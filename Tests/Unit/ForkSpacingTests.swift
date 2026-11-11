import CoreGraphics
import XCTest

/// fork: item spacing and edge padding, and the three upstream rules that must move with the gap.
final class ForkSpacingTests: XCTestCase {
    private func appearance(spacing: Double? = nil, edge: Double? = nil) -> ForkAppearance {
        var value = ForkAppearance()
        value.itemSpacing = spacing
        value.edgePadding = edge
        return value
    }

    func testUntouchedSpacingIsUpstreamsEverywhere() {
        let untouched = ForkAppearance.upstream
        XCTAssertEqual(untouched.resolvedItemSpacing(), ChipPillMetrics.chipSpacing)
        XCTAssertEqual(untouched.resolvedEdgePadding(), 20)
        XCTAssertEqual(untouched.resolvedContextMenuGapThreshold(), StripContextMenuZone.defaultMinimumGapWidth)
        XCTAssertEqual(untouched.resolvedHoverGapBridge(), StripHoverResolution.defaultGapBridge)
        XCTAssertEqual(untouched.resolvedEdgeFadeWidth(), 16)
    }

    /// Upstream's invariant, for every spacing the slider offers: ordinary gap < threshold < divider gap.
    /// Break it one way and a near-miss right-click on an icon opens the bar's menu instead of the
    /// app's; break it the other way and right-clicking the bar does nothing at all.
    func testContextMenuThresholdStaysBetweenAnOrdinaryGapAndADividerGap() {
        for spacing in stride(from: 0.0, through: 24.0, by: 1.0) {
            let value = appearance(spacing: spacing)
            let gap = value.resolvedItemSpacing()
            let dividerGap = gap + 5 + gap
            XCTAssertGreaterThan(value.resolvedContextMenuGapThreshold(), gap, "spacing \(spacing)")
            XCTAssertLessThan(value.resolvedContextMenuGapThreshold(), dividerGap, "spacing \(spacing)")
        }
    }

