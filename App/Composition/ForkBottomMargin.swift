import CoreGraphics

/// fork: adjustable distance between the screen's bottom edge and the bar (Settings > Appearance >
/// Bottom margin). Pure geometry, unit-tested in `ForkBottomMarginTests`.
///
/// The margin replaces `PanelLayoutMetrics.bottomGap`, which is the single number upstream derives
/// the bar's vertical position from: the panel frames (`PanelGeometry.dockTargetFrame`), the capsule
/// and drawer (anchored to the dock frame), and the top edge the window lift clears
/// (`PanelCoordinator.windowLiftAvoidanceContext`). Nothing else needs to know the bar moved.
enum ForkBottomMargin {
    /// The strip between the screen's bottom edge and the bar's panel, as wide as the panel.
    ///
    /// Auto-hide wakes the bar when the pointer reaches the screen's bottom edge, and hides it again
    /// shortly after the pointer is outside every panel. Upstream's 8pt gap is inside the panel's
    /// 20pt transparent shadow border, so edge and bar are one continuous "inside". A larger margin
    /// opens a dead zone between them: the pointer would wake the bar at the edge, leave "inside" on
    /// its way up, and arm the hide timer before it arrives. This corridor closes that zone.
    ///
    /// `nil` when the panel already reaches the edge, which includes every untouched install.
    static func approachCorridor(dockPanelFrame: CGRect, screenFrame: CGRect) -> CGRect? {
        let height = dockPanelFrame.minY - screenFrame.minY
        guard height > 0 else { return nil }
        return CGRect(x: dockPanelFrame.minX, y: screenFrame.minY, width: dockPanelFrame.width, height: height)
    }
}

extension PanelLayoutMetrics {
    /// fork: lets the plate shrink to its content instead of stopping at `minimumDockWidth`.
    ///
    /// Upstream never lets the plate get narrower than 120pt x tier. The strip inside is a
    /// leading-anchored scroll view, so when the entries need less than that, all of the surplus
    /// shows up as an empty stretch on the **right** (2026-09-18: two icons at the small tier with
    /// 6pt edge padding need 78pt, the plate stayed 102pt wide). Upstream rarely gets there, since
    /// Finder and the Trash are always on its bar, but it does with a single entry; NitiaDock gets
    /// there easily (no kept Finder, Trash can be hidden, edge padding and spacing can be reduced).
    ///
    /// A strip with no entries gets a square plate (as wide as the bar is tall): still something to
    /// see and right-click, but no wider than a bar holding one icon. Upstream's 120pt minimum made
    /// the empty bar the widest small bar there is, which reads as "two invisible apps"
    /// (reported 2026-09-18).
    ///
    /// - Parameters:
    ///   - contentWidth: the measured width of the strip's content, padding included.
    ///   - emptyContentWidth: what that measurement is with zero entries (both edge paddings).
    func huggingContent(contentWidth: CGFloat, emptyContentWidth: CGFloat) -> PanelLayoutMetrics {
        guard contentWidth.isFinite else { return self }
        var copy = self
        let hasEntries = contentWidth > emptyContentWidth + 1
        copy.minimumDockWidth = min(minimumDockWidth, hasEntries ? contentWidth : panelHeight)
        return copy
    }

    /// `nil` = upstream's `bottomGap`, untouched.
    func withBottomMargin(_ margin: Double?) -> PanelLayoutMetrics {
        guard let margin else { return self }
        var copy = self
        copy.bottomGap = CGFloat(margin)
        return copy
    }
}
