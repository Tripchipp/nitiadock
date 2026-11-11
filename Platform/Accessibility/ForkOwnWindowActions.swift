import AppKit

/// fork: window actions on NitiaDock's own windows, done with AppKit on the main thread
/// (`ForkOwnWindowPolicy` explains why not through AX).
enum ForkOwnWindowActions {
    /// Callable from the bar's action queue; hops to the main thread and waits for the result.
    ///
    /// The `main.sync` is safe only because the main thread never waits synchronously on the
    /// `window-action` queue (`AppComposition`). Adding such a wait would deadlock here.
    @discardableResult
    static func perform(_ kind: PlatformActionRequest.ActionKind, cgWindowID: CGWindowID?) -> Bool {
        guard let cgWindowID else { return false }
        if Thread.isMainThread {
            return performOnMain(kind, cgWindowID: cgWindowID)
        }
        return DispatchQueue.main.sync { performOnMain(kind, cgWindowID: cgWindowID) }
    }

    /// Moves one of our own windows to another display, keeping its offset from the display's
    /// visible area (same geometry as an AX move of a foreign window). Main thread only.
    @MainActor
    static func move(
        cgWindowID: CGWindowID,
        from source: WindowDisplayAttribution.Display?,
        to target: WindowDisplayAttribution.Display
    ) -> Bool {
        guard let window = NSApp.windows.first(where: { $0.windowNumber == Int(cgWindowID) }),
              let primaryHeight = NSScreen.screens.first?.frame.height else { return false }
        // Cocoa frames have a bottom-left origin, Quartz a top-left one, both anchored on the
        // primary screen.
        let cocoa = window.frame
        let quartz = CGRect(x: cocoa.minX, y: primaryHeight - cocoa.maxY, width: cocoa.width, height: cocoa.height)
        let moved = WindowDisplayMove.targetFrame(window: quartz, from: source, to: target)
        window.setFrame(
            CGRect(x: moved.minX, y: primaryHeight - moved.maxY, width: moved.width, height: moved.height),
            display: true
        )
        return true
    }

    private static func performOnMain(_ kind: PlatformActionRequest.ActionKind, cgWindowID: CGWindowID) -> Bool {
        // Compare as Int: `windowNumber` is -1 for a window that is not on screen, and converting that to
        // `CGWindowID` traps.
        guard let window = NSApp.windows.first(where: { $0.windowNumber == Int(cgWindowID) }) else {
            return false
        }
        switch kind {
        case .activateWindow:
            NSApp.activate(ignoringOtherApps: true)
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return true
        case .minimizeWindow:
            window.miniaturize(nil)
            return true
        case .closeWindow:
            window.performClose(nil)
            return true
        default:
            return false
        }
    }
}
