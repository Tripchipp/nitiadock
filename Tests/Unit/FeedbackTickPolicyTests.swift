import Foundation
import XCTest

final class DockSnapshotEqualityTests: XCTestCase {
    func testEquivalentSnapshotsCompareEqual() {
        let id = WindowID(rawValue: "cgw-1")
        let record = WindowRecord(
            id: id,
            appID: AppID(rawValue: "com.example.app"),
            pid: 42,
            bundleIdentifier: "com.example.app",
            title: "Window",
            bounds: CGRect(x: 1, y: 2, width: 300, height: 200),
            status: .inactive,
            cgWindowID: 10,
            isOnDesktop: true,
            groupID: "seat-1"
        )
        let lhs = DockSnapshot(windows: [id: record], orderedWindowIDs: [id])
        let rhs = DockSnapshot(windows: [id: record], orderedWindowIDs: [id])

        XCTAssertEqual(lhs, rhs)
        XCTAssertNotEqual(lhs, .empty)
    }
}

/// Truth table for running the feedback timer on demand.
///
/// Background: this timer used to be an unconditional 0.5s loop
/// started in `start()`, writing feedback state back to `@Published`
/// twice a second while idle, with the whole taskbar recomputing
/// along, although that dictionary is empty most of the time. Once it
/// runs on demand, "when should it tick" becomes a load-bearing rule, locked here.
final class FeedbackTickPolicyTests: XCTestCase {

    // MARK: - Four-cell truth table (runtime running)

    func testIdleDoesNotTick() {
        XCTAssertFalse(
            FeedbackTickPolicy.shouldTick(
                isRunning: true,
                hasFeedbackEntries: false,
                hasOptimisticStates: false
            )
        )
    }

    func testFeedbackOnlyTicks() {
        XCTAssertTrue(
            FeedbackTickPolicy.shouldTick(
                isRunning: true,
                hasFeedbackEntries: true,
                hasOptimisticStates: false
            )
        )
    }

    /// Optimistic tail: the feedback entries are already cleared (the 1.5s
    /// result display expired), but the optimistic overlay is still waiting
    /// to be confirmed or to bounce back on the 4s timeout. It must keep
    /// ticking then, otherwise that chip's predicted state never bounces back.
    func testOptimisticOnlyTicks() {
        XCTAssertTrue(
            FeedbackTickPolicy.shouldTick(
                isRunning: true,
                hasFeedbackEntries: false,
                hasOptimisticStates: true
            )
        )
    }

    func testBothPresentTicks() {
        XCTAssertTrue(
            FeedbackTickPolicy.shouldTick(
                isRunning: true,
                hasFeedbackEntries: true,
                hasOptimisticStates: true
            )
        )
    }

    // MARK: - Load-bearing rule: once the runtime stops it never ticks

    /// The detached execution callback of `AppRuntime.trigger()` gets back
    /// to the main thread to write feedback state only after `stop()`.
    /// Without this gate that callback would revive the stopped timer: runtime stopped,
    /// timer still spinning idle every 0.5s, and nobody left to turn it off.
    func testStoppedRuntimeNeverTicksEvenWithPendingWork() {
        XCTAssertFalse(
            FeedbackTickPolicy.shouldTick(
                isRunning: false,
                hasFeedbackEntries: true,
                hasOptimisticStates: true
            )
        )
        XCTAssertFalse(
            FeedbackTickPolicy.shouldTick(
                isRunning: false,
                hasFeedbackEntries: true,
                hasOptimisticStates: false
            )
        )
        XCTAssertFalse(
            FeedbackTickPolicy.shouldTick(
                isRunning: false,
                hasFeedbackEntries: false,
                hasOptimisticStates: true
            )
        )
    }

    func testStoppedRuntimeIdleDoesNotTick() {
        XCTAssertFalse(
            FeedbackTickPolicy.shouldTick(
                isRunning: false,
                hasFeedbackEntries: false,
                hasOptimisticStates: false
            )
        )
    }
}

/// The lifecycle of the feedback state itself: once the timer runs
/// on demand, "do entries empty out on their own" directly decides
/// whether the timer stops. These cases lock that the retention semantics were not changed.
final class IntentFeedbackStateRetentionTests: XCTestCase {

    private let windowID = "cgw-1"

