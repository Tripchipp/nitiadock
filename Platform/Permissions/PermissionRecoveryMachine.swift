import Foundation

// MARK: - Inputs and outputs

enum PermissionActivationPolicy: Equatable {
    /// Regular running state without a Dock icon.
    case accessory
    /// Regular app: used only when the onboarding window must be brought to the front.
    case regular
}

enum PermissionEpisodePurpose: Equatable {
    case initialLaunch
    case runtimeRecovery
}

/// Overall permission phase.
///
/// Every entry into "waiting for grant" allocates a new `episode`, which async completions must carry back.
/// Setting the phase alone cannot stop tasks already inside an `await` (the event loop keeps running while
/// `applicationShouldTerminate` returns `.terminateLater`), so callbacks with a mismatched generation must be
/// dropped.
enum PermissionPhase: Equatable {
    case idle
    /// One-shot onboarding shell for a temporary copy (read-only volume / App Translocation), terminal state.
    case transientShell(AppInstallLocation)
    case onboarding(episode: UInt64)
    case running
    /// The watchdog read the first false. No UI change, but the window snapshots are frozen.
    case uncertain
    case suspended(episode: UInt64)
    case restoringWindows(episode: UInt64)
    case relaunching(episode: UInt64)
    case relaunchFailed(episode: UInt64, message: String)
    case terminating
}

enum PermissionEvent: Equatable {
    case launched(location: AppInstallLocation, trusted: Bool)
    case trustVerdict(PermissionLossDetector.Verdict)
    case grantObserved(episode: UInt64)
    case windowsRestored(episode: UInt64)
    case relaunchSucceeded(episode: UInt64)
    case relaunchFailed(episode: UInt64, message: String)
    case retryRequested
    case recheckRequested
    case quitRequested
    case terminationRequested
}

enum PermissionEffect: Equatable {
    case startApp
    case setActivationPolicy(PermissionActivationPolicy)
    case showGuide
    case updateGuide
    case closeGuide
    case startPermissionEpisode(purpose: PermissionEpisodePurpose, episode: UInt64)
    case stopPermissionEpisode
    case requestSystemPrompt
    case recheckNow
    case startWatchdog
    case stopWatchdog
    case freezeLift
    case unfreezeLift
    case restoreLiftedWindows(episode: UInt64)
    case suspendPanelsAndStores
    case releaseHotKey
    case registerHotKey
    case launchNewInstance(episode: UInt64)
    case cancelRecoveryTask
    case terminateSelf
}

/// What the onboarding window should show. `nil` means there should be no window.
///
/// Troubleshooting copy for first grant and runtime recovery **must be separate**: after a successful first
/// grant the current process simply continues with `startApp()`; there is no "automatic relaunch" and no
/// leftover windows lifted in this run.
enum PermissionPresentation: Equatable {
    case moveToApplications(AppInstallLocation)
    case waiting
    case stalled
    case recoveryWaiting
    case recoveryStalled
    case restoringWindows
    case relaunching
    case relaunchFailed(message: String)
}

// MARK: - State machine

/// Pure state machine: no AppKit, side effects are only returned as `PermissionEffect` and executed by the
/// coordinator.
struct PermissionRecoveryMachine: Equatable {
    private(set) var phase: PermissionPhase = .idle
    private var episodeCounter: UInt64 = 0

    init() {}

    mutating func handle(_ event: PermissionEvent) -> [PermissionEffect] {
        // The terminal state swallows everything: once quitting is decided, no late recovery event may launch
        // a new instance.
        if case .terminating = phase { return [] }

        switch event {
        case .terminationRequested:
            phase = .terminating
            return [.stopWatchdog, .cancelRecoveryTask, .stopPermissionEpisode]

        case .quitRequested:
            phase = .terminating
            return [.stopWatchdog, .cancelRecoveryTask, .stopPermissionEpisode, .terminateSelf]

        case let .launched(location, trusted):
            return handleLaunched(location: location, trusted: trusted)

        case let .trustVerdict(verdict):
            return handleTrustVerdict(verdict)

        case let .grantObserved(episode):
            return handleGrantObserved(episode: episode)

        case let .windowsRestored(episode):
            guard case let .restoringWindows(current) = phase, current == episode else { return [] }
            phase = .relaunching(episode: current)
            return [.updateGuide, .releaseHotKey, .launchNewInstance(episode: current)]

        case let .relaunchSucceeded(episode):
            guard case let .relaunching(current) = phase, current == episode else { return [] }
            return [.terminateSelf]

        case let .relaunchFailed(episode, message):
            guard case let .relaunching(current) = phase, current == episode else { return [] }
            phase = .relaunchFailed(episode: current, message: message)
            // If launching the new instance fails the old one must stay alive, so the hotkeys have to be
            // given back.
            return [.registerHotKey, .updateGuide]

        case .retryRequested:
            guard case let .relaunchFailed(current, _) = phase else { return [] }
            phase = .relaunching(episode: current)
            // A retry must also release the hotkeys first and cannot skip it because "they were released last
            // time": the failure branch has registered them again.
            return [.updateGuide, .releaseHotKey, .launchNewInstance(episode: current)]

        case .recheckRequested:
            switch phase {
            case .onboarding, .suspended:
                return [.recheckNow]
            default:
                return []
            }
        }
    }

