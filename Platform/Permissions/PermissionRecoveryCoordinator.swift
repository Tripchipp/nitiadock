import Combine
import Foundation

/// Generation and single in-flight gate for the background permission probe. `stop()` permanently invalidates
/// results already issued; even if the next `start()` issues a new probe first, an old callback cannot clear
/// the in-flight state.
///
/// **Known cost**: `beginProbe()` returns nil while the previous probe has not returned, and that tick's
/// sample is **dropped entirely**. With `AXIsProcessTrusted()` moved to a background queue, the 5-second
/// sampling no longer guarantees a result on every tick. `PermissionLossDetector` decides "two consecutive
/// false ≥ 5s" on monotonic time, so dropped samples **cannot cause a false verdict** (a present permission
/// is never judged lost) but **delay** the discovery of a loss. This is accepted on purpose: if sampling
/// stalls the main thread, every menu/interaction hitches, which is worse than finding the loss a few seconds
/// late. What actually protects lifted windows is not this watchdog but the 0.2-second self-check
/// `WindowLiftAvoidanceController` keeps while a session/pending-restore state exists; the 1-second slow tier
/// is only for idle periods without snapshots.
struct PermissionWatchdogGate {
    private var generation: UInt64 = 0
    private var isProbeInFlight = false

    mutating func start() {
        generation &+= 1
        isProbeInFlight = false
    }

    mutating func stop() {
        generation &+= 1
        isProbeInFlight = false
    }

    mutating func beginProbe() -> UInt64? {
        guard !isProbeInFlight else { return nil }
        isProbeInFlight = true
        return generation
    }

    mutating func completeProbe(generation completedGeneration: UInt64) -> Bool {
        guard completedGeneration == generation, isProbeInFlight else { return false }
        isProbeInFlight = false
        return true
    }
}

/// Who performs the side effects the state machine declares. All through a protocol, so the machine's
/// side-effect sequence can be unit tested.
///
/// Starting/stopping a grant episode, rechecking and cancelling the recovery task are not here: those are the
/// coordinator's own business (it holds the model and `recoveryTask`) and should not be outsourced.
@MainActor
protocol PermissionEffectHandler: AnyObject {
    func startApp()
    func setActivationPolicy(_ policy: PermissionActivationPolicy)
    func showGuideWindow()
    func updateGuideWindow()
    func closeGuideWindow()
    func openAccessibilitySettings()
    func openApplicationsFolder()
    func startWatchdog()
    func stopWatchdog()
    func freezeLiftSnapshots()
    func unfreezeLiftSnapshots()
    func restoreLiftedWindows(episode: UInt64) async
    func suspendPanelsAndStores()
    func releaseHotKey()
    func registerHotKey()
    func launchNewInstance(episode: UInt64) async -> Result<Void, Error>
    func terminateSelf()
}

/// Single source of truth for permission onboarding and recovery. Views only observe `presentation`.
@MainActor
final class PermissionRecoveryCoordinator: ObservableObject {
    /// The view's only data source. `nil` = there should be no onboarding window.
    @Published private(set) var presentation: PermissionPresentation?

    private weak var handler: PermissionEffectHandler?
    private let permissionService: PermissionService
    private let installLocation: AppInstallLocation
    private let now: () -> TimeInterval
    private let makeModel: (PermissionEpisodePurpose, UInt64) -> AccessibilityPermissionModel

    private var machine = PermissionRecoveryMachine()
    private var detector = PermissionLossDetector()
    private var model: AccessibilityPermissionModel?
    private var modelSubscription: AnyCancellable?
    private var recoveryTask: Task<Void, Never>?
    private var onboardingState: PermissionOnboardingState = .waiting

    /// Event queue + reentrancy gate: `startPolling()` may confirm the grant and call back synchronously,
    /// reentering the state machine before the previous batch of side effects has finished. Queue the events
    /// so the order is deterministic.
    private var pendingEvents: [PermissionEvent] = []
    private var isDispatching = false

    var phase: PermissionPhase { machine.phase }

    init(
        handler: PermissionEffectHandler?,
        permissionService: PermissionService,
        installLocation: AppInstallLocation,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        makeModel: ((PermissionEpisodePurpose, UInt64) -> AccessibilityPermissionModel)? = nil
    ) {
        self.handler = handler
        self.permissionService = permissionService
        self.installLocation = installLocation
        self.now = now
        self.makeModel = makeModel ?? { _, _ in
            AccessibilityPermissionModel(
                permissionService: permissionService,
                installLocation: installLocation
            )
        }
    }

