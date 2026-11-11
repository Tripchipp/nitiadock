import CoreGraphics
import XCTest

/// fork: the Appearance override layer. The load-bearing promise is the first test: an untouched
/// option resolves to exactly what upstream draws.
@MainActor
final class ForkAppearanceTests: XCTestCase {
    private let theme = DockThemeTokens.standard

    override func tearDown() {
        ForkAppearanceModel.shared.resetForTesting()
        super.tearDown()
    }

    func testUntouchedAppearanceResolvesToUpstreamValues() {
        let appearance = ForkAppearance.upstream
        XCTAssertTrue(appearance.isUpstream)
        XCTAssertEqual(appearance.resolvedDotTint(upstream: theme.runningDot), theme.runningDot)
        XCTAssertEqual(appearance.resolvedDotDiameter(), 4)
        for systemIsDark in [false, true] {
            XCTAssertEqual(appearance.resolvedCardFill(upstream: theme.chipPillFill, systemIsDark: systemIsDark),
                           theme.chipPillFill)
            XCTAssertEqual(appearance.resolvedCardLabel(upstream: theme.labelActive, systemIsDark: systemIsDark),
                           theme.labelActive)
        }
        XCTAssertEqual(appearance.resolvedCardCornerRadius(scale: 1), 10)
        XCTAssertEqual(appearance.resolvedCardCornerRadius(scale: 1.5), 15)
        for scale in DockSize.allCases.map(\.scale) {
            let upstream = max(10, 12 * scale)
            XCTAssertEqual(appearance.resolvedTitleFontSize(upstream: upstream), upstream)
        }
    }

    func testDotColorChoices() {
        var appearance = ForkAppearance()
        appearance.dotColor = .white
        XCTAssertEqual(appearance.resolvedDotTint(upstream: theme.runningDot)?.base, .white)
        appearance.dotColor = .black
        XCTAssertEqual(appearance.resolvedDotTint(upstream: theme.runningDot)?.base, .black)
        XCTAssertGreaterThan(appearance.resolvedDotTint(upstream: theme.runningDot)!.opacity, theme.runningDot.opacity,
                             "an explicit black must be stronger than upstream's half-black, or the choice is invisible")
        appearance.dotColor = .accent
        XCTAssertNil(appearance.resolvedDotTint(upstream: theme.runningDot), "nil hands the accent colour to SwiftUI")
    }

    func testDotSizesGrowInOrder() {
        let sizes = ForkAppearance.DotSize.allCases.map(\.diameter)
        XCTAssertEqual(sizes, sizes.sorted())
        XCTAssertEqual(Set(sizes).count, sizes.count)
    }

    func testCardOpacityKeepsUpstreamsHoverRelationship() {
        var appearance = ForkAppearance()
        appearance.cardOpacity = 0.5
        let fill = appearance.resolvedCardFill(upstream: theme.chipPillFill, systemIsDark: false)
        XCTAssertEqual(fill.normal, .white(0.5))
        XCTAssertEqual(fill.emphasized.opacity, 0.7, accuracy: 1e-9)

        appearance.cardOpacity = 0.9
        XCTAssertEqual(appearance.resolvedCardFill(upstream: theme.chipPillFill, systemIsDark: false).emphasized.opacity, 1)
    }

    func testDarkCardFlipsFillAndTextTogether() {
        var appearance = ForkAppearance()
        appearance.cardTint = .dark
        let fill = appearance.resolvedCardFill(upstream: theme.chipPillFill, systemIsDark: false)
        XCTAssertEqual(fill.normal, .black(ForkAppearance.darkCardDefaultOpacity))
        let active = appearance.resolvedCardLabel(upstream: theme.labelActive, systemIsDark: false)
        let inactive = appearance.resolvedCardLabel(upstream: theme.labelInactive, systemIsDark: false)
        XCTAssertEqual(active.base, .white)
        XCTAssertEqual(inactive.base, .white)
        XCTAssertGreaterThan(active.opacity, inactive.opacity, "on-desktop vs minimised must stay distinguishable")
    }

    func testFollowSystemTintTracksTheSystem() {
        var appearance = ForkAppearance()
        appearance.cardTint = .system
        XCTAssertEqual(appearance.resolvedCardFill(upstream: theme.chipPillFill, systemIsDark: false), theme.chipPillFill)
        XCTAssertEqual(appearance.resolvedCardFill(upstream: theme.chipPillFill, systemIsDark: true).normal.base, .black)
        XCTAssertEqual(appearance.resolvedCardLabel(upstream: theme.labelActive, systemIsDark: true).base, .white)
    }

