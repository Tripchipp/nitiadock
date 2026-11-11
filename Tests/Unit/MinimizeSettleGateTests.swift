import XCTest
@testable import NitiaDock

final class MinimizeSettleGateTests: XCTestCase {
    /// Anchor at reference epoch 0: `addingTimeInterval(x)` and `timeIntervalSince(anchor)` both equal x
    /// exactly, so boundary-equality cases do not go flaky from Double rounding (1000 + 0.65 ≠ exactly 0.65).
    private let anchor = Date(timeIntervalSinceReferenceDate: 0)

    private func verdict(
        kind: PlatformActionRequest.ActionKind = .activateWindow,
        hasAnchor: Bool = true,
        confirmed: Bool,
        elapsed: TimeInterval
    ) -> MinimizeSettleGate.Verdict {
        MinimizeSettleGate.verdict(
            requestKind: kind,
            minimizeDispatchedAt: hasAnchor ? anchor : nil,
            snapshotConfirmsMinimized: confirmed,
            now: anchor.addingTimeInterval(elapsed)
        )
    }

    /// Non-activate actions always pass, even with a live anchor.
    func testNonActivateKindsAlwaysDispatch() {
        let kinds: [PlatformActionRequest.ActionKind] = [.minimizeWindow, .hideApp, .closeWindow, .quitApp, .newWindow]
        for kind in kinds {
            XCTAssertEqual(verdict(kind: kind, confirmed: false, elapsed: 0.1), .dispatchNow)
        }
    }

    /// No minimize anchor → no guarding.
    func testNoAnchorDispatches() {
        XCTAssertEqual(verdict(hasAnchor: false, confirmed: false, elapsed: 0.1), .dispatchNow)
    }

    /// [Load-bearing, v2 semantics reversed] A snapshot-confirmed `.minimized` passes at once, with no time
    /// floor. v1 locked "confirmation also waits 0.65s" here, and real use rejected it twice (feel + Finder
    /// missing a sibling at 887ms): waiting is not where safety comes from. The dangerous animation-phase
    /// branches are already sealed by the prior in the execution layer (force knownMinimized onto the 07-05
    /// v3 measured order, skip earlyFocus, seal the app fallback); confirmation itself only proves write
    /// ordering against a concurrent minimize.
    func testConfirmedDispatchesImmediately() {
        for elapsed in [0.05, 0.2, 0.5, 0.99] {
            XCTAssertEqual(verdict(confirmed: true, elapsed: elapsed), .dispatchNow, "elapsed=\(elapsed)")
        }
    }

    /// Unconfirmed → hold until the hard cap (the only deadline tier).
    func testUnconfirmedHoldsToMaxHold() {
        for elapsed in [0.1, 0.5, 0.9] {
            XCTAssertEqual(
                verdict(confirmed: false, elapsed: elapsed),
                .hold(until: anchor.addingTimeInterval(MinimizeSettleGate.maxHold)),
                "elapsed=\(elapsed)"
            )
        }
    }

    /// [Load-bearing] Past the hard cap it passes even unconfirmed: a click cannot be held forever (the
    /// execution layer still has the prior as fallback).
    func testPastMaxHoldDispatchesEvenUnconfirmed() {
        XCTAssertEqual(verdict(confirmed: false, elapsed: 1.1), .dispatchNow)
    }

    /// Confirmed + past the hard cap → still passes (boundary completeness).
    func testConfirmedPastMaxHoldStillDispatches() {
        XCTAssertEqual(verdict(confirmed: true, elapsed: 1.2), .dispatchNow)
    }

    /// The deadline is monotonic: re-running the decision as time advances never moves it back; after
    /// dispatchNow it never returns to hold.
    func testDeadlineMonotonicAcrossReevaluation() {
        var lastDeadline = Date.distantPast
        var dispatched = false
        for elapsed in stride(from: 0.05, through: 1.3, by: 0.05) {
            switch verdict(confirmed: false, elapsed: elapsed) {
            case .hold(let until):
                XCTAssertFalse(dispatched, "must not return to hold after dispatchNow (elapsed=\(elapsed))")
                XCTAssertGreaterThanOrEqual(until, lastDeadline)
                lastDeadline = until
            case .dispatchNow:
                dispatched = true
            }
        }
        XCTAssertTrue(dispatched)
    }

    /// Clock anomaly (anchor in the future) → pass conservatively, back to the old behavior.
    func testNegativeElapsedDispatches() {
        XCTAssertEqual(verdict(confirmed: false, elapsed: -0.5), .dispatchNow)
    }

    /// Boundary equality: elapsed == maxHold unconfirmed → pass.
    func testBoundaryEquality() {
        XCTAssertEqual(verdict(confirmed: false, elapsed: MinimizeSettleGate.maxHold), .dispatchNow)
    }

    /// Prior window: anchor within [0, priorWindow) → true; at the boundary, no anchor, clock anomaly →
    /// false.
    func testDispatchPrior() {
        func prior(_ elapsed: TimeInterval, hasAnchor: Bool = true) -> Bool {
            MinimizeSettleGate.dispatchPrior(
                minimizeDispatchedAt: hasAnchor ? anchor : nil,
                now: anchor.addingTimeInterval(elapsed)
            )
        }
        XCTAssertTrue(prior(0))
        XCTAssertTrue(prior(0.1))
        XCTAssertTrue(prior(1.5))
        XCTAssertTrue(prior(1.99))
        XCTAssertFalse(prior(MinimizeSettleGate.priorWindow))
        XCTAssertFalse(prior(2.5))
        XCTAssertFalse(prior(-0.5))
        XCTAssertFalse(prior(0.1, hasAnchor: false))
    }
}
