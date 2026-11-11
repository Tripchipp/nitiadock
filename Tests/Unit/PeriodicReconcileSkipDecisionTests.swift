import CoreGraphics
import XCTest

/// Skip-read gate decision matrix: each forced-full-read condition flipped once, plus the all-quiet skip.
final class PeriodicReconcileSkipDecisionTests: XCTestCase {
    /// Baseline input with every condition met and skipping allowed.
    private func quietInput() -> PeriodicReconcileSkipDecision.Input {
        PeriodicReconcileSkipDecision.Input(
            captureFailed: false,
            currentCGIDs: [77, 78],
            lastObservedCGIDs: [77, 78],
            dirtySinceLastRead: false,
            hasAbsenceClock: false,
            hasPhantomCandidate: false,
            lastReadWasUnread: false,
            lastRoundChanged: false,
            observerActive: true,
            uptimeSinceLastFullRead: 5
        )
    }

    func testAllQuietSkips() {
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(quietInput()), .skip)
    }

    func testCaptureFailureForcesFullRead() {
        var input = quietInput()
        input.captureFailed = true
        // On CG failure a full read is required even if the sets "look" identical: failure and an empty set
        // are indistinguishable (hard constraint).
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.captureFailed))
    }

    func testNeverReadForcesFullRead() {
        var input = quietInput()
        input.lastObservedCGIDs = nil
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.neverRead))
    }

    func testRefreshDueAtBoundaryForcesFullRead() {
        var input = quietInput()
        input.uptimeSinceLastFullRead = input.maxSkipInterval   // the boundary is "read when due"
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.refreshDue))
        input.uptimeSinceLastFullRead = input.maxSkipInterval - 0.001
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .skip)
    }

    func testInactiveObserverForcesFullRead() {
        var input = quietInput()
        input.observerActive = false
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.observerInactive))
    }

    func testUnreadLastRoundForcesFullRead() {
        var input = quietInput()
        input.lastReadWasUnread = true
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.lastReadUnread))
    }

    func testDirtyEventsForceFullRead() {
        var input = quietInput()
        input.dirtySinceLastRead = true
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.dirtyEvents))
    }

    func testCGSetChangeForcesFullRead() {
        var input = quietInput()
        input.currentCGIDs = [77]
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.cgSetChanged))
        // More and fewer both trigger.
        input.currentCGIDs = [77, 78, 79]
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.cgSetChanged))
    }

    func testAbsenceClockForcesFullRead() {
        var input = quietInput()
        input.hasAbsenceClock = true
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.absenceClockRunning))
    }

    func testPhantomCandidateForcesFullRead() {
        var input = quietInput()
        input.hasPhantomCandidate = true
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.phantomCandidate))
    }

    func testUnstableLastRoundForcesFullRead() {
        var input = quietInput()
        input.lastRoundChanged = true
        XCTAssertEqual(PeriodicReconcileSkipDecision.verdict(input), .fullRead(.lastRoundChanged))
    }
}
