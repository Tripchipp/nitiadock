import ApplicationServices
import CoreGraphics

// Pure decision for whether the focused window is fullscreen and belongs to this display. Platform layer:
// `FullscreenIntentMonitor` calls it on the event tap thread, and so does `PanelCoordinator`'s async AX
// probe; no AX calls / AppKit / logging allowed here. Moved from App/Composition/PanelVisibilityState.swift
// on 2026-09-05, removing the only Platform->App reverse dependency.

// Pure decision for the async AX fullscreen probe (called by PanelCoordinator.detectFullscreenViaAX). The
// role gate is a hard constraint: Finder carries a desktop pseudo-window (role=AXScrollArea, frame exactly
// equal to the whole screen) that becomes AXFocusedWindow the moment a minimized window is restored. Without
// the gate it hits the frame≈whole-screen fallback and the taskbar is hidden by mistake.
/// Three-state verdict for the focused window relative to **this display** (multi-display taskbar,
/// 2026-09-02). `.notOnThisScreen` = the bulk of the focused window is on another display. For this display's
/// bar it is **not evidence**: this display may be showing another app's fullscreen Space right now, so ask
/// SkyLight for this display's current Space type instead
/// (`PanelCoordinator.triggerAsyncFullscreenCheck`), rather than treating it as "not fullscreen" and
/// showing the bar.
enum FullscreenAXVerdict: Equatable {
    case fullscreen
    case windowed
    case notOnThisScreen
}

enum FullscreenWindowClassifier {
    static let frameTolerance: CGFloat = 8

    /// The Boolean form is kept for callers with single-display semantics
    /// (`FullscreenIntentMonitor.readAXState`, the probe copy): only `.fullscreen` is true, word for word
    /// equivalent to before the three states.
    static func isFullscreen(
        role: String?,
        isAXFullscreen: Bool,
        windowFrame: CGRect?,
        screenCGFrame: CGRect
    ) -> Bool {
        classify(role: role, isAXFullscreen: isAXFullscreen, windowFrame: windowFrame, screenCGFrame: screenCGFrame)
            == .fullscreen
    }

    static func classify(
        role: String?,
        isAXFullscreen: Bool,
        windowFrame: CGRect?,
        screenCGFrame: CGRect
    ) -> FullscreenAXVerdict {
        guard role == kAXWindowRole else { return .windowed }

        if isAXFullscreen {
            guard let wf = windowFrame else { return .fullscreen }
            // Ownership criterion (bulk of the area on this display), not a width criterion. The old `width >
            // screen × 0.7` doubled as the multi-display guardrail but **wrongly rejected half-width tiles in
            // fullscreen tiling (true split view)**. Measured 2026-08-30 (macOS 26.5.2,
            // `scratch/space-probe-20260830-2106.log`): a split-view tile reports AXFullScreen=true,
            // frame=(0,40 1278×1400), 1278 < 2560×0.7 was rejected, and the taskbar covered the split-view
            // content (0.9.10 feedback `02525cc5`). Area ownership keeps the guardrail's intent: a fullscreen
            // window on another display, measured the same day, does not intersect this display and is still
            // blocked.
            return mostlyBelongsToScreen(wf, screenCGFrame) ? .fullscreen : .notOnThisScreen
        }

        // Fallback: frame ≈ full screen (games / HTML5 that skip the AXFullScreen flag)
        if let wf = windowFrame {
            let t = frameTolerance
            if abs(wf.width  - screenCGFrame.width)  < t
                && abs(wf.height - screenCGFrame.height) < t
                && abs(wf.minX   - screenCGFrame.minX)   < t
                && abs(wf.minY   - screenCGFrame.minY)   < t {
                return .fullscreen
            }
            return mostlyBelongsToScreen(wf, screenCGFrame) ? .windowed : .notOnThisScreen
        }

        return .windowed
    }

    /// A window belongs to this display only if more than half its area lies on it. Pure CGRect math:
    /// `FullscreenIntentMonitor.readAXState` also calls this and the result is consumed on the event tap
    /// thread, so no AX / AppKit / logging here (see the panels-and-screens rule). Same area method as the
    /// private method of the same name in `WindowLiftAvoidance`, deliberately not shared: the lift avoidance
    /// copy is frozen in its own rule file, and coupling the two would make changes riskier.
    private static func mostlyBelongsToScreen(_ frame: CGRect, _ screen: CGRect) -> Bool {
        let frameArea = frame.width * frame.height
        guard frameArea > 0 else { return false }
        let overlap = frame.intersection(screen)
        guard !overlap.isNull, !overlap.isEmpty else { return false }
        return overlap.width * overlap.height >= frameArea * 0.5
    }
}
