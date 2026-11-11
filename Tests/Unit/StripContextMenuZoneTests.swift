import XCTest
@testable import NitiaDock

final class StripContextMenuZoneTests: XCTestCase {
    /// A typical taskbar at the medium baseline: 20pt inset, chips 40 wide with
    /// 2pt spacing, and a divider between chips 2 and 3 (5pt extra, 9pt gap).
    ///
    /// Numbers come from the real layout (`ChipPillMetrics.cardWidth` / `Style.chipSpacing`), but are
    /// **deliberately literals here**: this fixture is input for a pure function, and written as
    /// references it would change with the implementation and test nothing. Sync it by hand when changing
    /// layout constants; `testThresholdSeparatesBothGapsAtEveryTier` tells you if you missed one.
    private let bounds = CGRect(x: 0, y: 0, width: 300, height: 54)
    private let chips: [CGRect] = [
        CGRect(x: 20, y: 0, width: 40, height: 54),    // 20...60
        CGRect(x: 62, y: 0, width: 40, height: 54),    // 62...102 (2pt from the previous)
        CGRect(x: 111, y: 0, width: 40, height: 54),   // 111...151 (9pt from the previous: divider)
    ]
    private let gap = StripContextMenuZone.defaultMinimumGapWidth

    private func claims(x: CGFloat) -> Bool {
        StripContextMenuZone.claims(
            point: CGPoint(x: x, y: 26),
            chipFrames: chips,
            bounds: bounds,
            minimumGapWidth: gap
        )
    }

    func testLeftInsetClaims() {
        XCTAssertTrue(claims(x: 10))
    }

    func testRightInsetClaims() {
        XCTAssertTrue(claims(x: 250))
    }

    func testDividerGapClaims() {
        // The gap is 102...111, middle 106.5.
        XCTAssertTrue(claims(x: 106))
    }

    /// This is the **purpose** of this change: when aiming at an icon misses by a few pt into
    /// a narrow gap, better no reaction than a NitiaDock menu replacing that app's own menu.
    func testPlainChipGapDoesNotClaim() {
        // The gap is 60...62, only 2pt.
        XCTAssertFalse(claims(x: 61))
    }

    func testPointOnAChipDoesNotClaim() {
        XCTAssertFalse(claims(x: 40))
        XCTAssertFalse(claims(x: 82))
    }

    func testPointOutsideBoundsDoesNotClaim() {
        XCTAssertFalse(claims(x: -5))
        XCTAssertFalse(StripContextMenuZone.claims(
            point: CGPoint(x: 100, y: 999),
            chipFrames: chips,
            bounds: bounds,
            minimumGapWidth: gap
        ))
    }

    /// Not recognized before any chip is measured on the first frame: it is unknown whether
    /// the click is on an icon, and stealing that app's menu is worse than missing one popup.
    func testEmptyFramesDoNotClaim() {
        XCTAssertFalse(StripContextMenuZone.claims(
            point: CGPoint(x: 10, y: 26),
            chipFrames: [],
            bounds: bounds,
            minimumGapWidth: gap
        ))
    }

    /// Both gap kinds must be separable at all four tiers: threshold and geometry scale together.
    ///
    /// **This is the guardrail for `Style.chipSpacing`.** On 2026-08-16, when icon spacing was
    /// matched to native (center spacing 52→42pt, chipSpacing 8→2), the divider gap shrank from
    /// 21pt to 9pt while the threshold stayed at 12pt. That would make the divider gap
    /// unrecognizable too and break right-click on the whole taskbar. This test is what caught it.
    func testThresholdSeparatesBothGapsAtEveryTier() {
        for scale in DockSize.allCases.map(\.scale) {
            let plainGap: CGFloat = 2 * scale
            let dividerGap: CGFloat = (2 + 5 + 2) * scale
            let threshold: CGFloat = StripContextMenuZone.defaultMinimumGapWidth * scale
            XCTAssertLessThan(plainGap, threshold, "a plain gap should not be recognized at scale=\(scale)")
            XCTAssertGreaterThan(dividerGap, threshold, "the divider gap must be recognized at scale=\(scale)")
        }
    }

    /// Overlapping frames (frames expanded by the messaging zone, temporary positions while dragging) must
    /// not count as a gap.
    func testOverlappingFramesDoNotSynthesizeAGap() {
        let overlapping = [
            CGRect(x: 20, y: 0, width: 40, height: 54),   // 20...60
            CGRect(x: 52, y: 0, width: 40, height: 54),   // 52...92, overlaps the previous
            CGRect(x: 84, y: 0, width: 40, height: 54),   // 84...124, overlaps the previous
        ]
        for x in stride(from: CGFloat(21), to: 123, by: 3) {
            XCTAssertFalse(
                StripContextMenuZone.claims(
                    point: CGPoint(x: x, y: 26),
                    chipFrames: overlapping,
                    bounds: bounds,
                    minimumGapWidth: gap
                ),
                "x=\(x) is in a continuously covered area and should not count as a gap"
            )
        }
    }
}
