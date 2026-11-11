import CoreGraphics
import Foundation

/// The **pure decision layer** for whether a right click on
/// the taskbar backing should show the NitiaDock menu.
///
/// Only two places count (decided 2026-08-03):
/// - **Blank ends**: the inset margins left of the leftmost chip and right of the rightmost chip;
/// - **Around a zone divider**: the wide gap the divider sits in.
///
/// The **narrow gaps between chips deliberately do not count**: when the user aims at an icon and lands
/// a few pt off, showing the NitiaDock menu (instead of that app's own menu) is worse than showing
/// nothing. The cost is that a right click in a narrow gap does nothing at all, a known trade-off.
///
/// The two kinds of gap are told apart by width: the space around a divider is
/// `2 (HStack spacing) + 5 (1pt hairline + 2pt padding on each side) + 2 (HStack spacing) = 9pt`,
/// while the ordinary chip spacing is only `2pt`; a threshold between the two
/// is enough, and it scales with the size tier.
///
/// **The threshold must fall strictly between the two; changing `Style.chipSpacing` means changing it too.**
/// On 2026-08-16, when icon spacing was aligned with the native Dock (center spacing 52->42pt,
/// `chipSpacing` 8->2), the divider gap shrank from 21pt to 9pt while the threshold was still 12pt, so
/// the divider gap was no longer recognized either and right click stopped working on the whole taskbar.
enum StripContextMenuZone {
    /// Baseline for the medium tier. Callers pass `defaultMinimumGapWidth * scale`.
    /// 5pt: greater than the ordinary 2pt gap, less than the 9pt divider gap.
    static let defaultMinimumGapWidth: CGFloat = 5

    /// `point` and `chipFrames` are both in the "strip" coordinate space (top-left origin, y down).
    static func claims(
        point: CGPoint,
        chipFrames: [CGRect],
        bounds: CGRect,
        minimumGapWidth: CGFloat
    ) -> Bool {
        guard bounds.contains(point) else { return false }
        // Do not count while no chip has been measured yet (first frame): better that this one right
        // click does nothing than to steal that app's menu when the click "was actually on an icon".
        guard !chipFrames.isEmpty else { return false }
        guard !chipFrames.contains(where: { $0.contains(point) }) else { return false }

        let sorted = chipFrames.sorted { $0.minX < $1.minX }
        guard let first = sorted.first, let last = sorted.last else { return false }

        // Blank ends.
        if point.x < first.minX || point.x > last.maxX { return true }

        // Middle: only points inside a "wide enough gap" count. Uses the running maximum of maxX rather
        // than the previous chip's maxX: frames can overlap (frames outset by the messaging zone, temporary
        // positions during a drag), and only comparing one by one avoids counting overlap as a gap.
        var gapStart = first.maxX
        for frame in sorted.dropFirst() {
            if point.x < frame.minX {
                let width = frame.minX - gapStart
                return width >= minimumGapWidth && point.x >= gapStart
            }
            gapStart = max(gapStart, frame.maxX)
        }
        return false
    }
}
