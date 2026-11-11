import CoreGraphics
import Foundation

/// Cross-display window drag (multi-display ③④): dragging a window icon from one display's taskbar onto
/// another's moves the window to that display. Pure geometry: size unchanged (shrunk to the usable area if
/// larger than the target's), position = the same offset from the top-left of the **source display's usable
/// area**, clamped into the target's usable area; unknown source -> centered in the target's usable area. All
/// in Quartz coordinates (top-left origin).
enum WindowDisplayMove {
    static func targetFrame(window: CGRect,
                            from source: WindowDisplayAttribution.Display?,
                            to target: WindowDisplayAttribution.Display) -> CGRect {
        let area = target.visibleCGFrame
        let width = min(window.width, area.width)
        let height = min(window.height, area.height)
        var origin: CGPoint
        if let source {
            let offset = CGPoint(x: window.minX - source.visibleCGFrame.minX,
                                 y: window.minY - source.visibleCGFrame.minY)
            origin = CGPoint(x: area.minX + offset.x, y: area.minY + offset.y)
        } else {
            origin = CGPoint(x: area.midX - width / 2, y: area.midY - height / 2)
        }
        origin.x = min(max(origin.x, area.minX), area.maxX - width)
        origin.y = min(max(origin.y, area.minY), area.maxY - height)
        // Round only the origin and keep the size as is (`.integral` grows the size by 1pt at half pixels).
        return CGRect(x: origin.x.rounded(), y: origin.y.rounded(), width: width, height: height)
    }

    /// Whether the move succeeded: check that **the display the read-back frame is attributed to** is the
    /// target, not how many pt it differs from the requested frame. On a cross-display move AppKit often
    /// corrects a few pt itself (menu bar / usable area constraints, different scale factors on the two
    /// displays); judging failure by ±2pt would move a window that already arrived back again (2026-09-03:
    /// "the window reached B, flashed, then window and card went back to A").
    static func landedOnTarget(actual: CGRect, target: String, table: WindowDisplayAttribution.Table) -> Bool {
        WindowDisplayAttribution.displayUUID(for: actual, table: table) == target
    }
}
