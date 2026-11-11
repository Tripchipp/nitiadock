import Foundation

/// fork: window actions on NitiaDock's own windows (the Settings window has a card on the bar while it is
/// open) must not go through the accessibility API.
///
/// The bar runs every window action on a background queue and drives it with AX calls. For another app's
/// window that is a message to another process. For a window of our own process AppKit serves the AX
/// request on the calling thread, i.e. it runs `makeKeyAndOrderFront` on the background queue, and
/// AppKit stops the process there ("must only be used from the main thread", EXC_BREAKPOINT). So these
/// are done with the window's own AppKit methods on the main thread instead.
enum ForkOwnWindowPolicy {
    /// Whether `execute` should hand the request to `ForkOwnWindowActions` instead of the AX executor.
    /// `hideApp`, `quitApp` and `newWindow` act on the application, not through a window's AX element,
    /// and keep their existing paths.
    static func handlesNatively(
        kind: PlatformActionRequest.ActionKind,
        windowPID: Int32,
        ownPID: Int32,
        isAppLevelFallback: Bool
    ) -> Bool {
        guard windowPID == ownPID, !isAppLevelFallback else { return false }
        switch kind {
        case .activateWindow, .minimizeWindow, .closeWindow: return true
        default: return false
        }
    }
}
