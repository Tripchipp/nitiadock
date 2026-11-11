import CoreGraphics

/// **Pure decision layer** for the panel rim: how wide each of the two layers (glass specular rim / theme
/// stroke) is drawn at a given moment.
///
/// It exists because of a real regression (reported 2026-08-20: "dragging an icon from the drawer to the
/// taskbar puts a black border around the whole taskbar"): the drop highlight was then written as **removing
/// the glass rim from the view tree and swapping in the theme stroke**. Before glass became the default, the
/// theme stroke only deepened the "white 0.6 -> black 0.1" gradient edge by one step, which did not stand
/// out; after glass became the default, the usual ring is the white specular rim measured against the native
/// Dock (peak 0.75), so the same code turned into "bright white edge -> pure black edge".
///
/// The rule now: **the glass rim is always drawn, and the highlight is layered on top, not swapped in.**
enum DockPanelRimPlan {
    /// Whether the glass specular rim (`DockGlassRim`) is drawn. Depends only on whether the glass path is
    /// used, not on the highlight.
    static func glassRimVisible(usesLiquidGlass: Bool) -> Bool {
        usesLiquidGlass
    }

    /// Line width of the theme stroke.
    ///
    /// - Frosted glass path (macOS 12-25): it **is** the rim, drawn both normally and when highlighted.
    /// - Glass path: normally `DockGlassRim` handles it and the theme stroke width is 0 (equivalent to not
    ///   being in the view tree); it is layered on only when highlighted. The width grows from 0 to
    ///   `lineWidth`, so the 0.15s fade-in is done by line width interpolation, and the hard `AnyShapeStyle`
    ///   cut between the highlight color and the usual gradient happens while the width is still 0,
    ///   invisibly.
    static func themeStrokeWidth(usesLiquidGlass: Bool,
                                 highlighted: Bool,
                                 lineWidth: CGFloat) -> CGFloat {
        guard usesLiquidGlass else { return lineWidth }
        return highlighted ? lineWidth : 0
    }
}
