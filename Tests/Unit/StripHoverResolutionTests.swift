import XCTest
@testable import NitiaDock

/// Pure decision of "which card the pointer is over". Replaces each card's own `.onHover`; the cause, the
/// measurements and the two problems it fixes (missed cards on fast sweeps / direction-dependent switch
/// boundary) are in the `StripHoverResolution` comment.
final class StripHoverResolutionTests: XCTestCase {
    /// A row of natively spaced icon cards: width 40, spacing 2, center spacing 42.
    private let bar: [String: CGRect] = [
        "a": CGRect(x: 0,  y: 0, width: 40, height: 54),
        "b": CGRect(x: 42, y: 0, width: 40, height: 54),
        "c": CGRect(x: 84, y: 0, width: 40, height: 54)
    ]
    private let midY: CGFloat = 27

    private func hit(_ x: CGFloat, _ frames: [String: CGRect]? = nil) -> String? {
        StripHoverResolution.chip(at: CGPoint(x: x, y: midY), frames: frames ?? bar)
    }

    func testPointerInsideACardHitsThatCard() {
        XCTAssertEqual(hit(20), "a")
        XCTAssertEqual(hit(62), "b")
        XCTAssertEqual(hit(104), "c")
    }

    // MARK: - Boundary: one hard line, independent of direction

    /// **This is the goal of this round.** Before, a 2pt dead zone separated two cards' hit rects and the
    /// handover needed the pointer fully inside the next card, so the switch point depended on direction:
    /// measured, moving right it sat at the right card's left edge, moving left it sat left of the midpoint,
    /// 3.5pt of hysteresis (the boundary felt unfixed and not crisp). Now the gap is bridged and the switch
    /// point is the gap's middle, 41, the same number both ways.
    func testTheSwitchPointIsExactlyTheMiddleOfTheGap() {
        XCTAssertEqual(hit(40.4), "a", "the left half of the gap still belongs to the left card")
        XCTAssertEqual(hit(41.6), "b", "the right half of the gap belongs to the right card")
    }

    /// **No part of the gap is ownerless**: those 2pt used to be a "nobody"
    /// in-between state, and sliding slowly across showed "A → none → B".
    func testNoDeadZoneAnywhereInsideTheGap() {
        for step in stride(from: CGFloat(40), through: 42, by: 0.1) {
            XCTAssertNotNil(hit(step), "x=\(step) inside the gap should not be unclaimed")
        }
    }

    /// With cards of unequal width side by side, the gap is decided by distance **to the card edge**, not to
    /// the card center: by center the narrow card would take more, and the boundary would not be mid-gap.
    func testGapIsSplitByEdgeDistanceNotByCardCentre() {
        let mixed: [String: CGRect] = [
            "wide": CGRect(x: 0, y: 0, width: 160, height: 54),
            "icon": CGRect(x: 162, y: 0, width: 40, height: 54)
        ]
        XCTAssertEqual(hit(160.4, mixed), "wide")
        XCTAssertEqual(hit(161.6, mixed), "icon")
    }

    // MARK: - Wide gaps still show nothing

    /// The 9pt gap at a zone divider and the padding at both ends of the taskbar: after bridging 2pt on
    /// each side the middle is still empty, so hovering there owns no card (native behaves the same).
    func testWideGapsStayUnowned() {
        let zones: [String: CGRect] = [
            "left":  CGRect(x: 0,  y: 0, width: 40, height: 54),
            "right": CGRect(x: 49, y: 0, width: 40, height: 54)   // 9pt zone gap
        ]
        XCTAssertNil(hit(44.5, zones), "nobody should own the middle of a zone gap")
        XCTAssertNil(hit(-5, zones), "outside the padding at the bar's left end")
        XCTAssertNil(hit(200, zones), "outside the padding at the bar's right end")
    }

    /// No vertical bridging: leaving the bar vertically must own nothing, otherwise the edge wake / capsule
    /// band misfires.
    func testVerticalIsNotBridged() {
        XCTAssertNil(StripHoverResolution.chip(at: CGPoint(x: 20, y: -3), frames: bar))
        XCTAssertNil(StripHoverResolution.chip(at: CGPoint(x: 20, y: 80), frames: bar))
    }

    /// Bridging scales with the tier (small tier: narrower cards and gaps). Passing 0 degrades to "must be
    /// fully inside the card", i.e. the old direction-dependent behavior; this also pins that the parameter
    /// is really used.
    func testGapBridgeIsAParameter() {
        XCTAssertNil(StripHoverResolution.chip(at: CGPoint(x: 41, y: midY),
                                               frames: bar, gapBridge: 0))
        XCTAssertNotNil(StripHoverResolution.chip(at: CGPoint(x: 41, y: midY),
                                                  frames: bar, gapBridge: 2))
    }

    /// Bridging equals the card spacing exactly, they are the same thing: half a gap added on each side meets
    /// in the middle.
    func testBridgeMatchesTheChipSpacing() {
        XCTAssertEqual(StripHoverResolution.defaultGapBridge, ChipPillMetrics.chipSpacing)
    }

    /// Unmeasured frames (`.zero`) take no part, otherwise an extra owner appears near the origin.
    func testUnmeasuredFramesAreIgnored() {
        XCTAssertNil(StripHoverResolution.chip(at: .zero, frames: ["x": .zero]))
    }

    /// An empty table does not crash and claims nothing.
    func testEmptyFrames() {
        XCTAssertNil(hit(20, [:]))
    }

    /// fork: overlapping frames (a negative gap between one app's cards) go to the nearer centre, not to
    /// whichever id sorts first.
    func testOverlappingFramesGoToTheNearerCentre() {
        let overlapping: [String: CGRect] = [
            "a": CGRect(x: 0, y: 0, width: 100, height: 34),
            "b": CGRect(x: 92, y: 0, width: 100, height: 34),   // overlaps a by 8
        ]
        XCTAssertEqual(StripHoverResolution.chip(at: CGPoint(x: 94, y: 10), frames: overlapping), "a")
        XCTAssertEqual(StripHoverResolution.chip(at: CGPoint(x: 98, y: 10), frames: overlapping), "b")
        XCTAssertEqual(StripHoverResolution.chip(at: CGPoint(x: 50, y: 10), frames: overlapping), "a")
        XCTAssertEqual(StripHoverResolution.chip(at: CGPoint(x: 150, y: 10), frames: overlapping), "b")
    }
}