    func testTitleFontOffsetAppliesAfterUpstreamsFloorAndNeverGoesBelowEightPoints() {
        var appearance = ForkAppearance()
        appearance.titleFontOffset = 2
        XCTAssertEqual(appearance.resolvedTitleFontSize(upstream: 12), 14)
        appearance.titleFontOffset = -2
        XCTAssertEqual(appearance.resolvedTitleFontSize(upstream: 12), 10)
        XCTAssertEqual(appearance.resolvedTitleFontSize(upstream: 9), 8)
    }

    func testSanitizedDropsOutOfRangeNumbers() {
        var appearance = ForkAppearance()
        appearance.cardOpacity = 4
        appearance.cardCornerRadius = -1
        appearance.titleFontOffset = 9
        XCTAssertEqual(appearance.sanitized, .upstream)

        appearance.cardOpacity = .nan
        XCTAssertNil(appearance.sanitized.cardOpacity)
    }

    // MARK: Storage

    func testStorageRoundTripsAndUntouchedOptionsLeaveNoKeys() {
        let defaults = makeDefaults()
        XCTAssertEqual(ForkAppearanceStorage.load(from: defaults), .upstream)

        var appearance = ForkAppearance()
        appearance.dotColor = .accent
        appearance.cardOpacity = 0.4
        ForkAppearanceStorage.save(appearance, to: defaults)
        XCTAssertEqual(ForkAppearanceStorage.load(from: defaults), appearance)
        XCTAssertNil(defaults.object(forKey: ForkAppearanceStorage.Keys.dotSize))
        XCTAssertNil(defaults.object(forKey: ForkAppearanceStorage.Keys.cardCornerRadius))

        ForkAppearanceStorage.save(.upstream, to: defaults)
        XCTAssertNil(defaults.object(forKey: ForkAppearanceStorage.Keys.dotColor), "reset removes the key")
        XCTAssertNil(defaults.object(forKey: ForkAppearanceStorage.Keys.cardOpacity))
    }

    func testStorageIgnoresGarbage() {
        let defaults = makeDefaults()
        defaults.set("purple", forKey: ForkAppearanceStorage.Keys.dotColor)
        defaults.set("a lot", forKey: ForkAppearanceStorage.Keys.cardOpacity)
        defaults.set(true, forKey: ForkAppearanceStorage.Keys.cardCornerRadius)
        defaults.set(40, forKey: ForkAppearanceStorage.Keys.titleFontOffset)
        XCTAssertEqual(ForkAppearanceStorage.load(from: defaults), .upstream)
    }

    // MARK: Store + shared model

    func testSettingsStorePersistsAppearance() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(store.appearance, .upstream)

        var appearance = ForkAppearance()
        appearance.dotSize = .large
        appearance.titleFontOffset = 1
        store.setAppearance(appearance)
        XCTAssertEqual(AppSettingsStore(defaults: defaults).appearance, appearance)
    }

    func testScratchStoresNeverRepaintTheSharedModel() {
        let store = AppSettingsStore(defaults: makeDefaults())
        var appearance = ForkAppearance()
        appearance.titleFontOffset = 2
        store.setAppearance(appearance)
        XCTAssertEqual(ForkAppearanceModel.current, .upstream)
        XCTAssertEqual(ForkAppearanceModel.shared.value, .upstream)
    }

    func testTitleMetricsMeasureWithTheSameFontTheCardDraws() {
        let scale = DockSize.medium.scale
        let title = "A reasonably long window title"
        let before = WindowTitleTextMetrics.intrinsicWidth(of: title, scale: scale)
        XCTAssertEqual(WindowTitleTextMetrics.fontSize(scale: scale), 12)

        var appearance = ForkAppearance()
        appearance.titleFontOffset = 2
        ForkAppearanceModel.shared.apply(appearance)
        XCTAssertEqual(WindowTitleTextMetrics.fontSize(scale: scale), 14)
        XCTAssertEqual(WindowTitleTextMetrics.font(scale: scale).pointSize, 14)
        XCTAssertGreaterThan(WindowTitleTextMetrics.intrinsicWidth(of: title, scale: scale), before)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "com.tungsten.edge.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