    private mutating func handleLaunched(
        location: AppInstallLocation,
        trusted: Bool
    ) -> [PermissionEffect] {
        guard case .idle = phase else { return [] }

        if location.isTransient {
            // Temporary copy: do not request the permission (to avoid writing a dead TCC record pointing at a
            // temporary copy) and do not poll either: in this location it can never really get the
            // permission.
            phase = .transientShell(location)
            return [.setActivationPolicy(.regular), .showGuide]
        }

        if trusted {
            phase = .running
            return [.setActivationPolicy(.accessory), .startApp, .startWatchdog]
        }

        let episode = nextEpisode()
        phase = .onboarding(episode: episode)
        return [
            .setActivationPolicy(.regular),
            .showGuide,
            .startPermissionEpisode(purpose: .initialLaunch, episode: episode),
            .requestSystemPrompt,
        ]
    }

    private mutating func handleTrustVerdict(
        _ verdict: PermissionLossDetector.Verdict
    ) -> [PermissionEffect] {
        switch verdict {
        case .stable:
            guard case .uncertain = phase else { return [] }
            phase = .running
            return [.unfreezeLift]

        case .uncertain:
            guard case .running = phase else { return [] }
            phase = .uncertain
            return [.freezeLift]

        case .lost:
            switch phase {
            case .running, .uncertain:
                let episode = nextEpisode()
                phase = .suspended(episode: episode)
                return [
                    .stopWatchdog,
                    // Going straight from `.running` to `.lost` has not frozen yet; freezing is idempotent.
                    .freezeLift,
                    .suspendPanelsAndStores,
                    .setActivationPolicy(.regular),
                    .showGuide,
                    .startPermissionEpisode(purpose: .runtimeRecovery, episode: episode),
                    // After `tccutil reset` this instance may no longer be in the Accessibility list, so with
                    // polling alone the user has nothing to tick: it must register again.
                    .requestSystemPrompt,
                ]
            default:
                return []
            }
        }
    }

    private mutating func handleGrantObserved(episode: UInt64) -> [PermissionEffect] {
        switch phase {
        case let .onboarding(current) where current == episode:
            phase = .running
            return [
                .stopPermissionEpisode,
                .closeGuide,
                .setActivationPolicy(.accessory),
                .startApp,
                .startWatchdog,
            ]

        case let .suspended(current) where current == episode:
            // Restore is deferred to this moment: the permission just came back, and only now can AX write to
            // the lifted windows.
            phase = .restoringWindows(episode: current)
            return [.stopPermissionEpisode, .updateGuide, .restoreLiftedWindows(episode: current)]

        default:
            return []
        }
    }

    private mutating func nextEpisode() -> UInt64 {
        episodeCounter &+= 1
        return episodeCounter
    }

    // MARK: Presentation state

    static func presentation(
        phase: PermissionPhase,
        onboarding: PermissionOnboardingState
    ) -> PermissionPresentation? {
        switch phase {
        case .idle, .running, .uncertain, .terminating:
            return nil

        case let .transientShell(location):
            return .moveToApplications(location)

        case .onboarding:
            switch onboarding {
            case let .moveToApplications(location): return .moveToApplications(location)
            case .waiting, .granted: return .waiting
            case .stalled: return .stalled
            }

        case .suspended:
            switch onboarding {
            case let .moveToApplications(location): return .moveToApplications(location)
            case .waiting, .granted: return .recoveryWaiting
            case .stalled: return .recoveryStalled
            }

        case .restoringWindows:
            return .restoringWindows

        case .relaunching:
            return .relaunching

        case let .relaunchFailed(_, message):
            return .relaunchFailed(message: message)
        }
    }
}