    // MARK: - Entry points

    func launched(trusted: Bool) {
        dispatch(.launched(location: installLocation, trusted: trusted))
    }

    /// The watchdog feeds every sample in here. The debounce decision is in the pure
    /// `PermissionLossDetector`.
    func sampleTrust(_ trusted: Bool) {
        dispatch(.trustVerdict(detector.record(trusted: trusted, at: now())))
    }

    func applicationDidBecomeActive() {
        model?.applicationDidBecomeActive()
    }

    func recheck() { dispatch(.recheckRequested) }
    func retryRelaunch() { dispatch(.retryRequested) }
    func quit() { dispatch(.quitRequested) }
    func terminationRequested() { dispatch(.terminationRequested) }
    func openSettings() { handler?.openAccessibilitySettings() }
    func openApplications() { handler?.openApplicationsFolder() }

    // MARK: - Dispatch

    private func dispatch(_ event: PermissionEvent) {
        pendingEvents.append(event)
        guard !isDispatching else { return }
        isDispatching = true
        defer { isDispatching = false }
        while !pendingEvents.isEmpty {
            run(machine.handle(pendingEvents.removeFirst()))
        }
    }

    private func run(_ effects: [PermissionEffect]) {
        for effect in effects {
            switch effect {
            case .startApp:
                handler?.startApp()
            case let .setActivationPolicy(policy):
                handler?.setActivationPolicy(policy)
            case .showGuide:
                refreshPresentation()
                handler?.showGuideWindow()
            case .updateGuide:
                refreshPresentation()
                handler?.updateGuideWindow()
            case .closeGuide:
                refreshPresentation()
                handler?.closeGuideWindow()
            case let .startPermissionEpisode(purpose, episode):
                startEpisode(purpose: purpose, episode: episode)
            case .stopPermissionEpisode:
                stopEpisode()
            case .requestSystemPrompt:
                model?.requestSystemPromptIfNeeded()
            case .recheckNow:
                model?.checkNow()
            case .startWatchdog:
                detector = PermissionLossDetector()
                handler?.startWatchdog()
            case .stopWatchdog:
                handler?.stopWatchdog()
            case .freezeLift:
                handler?.freezeLiftSnapshots()
            case .unfreezeLift:
                handler?.unfreezeLiftSnapshots()
            case let .restoreLiftedWindows(episode):
                startRestore(episode: episode)
            case .suspendPanelsAndStores:
                handler?.suspendPanelsAndStores()
            case .releaseHotKey:
                handler?.releaseHotKey()
            case .registerHotKey:
                handler?.registerHotKey()
            case let .launchNewInstance(episode):
                startLaunch(episode: episode)
            case .cancelRecoveryTask:
                recoveryTask?.cancel()
                recoveryTask = nil
            case .terminateSelf:
                handler?.terminateSelf()
            }
        }
        refreshPresentation()
    }

    private func refreshPresentation() {
        let next = PermissionRecoveryMachine.presentation(
            phase: machine.phase,
            onboarding: onboardingState
        )
        if presentation != next { presentation = next }
    }

    // MARK: - Grant episode (one model per episode)

    private func startEpisode(purpose: PermissionEpisodePurpose, episode: UInt64) {
        stopEpisode()
        let model = makeModel(purpose, episode)
        self.model = model
        onboardingState = model.state
        modelSubscription = model.$state.sink { [weak self] state in
            guard let self else { return }
            self.onboardingState = state
            self.refreshPresentation()
        }
        model.onGranted = { [weak self] in
            self?.dispatch(.grantObserved(episode: episode))
        }
        model.startPolling()
    }

    private func stopEpisode() {
        modelSubscription?.cancel()
        modelSubscription = nil
        model?.onGranted = nil
        model?.stop()
        model = nil
    }

    // MARK: - Recovery chain (tasks owned by the coordinator, cancelled on termination)

    private func startRestore(episode: UInt64) {
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            guard let self, let handler = self.handler else { return }
            await handler.restoreLiftedWindows(episode: episode)
            guard !Task.isCancelled else { return }
            self.dispatch(.windowsRestored(episode: episode))
        }
    }

    private func startLaunch(episode: UInt64) {
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            guard let self, let handler = self.handler else { return }
            let result = await handler.launchNewInstance(episode: episode)
            guard !Task.isCancelled else { return }
            switch result {
            case .success:
                self.dispatch(.relaunchSucceeded(episode: episode))
            case let .failure(error):
                self.dispatch(.relaunchFailed(episode: episode, message: error.localizedDescription))
            }
        }
    }
}
