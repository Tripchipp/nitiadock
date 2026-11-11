import XCTest

/// The only reason this suite exists: the 2026-08-20 report "dragging an icon
/// from the drawer to the taskbar puts a black rim around the whole taskbar".
/// Cause: the drop highlight **replaced the glass specular
/// rim entirely**. The first case below locks exactly that.
final class DockPanelRimPlanTests: XCTestCase {

    /// The highlight must **not** remove the glass rim again: the highlight is layered on top.
    func testGlassRimSurvivesHighlight() {
        XCTAssertTrue(DockPanelRimPlan.glassRimVisible(usesLiquidGlass: true))
        XCTAssertFalse(DockPanelRimPlan.glassRimVisible(usesLiquidGlass: false))
    }

    /// Glass path: the resting rim belongs to `DockGlassRim`, so the theme stroke width must be 0
    /// (not an invisible line: 0 width is equivalent to staying
    /// out of the view tree, same rule as `.blur(radius: 0)`).
    func testGlassPathDrawsThemeStrokeOnlyWhenHighlighted() {
        XCTAssertEqual(
            DockPanelRimPlan.themeStrokeWidth(usesLiquidGlass: true, highlighted: false, lineWidth: 0.5),
            0
        )
        XCTAssertEqual(
            DockPanelRimPlan.themeStrokeWidth(usesLiquidGlass: true, highlighted: true, lineWidth: 1),
            1
        )
    }

    /// Frosted-glass path (macOS 12–25): the theme stroke **is**
    /// the rim, drawn both at rest and for the highlight.
    func testFrostedPathAlwaysDrawsTheThemeStroke() {
        XCTAssertEqual(
            DockPanelRimPlan.themeStrokeWidth(usesLiquidGlass: false, highlighted: false, lineWidth: 0.5),
            0.5
        )
        XCTAssertEqual(
            DockPanelRimPlan.themeStrokeWidth(usesLiquidGlass: false, highlighted: true, lineWidth: 1),
            1
        )
    }
}
