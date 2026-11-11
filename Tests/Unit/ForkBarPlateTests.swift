import XCTest

/// fork: the bar's own plate, light / dark and how transparent.
final class ForkBarPlateTests: XCTestCase {
    private let theme = DockThemeTokens.standard
    private let upstreamOpacity = DockLiquidGlassConfiguration.resolve(environment: [:]).clearTintOpacity

    func testUntouchedPlateIsUpstreamsTintValueForValue() {
        XCTAssertEqual(upstreamOpacity, 0.4)
        for systemIsDark in [false, true] {
            let plate = ForkAppearance.upstream.resolvedBarPlate(upstreamOpacity: upstreamOpacity, systemIsDark: systemIsDark)
            XCTAssertEqual(plate, .init(white: 127.0 / 255.0, opacity: 0.4, isDark: false))
            XCTAssertEqual(ForkAppearance.upstream.resolvedPlateInk(upstream: theme.zoneDivider, systemIsDark: systemIsDark),
                           theme.zoneDivider)
            XCTAssertEqual(ForkAppearance.upstream.resolvedDotTint(upstream: theme.runningDot, systemIsDark: systemIsDark),
                           theme.runningDot)
        }
    }

    func testDarkBarIsDarkAndStrongerThanUpstreamsTintByDefault() {
        var appearance = ForkAppearance()
        appearance.barTint = .dark
        let plate = appearance.resolvedBarPlate(upstreamOpacity: upstreamOpacity, systemIsDark: false)
        XCTAssertTrue(plate.isDark)
        XCTAssertLessThan(plate.white, 0.15)
        XCTAssertGreaterThan(plate.opacity, upstreamOpacity)
    }

    func testOpacityAppliesToBothTints() {
        var appearance = ForkAppearance()
        appearance.barOpacity = 0.1
        XCTAssertEqual(appearance.resolvedBarPlate(upstreamOpacity: upstreamOpacity, systemIsDark: false).opacity, 0.1)
        XCTAssertFalse(appearance.resolvedBarPlate(upstreamOpacity: upstreamOpacity, systemIsDark: false).isDark)
        appearance.barTint = .dark
        XCTAssertEqual(appearance.resolvedBarPlate(upstreamOpacity: upstreamOpacity, systemIsDark: false).opacity, 0.1)
    }

    func testFollowSystemTracksTheSystem() {
        var appearance = ForkAppearance()
        appearance.barTint = .system
        XCTAssertFalse(appearance.resolvedBarPlate(upstreamOpacity: upstreamOpacity, systemIsDark: false).isDark)
        XCTAssertTrue(appearance.resolvedBarPlate(upstreamOpacity: upstreamOpacity, systemIsDark: true).isDark)
    }

    /// Everything drawn straight on the plate has to stay visible on a dark bar.
    func testInkOnADarkBarTurnsWhite() {
        var appearance = ForkAppearance()
        appearance.barTint = .dark
        XCTAssertEqual(appearance.resolvedPlateInk(upstream: theme.zoneDivider, systemIsDark: false).base, .white)
        XCTAssertEqual(appearance.resolvedDotTint(upstream: theme.runningDot, systemIsDark: false)?.base, .white)
        XCTAssertEqual(appearance.resolvedCardLabel(upstream: theme.labelActive, systemIsDark: false).base, .white,
                       "a light card is translucent: its title sits on the dark plate")
        let active = appearance.resolvedCardLabel(upstream: theme.labelActive, systemIsDark: false)
        let inactive = appearance.resolvedCardLabel(upstream: theme.labelInactive, systemIsDark: false)
        XCTAssertGreaterThan(active.opacity, inactive.opacity)
    }

    func testAnExplicitDotColourWinsOverTheBarsTint() {
        var appearance = ForkAppearance()
        appearance.barTint = .dark
        appearance.dotColor = .black
        XCTAssertEqual(appearance.resolvedDotTint(upstream: theme.runningDot, systemIsDark: false)?.base, .black)
    }

    func testPersistsAndRejectsOutOfRange() {
        let suiteName = "com.tungsten.edge.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        var appearance = ForkAppearance()
        appearance.barTint = .system
        appearance.barOpacity = 0.75
        ForkAppearanceStorage.save(appearance, to: defaults)
        XCTAssertEqual(ForkAppearanceStorage.load(from: defaults), appearance)

        defaults.set(3, forKey: ForkAppearanceStorage.Keys.barOpacity)
        defaults.set("purple", forKey: ForkAppearanceStorage.Keys.barTint)
        XCTAssertEqual(ForkAppearanceStorage.load(from: defaults), .upstream)
    }
}
