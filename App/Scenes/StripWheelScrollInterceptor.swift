import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Mouse wheel horizontal strip scrolling

struct WheelScrollInterceptorRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> WheelScrollInterceptorView {
        WheelScrollInterceptorView()
    }

    func updateNSView(_ nsView: WheelScrollInterceptorView, context: Context) {
        nsView.resolveScrollViewIfNeeded()
    }
}

final class WheelScrollInterceptorView: NSView {
    /// Diagnostic, off by default: prints only with `DOCK_STRIP_WHEEL_TRACE=1`.
    private static let trace = DebugSwitch.stripWheelTrace.isEnabled(in: ProcessInfo.processInfo.environment)

    private weak var scrollView: NSScrollView?
    private var reportedMissingScrollView = false

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        resolveScrollViewIfNeeded()
    }

    override func layout() {
        super.layout()
        resolveScrollViewIfNeeded()
    }

    /// **`point` is in the superview's coordinate system**, so the test must go through `super.hitTest` and
    /// must not compare it with our own `bounds` (`MenuHostNSView` is written the same way). The bar has a
    /// 20pt shadow margin around it; comparing against bounds shifts everything and leaves a whole band of
    /// the bar without wheel events.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil,
              let event = NSApp.currentEvent,
              event.type == .scrollWheel,
              StripWheelScroll.horizontalStep(for: Self.input(from: event)) != nil,
              overflowExtent() > 0 else {
            return nil
        }
        return self
    }

    /// **Nothing to do** when "reverse mouse wheel direction" is on: that tap sits at the head of the
    /// session, so what arrives here is the already reversed delta, same as other apps see; the bar's pan
    /// direction follows.
    override func scrollWheel(with event: NSEvent) {
        let input = Self.input(from: event)
        guard let delta = StripWheelScroll.horizontalStep(for: input),
              let scrollView = resolveScrollViewIfNeeded(),
              let documentView = scrollView.documentView else {
            super.scrollWheel(with: event)
            return
        }

        let clipView = scrollView.contentView
        let maxX = max(0, documentView.bounds.width - clipView.bounds.width)
        let currentX = clipView.bounds.origin.x
        let nextX = min(max(currentX + delta, 0), maxX)
        if Self.trace {
            print("[stripwheel] precise=\(input.hasPreciseDeltas) dx=\(input.deltaX) dy=\(input.deltaY)"
                + " inverted=\(input.isDirectionInverted) step=\(delta) x=\(currentX)->\(nextX) maxX=\(maxX)")
        }
        guard maxX > 0, nextX != currentX else { return }

        clipView.scroll(to: NSPoint(x: nextX, y: clipView.bounds.origin.y))
        scrollView.reflectScrolledClipView(clipView)
    }

    private static func input(from event: NSEvent) -> StripWheelScroll.Input {
        StripWheelScroll.Input(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            isDirectionInverted: event.isDirectionInvertedFromDevice
        )
    }

    /// How many pt can still be scrolled to the right. `0` = no overflow (or the scrollView is not resolved
    /// yet); events are never claimed then.
    ///
    /// **Called only when a scroll event actually arrives** (`hitTest` has already filtered the event type),
    /// so the "`NSScrollView` not found" warning lives here and is not falsely raised by the normal empty
    /// lookup early in launch, before SwiftUI has built the view.
    private func overflowExtent() -> CGFloat {
        guard let scrollView = resolveScrollViewIfNeeded(),
              let documentView = scrollView.documentView else {
            reportMissingScrollViewOnce()
            return 0
        }
        return max(0, documentView.bounds.width - scrollView.contentView.bounds.width)
    }

    /// The **only silent failure point** of this feature: if SwiftUI's `ScrollView` is ever no longer backed
    /// by `NSScrollView`, horizontal scrolling dies without a sound, not even a log line. Reported once.
    private func reportMissingScrollViewOnce() {
        guard !reportedMissingScrollView else { return }
        reportedMissingScrollView = true
        print("[stripwheel] NSScrollView not found, taskbar horizontal scrolling is disabled"
            + " (SwiftUI's ScrollView may no longer be backed by NSScrollView)")
    }

    @discardableResult
    func resolveScrollViewIfNeeded() -> NSScrollView? {
        if let scrollView, scrollView.window != nil {
            return scrollView
        }

        var ancestor = superview
        while let candidate = ancestor {
            if let found = findScrollView(in: candidate) {
                scrollView = found
                return found
            }
            ancestor = candidate.superview
        }
        scrollView = nil
        return nil
    }

    private func findScrollView(in root: NSView) -> NSScrollView? {
        guard root !== self else { return nil }
        if let scrollView = root as? NSScrollView {
            return scrollView
        }
        for subview in root.subviews {
            if let found = findScrollView(in: subview) {
                return found
            }
        }
        return nil
    }
}

extension View {
    /// macOS 14's `defaultScrollAnchor(.leading)` is unavailable on older systems; a horizontal ScrollView
    /// starts at the leading edge anyway, so older systems use the default (anchored explicitly on 14+ only,
    /// behavior unchanged).
    @ViewBuilder
    func compatLeadingScrollAnchor() -> some View {
        if #available(macOS 14.0, *) {
            self.defaultScrollAnchor(.leading)
        } else {
            self
        }
    }
}
