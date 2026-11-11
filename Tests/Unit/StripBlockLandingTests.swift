import XCTest
@testable import NitiaDock

/// Landing decision for dragging a whole drawer block into the taskbar. It used to be a whole-frame
/// `contains`; measured (2026-08-18 drag logs), the first landing degraded to "land at the end" 100% of the
/// time, because the conversion box deliberately extends 16pt above the bar's top edge and a whole-frame hit
/// always fails outside the bar. What is pinned here is "**look only at x, always have an answer**".
final class StripBlockLandingTests: XCTestCase {
    /// Three natively spaced cards in the live zone: width 40, spacing 2, centers at 20 / 62 / 104.
    private let live: [String: CGRect] = [
        "a": CGRect(x: 0,   y: 0, width: 40, height: 54),
        "b": CGRect(x: 42,  y: 0, width: 40, height: 54),
        "c": CGRect(x: 84,  y: 0, width: 40, height: 54)
    ]

    private func hit(_ x: CGFloat, _ frames: [String: CGRect]? = nil) -> String {
        guard let t = StripBlockLanding.target(pointerX: x, frames: frames ?? live) else { return "nil" }
        return "\(t.id)\(t.after ? ">" : "<")"
    }

    func testLandsOnTheHalfThePointerIsIn() {
        XCTAssertEqual(hit(10), "a<")
        XCTAssertEqual(hit(30), "a>")
        XCTAssertEqual(hit(55), "b<")
        XCTAssertEqual(hit(70), "b>")
    }

    /// **The core of this round**: above the bar's top edge, the 2pt gaps between cards, above the
    /// messaging/folder zones. These positions used to have "no target", so the block stayed put or landed at
    /// the end. Now each must yield the nearest insertion slot.
    func testEveryPointerPositionResolvesToASlot() {
        for x in stride(from: CGFloat(-200), through: 400, by: 1) {
            XCTAssertNotEqual(hit(x), "nil", "x=\(x) must be able to land")
        }
    }

    /// In a gap the nearer card center wins: left of the gap's middle goes to the right side of the left
    /// card, right of it to the left side of the right card. Those are in fact the **same insertion slot**,
    /// so no decision in a gap can skip a slot.
    func testTheGapResolvesToTheSameInsertionSlotFromEitherSide() {
        XCTAssertEqual(hit(40.9), "a>")
        XCTAssertEqual(hit(43.1), "b<")
    }

    /// Cursor far left of the live zone (over the messaging/folder zones) → insert **before** the leftmost
    /// card, not at the end. The gap should open where it is visible, on the side near the finger.
    func testFarLeftInsertsBeforeTheFirstCard() {
        XCTAssertEqual(hit(-500), "a<")
    }

    /// Far right → after the rightmost card.
    func testFarRightInsertsAfterTheLastCard() {
        XCTAssertEqual(hit(9999), "c>")
    }

    /// y takes no part at all: a decision in the 16pt tolerance band above the bar's top edge must still
    /// have an answer. (Expressed with frames whose y is outside the bar: a matching x should still hit.)
    func testVerticalPositionIsIrrelevantByConstruction() {
        // target's signature has no y at all; this pins it down as "same x, same result".
        let shifted = live.mapValues { $0.offsetBy(dx: 0, dy: 500) }
        for x in stride(from: CGFloat(-50), through: 200, by: 7) {
            XCTAssertEqual(hit(x, shifted), hit(x), "x=\(x) landing should not depend on vertical position")
        }
    }

    /// Unmeasured frames take no part, otherwise an extra landing slot appears near the origin.
    func testUnmeasuredFramesAreIgnored() {
        XCTAssertEqual(hit(500, ["ghost": .zero]), "nil")
        XCTAssertEqual(hit(50, ["a": live["a"]!, "ghost": .zero]), "a>")
    }

    /// Returns nil only when the live zone is really empty (the caller has nowhere to insert then anyway).
    func testEmptyLiveZone() {
        XCTAssertEqual(hit(50, [:]), "nil")
    }

    /// Equal distances must give a deterministic result: dictionary iteration order is undefined, and without
    /// an order it flips between frames.
    func testTiesAreResolvedDeterministically() {
        let symmetric: [String: CGRect] = [
            "z": CGRect(x: 0,  y: 0, width: 40, height: 54),
            "a": CGRect(x: 60, y: 0, width: 40, height: 54)
        ]
        // x = 40 is 20 from both centers.
        let first = hit(40, symmetric)
        for _ in 0..<50 { XCTAssertEqual(hit(40, symmetric), first) }
    }
}