    func testRightClickBehavesTheSameWithAWideGap() {
        let value = appearance(spacing: 16)
        let threshold = value.resolvedContextMenuGapThreshold()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 54)
        // Two icons 16pt apart, then a divider gap (16 + 5 + 16), then a third icon.
        let frames = [CGRect(x: 20, y: 0, width: 40, height: 54),
                      CGRect(x: 76, y: 0, width: 40, height: 54),
                      CGRect(x: 153, y: 0, width: 40, height: 54)]
        XCTAssertFalse(StripContextMenuZone.claims(point: CGPoint(x: 68, y: 20), chipFrames: frames,
                                                   bounds: bounds, minimumGapWidth: threshold),
                       "an ordinary gap, however wide the user made it, is not the bar's")
        XCTAssertTrue(StripContextMenuZone.claims(point: CGPoint(x: 134, y: 20), chipFrames: frames,
                                                  bounds: bounds, minimumGapWidth: threshold),
                      "the divider gap still is")
        XCTAssertTrue(StripContextMenuZone.claims(point: CGPoint(x: 5, y: 20), chipFrames: frames,
                                                  bounds: bounds, minimumGapWidth: threshold))
    }

    func testHoverHasNoDeadZoneInAWideGapAndSplitsItAtTheMidpoint() {
        let value = appearance(spacing: 20)
        let bridge = value.resolvedHoverGapBridge()
        let frames = ["a": CGRect(x: 20, y: 0, width: 40, height: 54),
                      "b": CGRect(x: 80, y: 0, width: 40, height: 54)]
        for x in stride(from: CGFloat(60), through: 80, by: 1) {
            XCTAssertNotNil(StripHoverResolution.chip(at: CGPoint(x: x, y: 20), frames: frames, gapBridge: bridge), "x=\(x)")
        }
        XCTAssertEqual(StripHoverResolution.chip(at: CGPoint(x: 66, y: 20), frames: frames, gapBridge: bridge), "a")
        XCTAssertEqual(StripHoverResolution.chip(at: CGPoint(x: 74, y: 20), frames: frames, gapBridge: bridge), "b")
    }

    func testHoverStillIgnoresADividerGap() {
        for spacing in [0.0, 2, 8, 24] {
            let value = appearance(spacing: spacing)
            let gap = value.resolvedItemSpacing()
            XCTAssertLessThan(2 * value.resolvedHoverGapBridge(), gap + 5 + gap,
                              "spacing \(spacing): the middle of a divider gap must belong to nobody")
        }
    }

    func testEdgeFadeNeverReachesARestingCard() {
        for edge in stride(from: 6.0, through: 60.0, by: 1.0) {
            let value = appearance(edge: edge)
            XCTAssertLessThan(value.resolvedEdgeFadeWidth(), value.resolvedEdgePadding())
            XCTAssertLessThanOrEqual(value.resolvedEdgeFadeWidth(), 16)
        }
    }

    func testPersistsAndRejectsOutOfRange() {
        let suiteName = "com.tungsten.edge.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let value = appearance(spacing: 10, edge: 8)
        ForkAppearanceStorage.save(value, to: defaults)
        XCTAssertEqual(ForkAppearanceStorage.load(from: defaults), value)

        defaults.set(-4, forKey: ForkAppearanceStorage.Keys.itemSpacing)
        defaults.set(2, forKey: ForkAppearanceStorage.Keys.edgePadding)
        XCTAssertEqual(ForkAppearanceStorage.load(from: defaults), .upstream)
        XCTAssertEqual(value.layoutIdentity, ForkAppearance.upstream.layoutIdentity, "spacing does not change card widths")
    }

    // MARK: Gap between an app's windows

    func testSameAppGapFollowsItemSpacingUntilSet() {
        XCTAssertEqual(ForkAppearance.upstream.resolvedSameAppSpacing(), ChipPillMetrics.chipSpacing)
        XCTAssertEqual(appearance(spacing: 9).resolvedSameAppSpacing(), 9)
        var value = appearance(spacing: 9)
        value.sameAppSpacing = 3
        XCTAssertEqual(value.resolvedSameAppSpacing(), 3)
        XCTAssertEqual(value.resolvedItemSpacing(), 9, "the gap between different apps is its own setting")
    }

    func testSameAppGapPersistsAndRejectsOutOfRange() {
        let suiteName = "com.tungsten.edge.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        var value = ForkAppearance()
        value.sameAppSpacing = 12
        ForkAppearanceStorage.save(value, to: defaults)
        XCTAssertEqual(ForkAppearanceStorage.load(from: defaults).sameAppSpacing, 12)
        XCTAssertFalse(ForkAppearanceStorage.load(from: defaults).isUpstream)

        defaults.set(99, forKey: ForkAppearanceStorage.Keys.sameAppSpacing)
        XCTAssertEqual(ForkAppearanceStorage.load(from: defaults), .upstream)
        defaults.set(-9, forKey: ForkAppearanceStorage.Keys.sameAppSpacing)
        XCTAssertEqual(ForkAppearanceStorage.load(from: defaults), .upstream, "below -8 the card pills would overlap")
        ForkAppearanceStorage.save(.upstream, to: defaults)
        XCTAssertNil(defaults.object(forKey: ForkAppearanceStorage.Keys.sameAppSpacing), "untouched leaves no trace")
    }

    func testSameAppGapMayBeNegativeButItemSpacingMayNot() {
        var value = ForkAppearance()
        value.sameAppSpacing = -8
        XCTAssertEqual(value.sanitized.sameAppSpacing, -8)
        XCTAssertEqual(value.resolvedSameAppSpacing(), -8)
        XCTAssertEqual(value.resolvedItemSpacing(), ChipPillMetrics.chipSpacing)
        var tooTight = ForkAppearance()
        tooTight.itemSpacing = -1
        XCTAssertNil(tooTight.sanitized.itemSpacing, "item spacing also drives hover and right-click rules, so it stays at 0 or more")
    }

    func testSameAppFollowersAreWindowCardsRightAfterTheSameApp() {
        typealias E = ForkSameAppGap.Entry
        let entries = [
            E(id: "w1", windowBundleID: "a"),
            E(id: "w2", windowBundleID: "a"),
            E(id: "w3", windowBundleID: "a"),
            E(id: "d", windowBundleID: nil),      // divider breaks the pair
            E(id: "w4", windowBundleID: "a"),
            E(id: "w5", windowBundleID: "b"),     // another app
            E(id: "w6", windowBundleID: "a"),
            E(id: "w7", windowBundleID: "a"),
        ]
        XCTAssertEqual(ForkSameAppGap.followerIDs(in: entries), ["w2", "w3", "w7"])
        XCTAssertEqual(ForkSameAppGap.followerIDs(in: []), [])
        XCTAssertEqual(ForkSameAppGap.followerIDs(in: [E(id: "x", windowBundleID: "")]), [])
    }
}

