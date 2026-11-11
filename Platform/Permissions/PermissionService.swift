import ApplicationServices
import Foundation

/// I/O layer for the Accessibility permission. All three entry points are injectable so the onboarding logic
/// can be unit tested apart from system state.
///
/// This file is also compiled into the window-lab target, which has no
/// `AccessibilityPermissionDecision.swift`, so only the raw fact "is the volume read-only" is provided here
/// and classifying the install location is left to the caller.
struct PermissionService {
    private let trustCheck: () -> Bool
    private let promptRequest: () -> Bool
    private let readOnlyVolumeCheck: (URL) -> Bool?

    init(
        trustCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
        promptRequest: @escaping () -> Bool = {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        },
        readOnlyVolumeCheck: @escaping (URL) -> Bool? = PermissionService.systemReadOnlyVolumeCheck
    ) {
        self.trustCheck = trustCheck
        self.promptRequest = promptRequest
        self.readOnlyVolumeCheck = readOnlyVolumeCheck
    }

    func hasRequiredPermissions() -> Bool {
        trustCheck()
    }

    /// Shows the native system prompt and registers this app in the Accessibility list. **Call only from a
    /// stable install location**: from a temporary copy it leaves a dead record in the system pointing at
    /// that copy.
    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        promptRequest()
    }

    /// `nil` = volume info unreadable (volume just unmounted, etc.).
    func isReadOnlyVolume(_ url: URL) -> Bool? {
        readOnlyVolumeCheck(url)
    }

    static func systemReadOnlyVolumeCheck(_ url: URL) -> Bool? {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly
    }
}
