import Combine
import Foundation

/// One "waiting for the user to grant" episode: polls the permission state, advances onboarding steps by wait
/// time, and calls back once when granted.
///
/// ⚠️ **Each episode needs a new instance.** `didRequestPrompt` and `didNotifyGranted` are one-shot gates for
/// the instance's lifetime: after the first successful grant the same instance never shows the system prompt
/// or calls back again. Reusing it silences the "runtime permission loss -> recovery" path entirely.
@MainActor
final class AccessibilityPermissionModel: ObservableObject {
    static let pollInterval: TimeInterval = 1
    static let defaultStallInterval: TimeInterval = 8

    @Published private(set) var state: PermissionOnboardingState

    /// One-shot callback. Set to nil right after firing so a queued timer cannot feed it again.
    var onGranted: (() -> Void)?
    var onTrustStatusChanged: ((Bool) -> Void)?

    private let permissionService: PermissionService
    private let installLocation: AppInstallLocation
    private let now: () -> TimeInterval
    private let stallAfter: TimeInterval
    private var pollingStartedAt: TimeInterval?
    private var timer: Timer?
    private var didRequestPrompt = false
    private var didNotifyGranted = false
    private var lastObservedTrust: Bool

    init(
        permissionService: PermissionService = PermissionService(),
        installLocation: AppInstallLocation,
        initialTrusted: Bool? = nil,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        stallAfter: TimeInterval = AccessibilityPermissionModel.defaultStallInterval
    ) {
        let trusted = initialTrusted ?? permissionService.hasRequiredPermissions()
        self.permissionService = permissionService
        self.installLocation = installLocation
        self.now = now
        self.stallAfter = stallAfter
        self.lastObservedTrust = trusted
        self.state = .initial(installLocation: installLocation, isTrusted: trusted)
    }

    func startPolling() {
        // A temporary copy in that location can never get a valid grant, so polling is pointless.
        guard installLocation.allowsAccessibilityPrompt, !didNotifyGranted else { return }
        if pollingStartedAt == nil { pollingStartedAt = now() }
        checkNow()
        guard state != .granted, timer == nil else { return }

        // `.common` mode: keep running during menu tracking / modal sessions, otherwise nothing happens when
        // the user flips the switch and comes back.
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkNow() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Shows the native system prompt once. Never in a temporary location.
    func requestSystemPromptIfNeeded() {
        guard installLocation.allowsAccessibilityPrompt,
              state != .granted,
              !didRequestPrompt else { return }
        didRequestPrompt = true
        permissionService.requestAccessibilityPermission()
    }

    func applicationDidBecomeActive() {
        checkNow()
    }

    func checkNow() {
        guard installLocation.allowsAccessibilityPrompt, !didNotifyGranted else { return }
        if pollingStartedAt == nil { pollingStartedAt = now() }

        let trusted = permissionService.hasRequiredPermissions()
        if trusted != lastObservedTrust {
            lastObservedTrust = trusted
            onTrustStatusChanged?(trusted)
        }

        let elapsed = max(0, now() - (pollingStartedAt ?? now()))
        state = state.updated(isTrusted: trusted, elapsed: elapsed, stallAfter: stallAfter)
        guard state == .granted else { return }

        didNotifyGranted = true
        stop()
        let callback = onGranted
        onGranted = nil
        callback?()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
