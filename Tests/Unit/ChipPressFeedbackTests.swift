import CoreGraphics
import XCTest

/// Pure decisions for press feedback.
///
/// Background (2026-08-11 report: "pressing feels sticky"): the
/// old implementation hung the bounce-back on `.onTapGesture`,
/// but SwiftUI's TapGesture fires on **mouse up**, so the
/// whole "press" happened after the click had already ended.
/// Now `DragGesture(minimumDistance: 0)` drives it at the
/// moment of press, and release finishes by the rules below.
final class ChipPressFeedbackTests: XCTestCase {

    // MARK: - Minimum hold

    /// A very fast click (a few milliseconds from press to release)
    /// that bounces back at once never shows the 0.93 scale.
    /// That was the purpose of the 90ms timer in the old implementation;
    /// it must be kept as is now that the press drives it.
    func testVeryFastClickIsHeldUpToTheMinimum() {
        let hold = ChipPressDecision.holdAfterRelease(pressedAt: 100.0, releasedAt: 100.005)
        XCTAssertEqual(hold, ChipPressDecision.minimumHold - 0.005, accuracy: 1e-9)
    }

    /// Press already held longer than the minimum hold: release bounces
    /// back at once with no extra delay, more delay is a new stickiness.
    func testSlowClickReleasesImmediately() {
        XCTAssertEqual(
            ChipPressDecision.holdAfterRelease(pressedAt: 100.0, releasedAt: 100.5),
            0
        )
    }

    func testExactlyAtMinimumReleasesImmediately() {
        XCTAssertEqual(
            ChipPressDecision.holdAfterRelease(
                pressedAt: 100.0,
                releasedAt: 100.0 + ChipPressDecision.minimumHold
            ),
            0
        )
    }

    /// No press time recorded (force touch / middle-click preview:
    /// a pulse only, no mouse-down): pad the full duration,
    /// otherwise that feedback level is shown for zero frames.
    func testMissingPressTimestampHoldsFullMinimum() {
        XCTAssertEqual(
            ChipPressDecision.holdAfterRelease(pressedAt: nil, releasedAt: 100.0),
            ChipPressDecision.minimumHold
        )
    }

    /// Release earlier than press (clock anomaly / out-of-order state) must never
    /// yield a negative number: a negative delay fires the schedule at once,
    /// which silently turns off the minimum-hold rule.
    func testReleaseBeforePressNeverReturnsNegative() {
        let hold = ChipPressDecision.holdAfterRelease(pressedAt: 100.0, releasedAt: 99.0)
        XCTAssertEqual(hold, ChipPressDecision.minimumHold)
        XCTAssertGreaterThanOrEqual(hold, 0)
    }

    // MARK: - Constant bounds

    /// The watchdog must be clearly longer than the minimum hold: it guards
    /// against "`onEnded` never arrives" (SwiftUI cancels the gesture
    /// when a reorder moves the chip), not against normal clicks. If the two get
    /// close, a normal long press is mistaken for stuck and bounces back early.
    func testWatchdogIsWellAboveMinimumHold() {
        XCTAssertGreaterThan(ChipPressDecision.maximumHold, ChipPressDecision.minimumHold * 5)
    }

    /// The scale value is the literal from before the change, left untouched on purpose (approved look).
    func testPressedScaleMatchesPreviousLiteral() {
        XCTAssertEqual(ChipPressDecision.pressedScale, 0.93)
    }

    /// The minimum hold keeps the old 90ms.
    func testMinimumHoldMatchesPreviousTimer() {
        XCTAssertEqual(ChipPressDecision.minimumHold, 0.09, accuracy: 1e-9)
    }
}
