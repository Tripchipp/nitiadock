import CoreGraphics
import XCTest

/// fork: maximum card width, title mode and equal-width cards.
///
/// The drawn card, the hover scale cap and the tooltip anchor all derive from
/// `ChipPillMetrics.width(title:scale:)`; these tests check that the overrides move all three
/// together, which is what keeps overlays and the pressed/hover scaling aligned.
@MainActor
final class ForkCardWidthTests: XCTestCase {
    private let short = "Notes"
    private let long = "A very long window title that certainly does not fit into any reasonable card width at all"

    override func tearDown() {
        ForkAppearanceModel.shared.resetForTesting()
        super.tearDown()
    }

    private func apply(_ edit: (inout ForkAppearance) -> Void) {
        var appearance = ForkAppearance()
        edit(&appearance)
        ForkAppearanceModel.shared.apply(appearance)
    }

    func testCardChromeMatchesUpstreamsPillConstants() {
        XCTAssertEqual(CGFloat(ForkAppearance.cardChrome),
                       2 * ChipPillMetrics.horizontalPadding + ChipPillMetrics.iconSlot + ChipPillMetrics.iconSpacing)
        XCTAssertEqual(CGFloat(ForkAppearance.upstreamTitleCap), WindowTitleTextMetrics.maximumWidth)
    }

    func testUntouchedMetricsAreUpstreams() {
        for scale in DockSize.allCases.map(\.scale) {
            XCTAssertEqual(WindowTitleTextMetrics.maximumWidth(for: scale), 140 * scale)
            let intrinsic = WindowTitleTextMetrics.intrinsicWidth(of: short, scale: scale)
            XCTAssertEqual(ChipPillMetrics.labelWidth(title: short, scale: scale), ceil(intrinsic))
            XCTAssertEqual(ChipPillMetrics.labelWidth(title: long, scale: scale), ceil(140 * scale))
            XCTAssertTrue(ChipPillMetrics.labelTruncates(title: long, scale: scale))
            XCTAssertFalse(ChipPillMetrics.labelTruncates(title: short, scale: scale))
        }
    }

    func testMaximumCardWidthCapsTheWholeCard() {
        apply { $0.maxCardWidth = 120 }
        XCTAssertEqual(ChipPillMetrics.width(title: long, scale: 1), 120)
        XCTAssertTrue(ChipPillMetrics.labelTruncates(title: long, scale: 1))
        // A short title is still only as wide as it needs.
        XCTAssertLessThan(ChipPillMetrics.width(title: "Hi", scale: 1), 120)

        apply { $0.maxCardWidth = 320 }
        XCTAssertEqual(ChipPillMetrics.width(title: long, scale: 1), 320)
    }

    func testMaximumCardWidthScalesWithTheSizeTier() {
        apply { $0.maxCardWidth = 200 }
        let scale = DockSize.extraLarge.scale
        XCTAssertEqual(ChipPillMetrics.width(title: long, scale: scale), ceil((200 - 48) * scale) + 48 * scale,
                       accuracy: 0.001)
    }

    func testFitToTextRemovesTheCap() {
        apply { $0.titleMode = .fit }
        let intrinsic = WindowTitleTextMetrics.intrinsicWidth(of: long, scale: 1)
        XCTAssertGreaterThan(intrinsic, 140)
        XCTAssertEqual(ChipPillMetrics.labelWidth(title: long, scale: 1), ceil(intrinsic))
        XCTAssertFalse(ChipPillMetrics.labelTruncates(title: long, scale: 1))
        XCTAssertTrue(ChipPillMetrics.width(title: long, scale: 1).isFinite)
    }

    func testMiddleTruncationKeepsUpstreamsWidths() {
        apply { $0.titleMode = .middle }
        XCTAssertTrue(ForkAppearanceModel.current.truncatesTitleInMiddle)
        XCTAssertEqual(ChipPillMetrics.labelWidth(title: long, scale: 1), 140)
    }

    func testEqualWidthCardsAllTakeTheMaximumWidth() {
        apply { $0.equalWidthCards = true }
        XCTAssertEqual(ChipPillMetrics.width(title: short, scale: 1), 188)
        XCTAssertEqual(ChipPillMetrics.width(title: long, scale: 1), 188)
        // Only the long one actually needs an ellipsis.
        XCTAssertFalse(ChipPillMetrics.labelTruncates(title: short, scale: 1))
        XCTAssertTrue(ChipPillMetrics.labelTruncates(title: long, scale: 1))

        apply { $0.equalWidthCards = true; $0.maxCardWidth = 150 }
        XCTAssertEqual(ChipPillMetrics.width(title: short, scale: 1), 150)
    }

    func testEqualWidthOverridesFitToText() {
        apply { $0.equalWidthCards = true; $0.titleMode = .fit }
        XCTAssertEqual(ChipPillMetrics.width(title: long, scale: 1), 188)
        XCTAssertTrue(ChipPillMetrics.labelTruncates(title: long, scale: 1))
    }

    func testTooltipAnchorAndHoverScaleFollowTheOverriddenWidth() {
        apply { $0.equalWidthCards = true; $0.maxCardWidth = 300 }
        let card = CGRect(x: 100, y: 0, width: 308, height: 54)
        let pill = ChipPillMetrics.pillRect(inCard: card, title: short, scale: 1)
        XCTAssertEqual(pill.width, 300)
        XCTAssertEqual(pill.midX, card.midX)

        // The hover scale is capped per side, so a wider card scales less; 3pt per side at most.
        let cardWidth = ChipPillMetrics.width(title: short, scale: 1) + 2 * ChipPillMetrics.titledCardInset
        let hover = ChipPillMetrics.quietHoverScale(forCardWidth: cardWidth, scale: 1)
        XCTAssertEqual((hover - 1) * cardWidth / 2, ChipPillMetrics.quietHoverEdgeBudget, accuracy: 0.001)
    }

    func testLayoutIdentityChangesOnlyForWidthAffectingOptions() {
        let base = ForkAppearance()
        var colourOnly = base
        colourOnly.dotColor = .accent
        colourOnly.cardOpacity = 0.5
        XCTAssertEqual(colourOnly.layoutIdentity, base.layoutIdentity)

        for edit: (inout ForkAppearance) -> Void in [
            { $0.titleFontOffset = 1 }, { $0.maxCardWidth = 100 }, { $0.titleMode = .fit }, { $0.equalWidthCards = true },
        ] {
            var changed = base
            edit(&changed)
            XCTAssertNotEqual(changed.layoutIdentity, base.layoutIdentity)
        }
    }

    func testWidthOptionsPersist() {
        let suiteName = "com.tungsten.edge.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        var appearance = ForkAppearance()
        appearance.maxCardWidth = 240
        appearance.titleMode = .middle
        appearance.equalWidthCards = true
        ForkAppearanceStorage.save(appearance, to: defaults)
        XCTAssertEqual(ForkAppearanceStorage.load(from: defaults), appearance)

        defaults.set(5000, forKey: ForkAppearanceStorage.Keys.maxCardWidth)
        XCTAssertNil(ForkAppearanceStorage.load(from: defaults).maxCardWidth, "out of range falls back to upstream")
    }
}
