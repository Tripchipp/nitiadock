import XCTest
@testable import NitiaDock

final class StripWheelScrollTests: XCTestCase {
    private func input(dx: CGFloat = 0,
                       dy: CGFloat,
                       precise: Bool,
                       inverted: Bool) -> StripWheelScroll.Input {
        StripWheelScroll.Input(deltaX: dx, deltaY: dy,
                               hasPreciseDeltas: precise, isDirectionInverted: inverted)
    }

    // MARK: - Cases not taken over

    func testNoVerticalComponentIsNotClaimed() {
        XCTAssertNil(StripWheelScroll.horizontalStep(for: input(dx: 12, dy: 0, precise: true, inverted: true)))
        XCTAssertNil(StripWheelScroll.horizontalStep(for: input(dy: 0, precise: false, inverted: false)))
    }

    /// Mostly horizontal gestures must pass through to `NSScrollView`: its inertia and rubber-banding are
    /// native, taking over only makes it worse.
    func testHorizontallyDominantGestureIsNotClaimed() {
        XCTAssertNil(StripWheelScroll.horizontalStep(for: input(dx: 30, dy: 4, precise: true, inverted: true)))
        XCTAssertNil(StripWheelScroll.horizontalStep(for: input(dx: -30, dy: 4, precise: true, inverted: true)))
        // Equal also counts as horizontal: take over only when vertical strictly exceeds horizontal.
        XCTAssertNil(StripWheelScroll.horizontalStep(for: input(dx: 8, dy: 8, precise: true, inverted: true)))
    }

    func testVerticallyDominantGestureIsClaimedEvenWithSomeHorizontalDrift() {
        XCTAssertNotNil(StripWheelScroll.horizontalStep(for: input(dx: 3, dy: 20, precise: true, inverted: true)))
    }

    // MARK: - Discrete wheel (notched mouse)

    /// These four notches must equal the pre-change `sign * deltaY * 56` results value for value: the feel is
    /// signed off.
    func testDiscreteWheelMatchesTheShippedFeel() {
        let table: [(dy: CGFloat, inverted: Bool, expected: CGFloat)] = [
            (1, false, 56), (-1, false, -56),
            (1, true, -56), (-1, true, 56),
        ]
        for row in table {
            XCTAssertEqual(
                StripWheelScroll.horizontalStep(for: input(dy: row.dy, precise: false, inverted: row.inverted)),
                row.expected,
                "dy=\(row.dy) inverted=\(row.inverted)"
            )
        }
    }

    func testDiscreteWheelStepIsClamped() {
        XCTAssertEqual(StripWheelScroll.horizontalStep(for: input(dy: 10, precise: false, inverted: false)),
                       StripWheelScroll.maxStep)
        XCTAssertEqual(StripWheelScroll.horizontalStep(for: input(dy: -10, precise: false, inverted: false)),
                       -StripWheelScroll.maxStep)
    }

    // MARK: - Continuous events (trackpad / Magic Mouse / smooth wheel)

    /// Continuous event deltas are already in points: carried 1:1, neither multiplied by `wheelSpeed`
    /// nor capped (large deltas in the momentum phase are exactly the feel it should have).
    func testPreciseDeltasArePassedThroughOneToOne() {
        let table: [(dy: CGFloat, inverted: Bool, expected: CGFloat)] = [
            (7, false, 7), (-7, false, -7),
            (7, true, -7), (-7, true, 7),
            (400, true, -400),
        ]
        for row in table {
            XCTAssertEqual(
                StripWheelScroll.horizontalStep(for: input(dy: row.dy, precise: true, inverted: row.inverted)),
                row.expected,
                "dy=\(row.dy) inverted=\(row.inverted)"
            )
        }
    }

    /// For the same delta a continuous event must never be amplified like a discrete wheel: that would fling
    /// to the end at once.
    func testPreciseDeltasAreNotAmplifiedLikeAWheelNotch() {
        let precise = StripWheelScroll.horizontalStep(for: input(dy: 1, precise: true, inverted: false))
        let discrete = StripWheelScroll.horizontalStep(for: input(dy: 1, precise: false, inverted: false))
        XCTAssertEqual(precise, 1)
        XCTAssertEqual(discrete, StripWheelScroll.wheelSpeed)
    }
}
