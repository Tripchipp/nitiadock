import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Gesture monitor (force click / middle button -> content preview)
//
// Installs a **local** NSEvent monitor in the taskbar view tree: trackpad force click (.pressure reaching
// stage 2, debounced to fire once on entering stage2) + mouse middle button (.otherMouseDown button 2) ->
// calls back with global screen coordinates, handed to handleGesturePreview for the reverse hit test. The
// monitor only observes and does not consume (return e), so left clicks / folder drags are unaffected; a
// spike (2026-07-09) verified that a force click does not trigger the left-click action, so there is no
// conflict.
struct GestureMonitorInstaller: NSViewRepresentable {
    let onGesture: (CGPoint) -> Void
    /// fork: when set, a middle click goes here instead of `onGesture` (force-click still uses
    /// `onGesture`). Only called for clicks in this view's own window.
    var onMiddleClick: ((CGPoint) -> Void)?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.onGesture = onGesture
        context.coordinator.onMiddleClick = onMiddleClick
        context.coordinator.view = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onGesture = onGesture   // refresh the closure so it captures the latest chip frames
        context.coordinator.onMiddleClick = onMiddleClick
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var onGesture: ((CGPoint) -> Void)?
        var onMiddleClick: ((CGPoint) -> Void)?
        weak var view: NSView?
        private var pressureMonitor: Any?
        private var middleMonitor: Any?
        private var lastStage = 0

        func start() {
            pressureMonitor = NSEvent.addLocalMonitorForEvents(matching: .pressure) { [weak self] e in
                guard let self else { return e }
                if e.stage == 2 && self.lastStage < 2 { self.onGesture?(NSEvent.mouseLocation) }
                self.lastStage = e.stage
                return e
            }
            middleMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] e in
                guard e.buttonNumber == 2, let self else { return e }
                if let onMiddleClick = self.onMiddleClick, let window = self.view?.window, e.window === window {
                    onMiddleClick(NSEvent.mouseLocation)
                } else {
                    self.onGesture?(NSEvent.mouseLocation)
                }
                return e
            }
        }

        func stop() {
            if let m = pressureMonitor { NSEvent.removeMonitor(m) }
            if let m = middleMonitor { NSEvent.removeMonitor(m) }
            pressureMonitor = nil
            middleMonitor = nil
        }
    }
}
