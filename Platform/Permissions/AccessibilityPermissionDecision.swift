import Foundation

// MARK: - Install location

/// Where this copy of the app lives.
///
/// macOS binds the Accessibility grant to a **specific copy of the app**. For a copy running from a read-only
/// volume (a mounted disk image) or an App Translocation temp path, the grant never takes effect even if the
/// user ticks the box in System Settings: the record points at a copy that vanishes on unmount/quit. So in
/// both locations the user is first asked to move the app, and we must **never** send a registration request
/// to TCC, to avoid leaving a dead record pointing at a temporary copy.
enum AppInstallLocation: String, Equatable {
    case applications
    case readOnlyVolume
    case appTranslocation
    case other

    /// - Parameter isReadOnlyVolume: `nil` means the volume info is unreadable (volume just unmounted,
    ///   etc.). Treat that as writable: better to miss a block than to lock a correctly located user on the
    ///   move page.
    init(bundleURL: URL, isReadOnlyVolume: (URL) -> Bool?) {
        let url = bundleURL.standardizedFileURL
        let path = url.path

        if path.split(separator: "/").contains("AppTranslocation") {
            self = .appTranslocation
        } else if Self.isUnderApplications(path) {
            self = .applications
        } else if isReadOnlyVolume(url) == true {
            self = .readOnlyVolume
        } else {
            self = .other
        }
    }

    private static func isUnderApplications(_ path: String) -> Bool {
        for root in ["/Applications", NSHomeDirectory() + "/Applications"] {
            if path == root || path.hasPrefix(root + "/") { return true }
        }
        return false
    }

    /// A temporary location must never register with TCC.
    var allowsAccessibilityPrompt: Bool { !isTransient }

    /// A temporary copy is only a one-shot onboarding shell: it does not take over other instances, register
    /// global hotkeys or request permissions.
    var isTransient: Bool {
        switch self {
        case .readOnlyVolume, .appTranslocation:
            return true
        case .applications, .other:
            return false
        }
    }
}

// MARK: - Onboarding steps

/// Which step the onboarding page should show now.
///
/// ⚠️ `.stalled` only means "waited a long time without getting the permission, time for troubleshooting
/// advice". It is **not** a verdict that "the old grant record in the system is invalid": the TCC database is
/// unreadable, so we can prove neither whether the user actually turned the switch on nor that the old record
/// mismatches. Copy based on it must always be conditional.
enum PermissionOnboardingState: Equatable {
    case moveToApplications(AppInstallLocation)
    case waiting
    case stalled
    case granted

    static func initial(installLocation: AppInstallLocation, isTrusted: Bool) -> Self {
        // Location takes priority over trust: even if a temporary copy is trusted now, that grant disappears
        // with the copy.
        guard installLocation.allowsAccessibilityPrompt else {
            return .moveToApplications(installLocation)
        }
        return isTrusted ? .granted : .waiting
    }

    func updated(isTrusted: Bool, elapsed: TimeInterval, stallAfter: TimeInterval) -> Self {
        if case .moveToApplications = self { return self }
        if isTrusted { return .granted }
        return elapsed >= stallAfter ? .stalled : .waiting
    }
}

// MARK: - Runtime loss debounce

/// Debounce decision for losing the permission at runtime.
///
/// It only decides **when the user-visible shutdown happens** (collapse the taskbar, show recovery
/// onboarding). The snapshot protection of maximize lift avoidance does **not rely on it**: with a
/// session/pending-restore state that side still polls every 0.2s, here it is every 5s, and the gap is
/// covered by `WindowLiftAvoidanceController`'s self-check in `poll()`.
struct PermissionLossDetector: Equatable {
    enum Verdict: Equatable {
        /// Permission is fine.
        case stable
        /// Read false once. Invisible to the user, but the window snapshots must be frozen at once.
        case uncertain
        /// Loss confirmed: false read consecutively and for long enough.
        case lost
    }

    /// Minimum duration required to declare loss. Equals one watchdog polling period. "Twice in a row" alone
    /// is not enough: a timer tick and `applicationDidBecomeActive` can arrive within tens of milliseconds of
    /// each other, which does not prove the permission is really gone.
    static let minimumSustained: TimeInterval = 5

    private var firstFalseAt: TimeInterval?
    private var consecutiveFalse = 0

    init() {}

    /// - Parameter at: **monotonic** clock (`ProcessInfo.processInfo.systemUptime`), not wall clock.
    mutating func record(trusted: Bool, at: TimeInterval) -> Verdict {
        guard !trusted else {
            firstFalseAt = nil
            consecutiveFalse = 0
            return .stable
        }

        // The anchor is set only on the first false: out-of-order/early samples may not move it back,
        // otherwise a run of jittery samples would reset "how long it has lasted" forever.
        if firstFalseAt == nil { firstFalseAt = at }
        consecutiveFalse += 1

        let elapsed = max(0, at - (firstFalseAt ?? at))
        if consecutiveFalse >= 2, elapsed >= Self.minimumSustained { return .lost }
        return .uncertain
    }
}

// MARK: - System Settings entry

enum AccessibilitySettingsLink {
    /// Deep link to "Privacy & Security -> Accessibility". Shared by `AppDelegate` and the status menu; do
    /// not copy the string again in each.
    static let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
}
