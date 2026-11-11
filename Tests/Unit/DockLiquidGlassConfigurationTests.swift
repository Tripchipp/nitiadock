import XCTest
@testable import NitiaDock

final class DockLiquidGlassConfigurationTests: XCTestCase {
    /// **Default is now on** (glass look made the default 2026-08-17).
    ///
    /// This test used to be named "default keeps the accepted frosted-glass
    /// path" and locked the exploration-phase "default off, on only with `=1`".
    /// That guardrail meant "an unaccepted effect must not be on
    /// by default"; once the look was accepted it had to flip,
    /// otherwise a process relaunched after a system restart (no
    /// env vars) would always show the old look, which did happen.
    func testDefaultNowShipsTheAcceptedGlassLook() {
        let configuration = DockLiquidGlassConfiguration.resolve(environment: [:])

        XCTAssertTrue(configuration.isEnabled)
        XCTAssertEqual(configuration.clearTintOpacity, 0.4)
        XCTAssertEqual(configuration.whiteOverlayOpacity, 0)
        XCTAssertEqual(configuration.dimmingOpacity, 0)
        XCTAssertEqual(configuration.borderPeakOpacity, 0.75, "peak level (top-left and bottom-right corners): tuned by measurement, not computed from 78/171")
        XCTAssertEqual(configuration.borderEdgeLevel, 0.5, "the long edge needs 0.375, divided by the 0.75 peak")
        XCTAssertEqual(configuration.borderCornerCut, 0.92, "top-right and bottom-left corners cut out, the native highlight line is almost absent there")
        XCTAssertEqual(configuration.borderCornerSpread, 2.2, "corner modulation radius = multiple of the corner radius")
        XCTAssertEqual(configuration.borderLineWidth, 0.5, "measured native outermost line: 1px @2x = 0.5pt")
        XCTAssertEqual(configuration.borderInnerOpacity, 0.21, "inner ring half step: brings the 84 backing up to the native 120")
        XCTAssertEqual(configuration.backgroundMaterialOpacity, 0)
        XCTAssertEqual(configuration.windowBlurRadius, 0, "window-level blur does not follow the corner radius and smears squares into the four corners; translucency does not rely on it")
        XCTAssertEqual(configuration.contentInset, 4)
        XCTAssertEqual(configuration.backgroundPlateOpacity, 0.001)
        XCTAssertEqual(
            configuration.renderPath(isGlassAPIAvailable: true, isCompositeAvailable: true),
            .layeredTaskbar
        )
        // No glass API on 12–25, still falls back to frosted glass:
        // flipping the default does not affect older systems.
        XCTAssertEqual(
            configuration.renderPath(isGlassAPIAvailable: false, isCompositeAvailable: true),
            .visualEffectFallback
        )
    }

    /// The switch that turns glass off **only accepts `0`**. Everything else (unset, garbage) means on.
    func testOnlyZeroTurnsGlassOff() {
        XCTAssertFalse(resolve(["DOCK_LIQUID_GLASS": "0"]).isEnabled)
        XCTAssertFalse(resolve(["DOCK_LIQUID_GLASS": " 0 \n"]).isEnabled)

        for value in ["", "1", "true", "yes", "2"] {
            XCTAssertTrue(resolve(["DOCK_LIQUID_GLASS": value]).isEnabled)
        }
    }

    func testCompositeRequiresSystemAPIAndBackgroundPanel() {
        let configuration = resolve(["DOCK_LIQUID_GLASS": "1"])

        XCTAssertEqual(
            configuration.renderPath(isGlassAPIAvailable: true, isCompositeAvailable: true),
            .layeredTaskbar
        )
        XCTAssertEqual(
            configuration.renderPath(isGlassAPIAvailable: false, isCompositeAvailable: true),
            .visualEffectFallback
        )
        XCTAssertEqual(
            configuration.renderPath(isGlassAPIAvailable: true, isCompositeAvailable: false),
            .visualEffectFallback
        )
    }

    func testNumericOverridesAcceptBounds() {
        let configuration = resolve([
            "DOCK_LIQUID_GLASS_CLEAR_TINT": "0",
            "DOCK_LIQUID_GLASS_WHITE_OVERLAY": "1",
            "DOCK_LIQUID_GLASS_DIMMING": "1",
            "DOCK_LIQUID_GLASS_BORDER": "1",
            "DOCK_LIQUID_GLASS_BORDER_EDGE": "1",
            "DOCK_LIQUID_GLASS_BORDER_CUT": "0",
            "DOCK_LIQUID_GLASS_BORDER_SPREAD": "6",
            "DOCK_LIQUID_GLASS_BORDER_WIDTH": "4",
            "DOCK_LIQUID_GLASS_BORDER_INNER": "1",
            "DOCK_LIQUID_GLASS_BACKGROUND_OPACITY": "0",
            "DOCK_LIQUID_GLASS_WINDOW_BLUR": "64",
            "DOCK_LIQUID_GLASS_CONTENT_INSET": "12",
        ])

        XCTAssertEqual(configuration.clearTintOpacity, 0)
        XCTAssertEqual(configuration.whiteOverlayOpacity, 1)
        XCTAssertEqual(configuration.dimmingOpacity, 1)
        XCTAssertEqual(configuration.borderPeakOpacity, 1)
        XCTAssertEqual(configuration.borderEdgeLevel, 1)
        XCTAssertEqual(configuration.borderCornerCut, 0)
        XCTAssertEqual(configuration.borderCornerSpread, 6)
        XCTAssertEqual(configuration.borderLineWidth, 4)
        XCTAssertEqual(configuration.borderInnerOpacity, 1)
        XCTAssertEqual(configuration.backgroundMaterialOpacity, 0)
        XCTAssertEqual(configuration.windowBlurRadius, 64)
        XCTAssertEqual(configuration.contentInset, 12)
    }

