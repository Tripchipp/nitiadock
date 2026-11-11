import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Single pointer tracking area for the whole bar

/// Reference box for the last pointer position. Lives in `@State` only to survive across body evaluations;
/// **mutating it does not trigger a re-evaluation**, which is the point: re-evaluating the whole bar body on
/// every pointer move is too expensive, so it only happens when the hovered card actually changes.
final class PointerBox {
    var value: CGPoint?
}

/// One `NSTrackingArea` covering the whole taskbar that reports the pointer position. Which card is hovered
/// is computed by the pure resolver `StripHoverResolution`. **This is the only hover source on the bar**;
/// cards no longer attach their own `.onHover` (missed cells + direction-dependent boundary bands, see that
/// type for the cause).
///
/// **Enter/exit come from the tracking area; position comes from our own per-frame polling.** The first
/// version relied entirely on the tracking area's `.mouseMoved`, which measured as a dead end: a 34-step
/// synthetic sweep reported only **6** events, 5 of them bunched into the last 80ms (2026-08-17). The cause:
/// these panels are all `.nonactivatingPanel` and never become the key window, and AppKit only guarantees
/// mouse-moved delivery to the key window. `acceptsMouseMovedEvents` does not fix it either (tried). Enter /
/// exit are reliable (SwiftUI's `.onHover(true)` has always relied on them).
///
/// So: `mouseEntered` starts a 60Hz timer that reads `NSEvent.mouseLocation`; when the pointer leaves this
/// view it reports `nil` and stops the timer. **It exists only while the pointer is over the taskbar**, not
/// as a permanent poll; a tick with an unchanged position is skipped, and `@State` is not written when the
/// hovered card is unchanged, so resting on the bar costs nothing.
///
/// This is not the permanent global `.mouseMoved` monitor that the project rules ban: that rule bans
/// `addGlobalMonitorForEvents` (an event tap: every mouse event system-wide passes through our process first,
/// which slows our own menus by 100ms). A timer is not a tap.
///
/// Two more load-bearing details:
/// - `.activeAlways`: the panel is never the key window, and the default `.activeInKeyWindow` would not even
///   get enter/exit.
/// - `hitTest` returns `nil`: it is a `.background` that only observes and never consumes clicks.
struct StripPointerTracker: NSViewRepresentable {
    /// Screen coordinates (bottom-left); `nil` = the pointer left the taskbar.
    let onMove: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onMove = onMove
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onMove = onMove   // refresh the closure so it captures the latest @State write path
    }

    static func dismantleNSView(_ nsView: TrackingView, coordinator: ()) {
        nsView.stopPolling()
        nsView.onMove = nil
    }

    final class TrackingView: NSView {
        /// Turns polling off and leaves only the tracking area's own `.mouseMoved`
        /// (`DOCK_STRIP_HOVER_POLL=0`). Kept so "is polling actually required" stays answerable: this A/B is
        /// what settled it on 2026-08-17.
        static let pollingEnabled =
            DebugSwitch.stripHoverPoll.isEnabled(in: ProcessInfo.processInfo.environment)

        var onMove: ((CGPoint?) -> Void)?
        private var area: NSTrackingArea?
        private var poll: Timer?
        private var lastReported: CGPoint?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stopPolling() }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let next = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(next)
            area = next
        }

        override func mouseEntered(with event: NSEvent) { pointerEvent() }
        override func mouseMoved(with event: NSEvent) { pointerEvent() }
        override func mouseDragged(with event: NSEvent) { pointerEvent() }

        /// The tracking area did deliver an event: report the position (this path always runs) and start the
        /// timer.
        private func pointerEvent() {
            report(NSEvent.mouseLocation)
            guard Self.pollingEnabled else { return }
            startPolling()
        }

        /// The tracking area's exit is only **one** of the teardown paths: it gets missed when the pointer
        /// leaves fast (the reason the "bubble watchdog" project rule exists). The poll's own out-of-bounds
        /// check is more reliable, so this only stops the timer one step early.
        override func mouseExited(with event: NSEvent) { leave() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func startPolling() {
            guard poll == nil else { return }
            tick()
            // 60Hz: the screen refresh rate, anything denser is invisible. At a 2400pt/s sweep each 42pt cell
            // takes about 17.5ms, so this cadence misses no cell.
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
            poll = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        func stopPolling() {
            poll?.invalidate()
            poll = nil
        }

        private func leave() {
            stopPolling()
            guard lastReported != nil else { return }
            lastReported = nil
            onMove?(nil)
        }

        private func tick() {
            guard let window, window.isVisible else {
                leave()
                return
            }
            let location = NSEvent.mouseLocation
            guard window.convertToScreen(convert(bounds, to: nil)).contains(location) else {
                leave()
                return
            }
            report(location)
        }

        /// A tick with an unchanged position is skipped: resting on the bar = zero cost.
        private func report(_ location: CGPoint) {
            guard location != lastReported else { return }
            lastReported = location
            onMove?(location)
        }
    }
}