    private func snapshot(status: WindowStatus) -> DockSnapshot {
        let id = WindowID(rawValue: windowID)
        let record = WindowRecord(
            id: id,
            appID: AppID(rawValue: "com.example.app"),
            pid: 1234,
            bundleIdentifier: "com.example.app",
            title: "窗口",
            bounds: nil,
            status: status,
            isOnDesktop: true,
            groupID: windowID
        )
        return DockSnapshot(windows: [id: record], orderedWindowIDs: [id])
    }

    /// pending not confirmed after 4s -> becomes failure (instead of staying pending and ticking forever).
    func testPendingBecomesFailureAfterRetention() {
        var state = IntentFeedbackState()
        let start = Date()
        state.begin(windowID: windowID, action: .minimize, at: start)

        state.reconcile(snapshot: snapshot(status: .inactive), now: start.addingTimeInterval(4.5))

        XCTAssertEqual(state.entriesByWindowID[windowID]?.phase, .failure)
    }

    /// **Immediate failure, then confirmed by a snapshot**: `AccessibilitySource.minimize` reads back
    /// `kAXMinimizedAttribute` right after pressing the minimize button, and minimizing
    /// is animated, so that read often has not caught up and the executor reports
    /// failure. The real snapshot then shows the window did
    /// minimize, and it must be possible to correct it to success.
    ///
    /// This is a regression guardrail: to let the on-demand timer stop,
    /// "all terminal states skip reconciliation" was once used as the fix,
    /// which deleted this upgrade path along with it.
    func testFailureIsUpgradedToSuccessWhenSnapshotLaterConfirms() {
        var state = IntentFeedbackState()
        let start = Date()
        state.begin(windowID: windowID, action: .minimize, at: start)

        // Executor's immediate read-back fails -> failure
        state.markFailed(windowID: windowID, action: .minimize, at: start.addingTimeInterval(0.05))
        XCTAssertEqual(state.entriesByWindowID[windowID]?.phase, .failure)

        // A later real snapshot shows the window minimized -> corrected to success
        state.reconcile(snapshot: snapshot(status: .minimized), now: start.addingTimeInterval(0.4))
        XCTAssertEqual(
            state.entriesByWindowID[windowID]?.phase,
            .success,
            "failure must be correctable by a later real snapshot: the AX action may have taken effect before the immediate read-back caught up"
        )
    }

    /// Same phase does not refresh the timestamp: while the window stays in the
    /// target state every reconcile round judges success again, but it must not
    /// overwrite `updatedAt` with now round after round, otherwise
    /// the entry never expires and the on-demand timer never stops.
    func testSuccessIsNotRestampedWhileWindowStaysInTargetState() {
        var state = IntentFeedbackState()
        let start = Date()
        state.begin(windowID: windowID, action: .minimize, at: start)
        state.reconcile(snapshot: snapshot(status: .minimized), now: start.addingTimeInterval(0.2))
        let firstSuccessAt = state.entriesByWindowID[windowID]?.updatedAt
        XCTAssertNotNil(firstSuccessAt)

        // Another round later, the window is still minimized
        state.reconcile(snapshot: snapshot(status: .minimized), now: start.addingTimeInterval(0.7))

        XCTAssertEqual(
            state.entriesByWindowID[windowID]?.updatedAt,
            firstSuccessAt,
            "a repeated same-phase reconcile must not refresh updatedAt, otherwise the 1.5s retention never runs out"
        )
    }

    /// A terminal state (success / failure) is shown for 1.5s and then the
    /// entry is cleared, which is the precondition for the timer to stop.
    func testTerminalEntryIsDroppedAfterRetentionSoTheTimerCanStop() {
        var state = IntentFeedbackState()
        let start = Date()
        state.begin(windowID: windowID, action: .minimize, at: start)

        // Confirmed: the window really minimized -> success
        state.reconcile(snapshot: snapshot(status: .minimized), now: start.addingTimeInterval(0.5))
        XCTAssertEqual(state.entriesByWindowID[windowID]?.phase, .success)

        // The 1.5s result display expires -> the entry disappears and the dictionary is empty
        state.reconcile(snapshot: snapshot(status: .minimized), now: start.addingTimeInterval(2.2))
        XCTAssertTrue(
            state.entriesByWindowID.isEmpty,
            "if terminal entries are not cleared, the on-demand timer never stops"
        )
    }
}