    func testInvalidNumericOverridesUseCandidateDefaults() {
        let invalidValues = ["", "abc", "nan", "inf", "-1", "999"]
        for value in invalidValues {
            let configuration = resolve([
                "DOCK_LIQUID_GLASS_CLEAR_TINT": value,
                "DOCK_LIQUID_GLASS_WHITE_OVERLAY": value,
                "DOCK_LIQUID_GLASS_DIMMING": value,
                "DOCK_LIQUID_GLASS_BORDER": value,
                "DOCK_LIQUID_GLASS_BORDER_EDGE": value,
                "DOCK_LIQUID_GLASS_BORDER_CUT": value,
                "DOCK_LIQUID_GLASS_BORDER_SPREAD": value,
                "DOCK_LIQUID_GLASS_BORDER_WIDTH": value,
                "DOCK_LIQUID_GLASS_BORDER_INNER": value,
                "DOCK_LIQUID_GLASS_BACKGROUND_OPACITY": value,
                "DOCK_LIQUID_GLASS_WINDOW_BLUR": value,
                "DOCK_LIQUID_GLASS_CONTENT_INSET": value,
            ])
            XCTAssertEqual(configuration.clearTintOpacity, 0.4, "clear tint: \(value)")
            XCTAssertEqual(configuration.whiteOverlayOpacity, 0, "white overlay: \(value)")
            XCTAssertEqual(configuration.dimmingOpacity, 0, "dimming: \(value)")
            XCTAssertEqual(configuration.borderPeakOpacity, 0.75, "border peak: \(value)")
            XCTAssertEqual(configuration.borderEdgeLevel, 0.5, "border edge: \(value)")
            XCTAssertEqual(configuration.borderCornerCut, 0.92, "border cut: \(value)")
            XCTAssertEqual(configuration.borderCornerSpread, 2.2, "border spread: \(value)")
            XCTAssertEqual(configuration.borderLineWidth, 0.5, "border width: \(value)")
            XCTAssertEqual(configuration.borderInnerOpacity, 0.21, "border inner: \(value)")
            XCTAssertEqual(configuration.backgroundMaterialOpacity, 0, "background: \(value)")
            XCTAssertEqual(configuration.windowBlurRadius, 0, "window blur: \(value)")
            XCTAssertEqual(configuration.contentInset, 4, "content inset: \(value)")
        }
    }

    /// Background window = the visible backing left after removing the 20pt transparent
    /// shadow margin from the content window; its height comes from `DockSize.metrics`
    /// (92 − 2×20 = 52 = medium panel height), **the glass no longer has a second height of its own**.
    func testBackgroundFrameIsTheVisiblePlateInsideTheShadowPadding() {
        XCTAssertEqual(
            DockLiquidGlassPanelGeometry.backgroundFrame(
                for: CGRect(x: 80, y: 10, width: 440, height: 92),
                shadowPadding: 20
            ),
            CGRect(x: 100, y: 30, width: 400, height: 52)
        )
    }

    func testBackgroundFrameIsIdentityWithoutShadowPadding() {
        let frame = CGRect(x: 10, y: 20, width: 100, height: 40)
        XCTAssertEqual(
            DockLiquidGlassPanelGeometry.backgroundFrame(for: frame, shadowPadding: 0),
            frame
        )
        XCTAssertEqual(
            DockLiquidGlassPanelGeometry.backgroundFrame(for: frame, shadowPadding: -2),
            frame,
            "a negative value must not enlarge the window"
        )
    }

    func testCompositePanelLifecycleOrderingIsAtomic() {
        XCTAssertEqual(
            DockLiquidGlassPanelLifecyclePlan.ordering(
                isCompositeActive: true,
                shouldShow: true
            ),
            [.background, .content]
        )
        XCTAssertEqual(
            DockLiquidGlassPanelLifecyclePlan.ordering(
                isCompositeActive: true,
                shouldShow: false
            ),
            [.content, .background]
        )
        XCTAssertEqual(
            DockLiquidGlassPanelLifecyclePlan.ordering(
                isCompositeActive: false,
                shouldShow: true
            ),
            [.content]
        )
        XCTAssertEqual(
            DockLiquidGlassPanelLifecyclePlan.ordering(
                isCompositeActive: false,
                shouldShow: false
            ),
            [.content]
        )
    }

    private func resolve(_ environment: [String: String]) -> DockLiquidGlassConfiguration {
        DockLiquidGlassConfiguration.resolve(environment: environment)
    }
}
