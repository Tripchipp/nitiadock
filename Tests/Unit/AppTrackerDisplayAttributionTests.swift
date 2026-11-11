import ApplicationServices
import CoreGraphics
import XCTest

/// Inventory side of multi-display ④: when a seat's coarse attribution key (`WindowEntry.displayUUID`)
/// changes and when it is published. Locks three things: a cross-display move publishes (a same-display
/// move does not); minimized / hidden seats freeze on the last visible display;
/// a pid skipped by the read-skip gate can still change display via the 5s tick's CG bounds walk.
@MainActor
final class AppTrackerDisplayAttributionTests: XCTestCase {
    private let pid: pid_t = 5151
    private let cgWindow: CGWindowID = 91

    private let frameOnA = CGRect(x: 100, y: 100, width: 500, height: 400)
    private let frameOnAMoved = CGRect(x: 300, y: 150, width: 500, height: 400)
    private let frameOnB = CGRect(x: 1200, y: 100, width: 500, height: 400)

    private let tableAB = WindowDisplayAttribution.Table(
        displays: [
            .init(uuid: "A", cgFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
            .init(uuid: "B", cgFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800)),
        ],
        primaryUUID: "A"
    )

    func testMovingAcrossDisplaysChangesTheSignatureAndPublishes() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        tracker.rebuildSnapshotForTesting()
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-\(cgWindow)")]?.displayUUID, "A")

        let changed = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnB, isMinimized: false)],
            readOutcome: .success(count: 1)
        )

        XCTAssertTrue(changed, "a cross-display move must count as a seat change, otherwise the inventory never publishes the new position")
        tracker.rebuildSnapshotForTesting()
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-\(cgWindow)")]?.displayUUID, "B")
    }

    func testMovingWithinOneDisplayIsNotAChange() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        tracker.rebuildSnapshotForTesting()
        let before = tracker.snapshot

        let changed = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnAMoved, isMinimized: false)],
            readOutcome: .success(count: 1)
        )

        XCTAssertFalse(changed, "a move within one display must not trigger a rebuild (the fingerprint holds only the coarse key, no coordinates)")
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
        XCTAssertEqual(tracker.snapshot, before)
    }

    func testMinimizedSeatKeepsItsLastVisibleDisplay() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A", isMinimized: true))

        // AX path: a minimized window reads a frame on another display, the key does not move.
        let changed = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnB, isMinimized: true)],
            readOutcome: .success(count: 1)
        )
        XCTAssertFalse(changed)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")

        // CG path: the tick's bounds walk skips minimized seats too.
        let cgChanged = tracker.refreshDisplayAttributionFromCGForTesting(
            cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnB])
        )
        XCTAssertFalse(cgChanged)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
    }

    func testHiddenAppKeepsItsLastVisibleDisplay() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A", isHidden: true))

        let changed = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnB, isMinimized: false)],
            readOutcome: .success(count: 1)
        )
        XCTAssertFalse(changed)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
    }

    func testPeriodicCGPassMovesVisibleSeatsWithoutAnAXRead() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))

        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(
            cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnAMoved])
        ))
        XCTAssertTrue(tracker.refreshDisplayAttributionFromCGForTesting(
            cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnB])
        ))
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "B")
        // Change only the key, leave the AX frame alone (`frameKey` / `seatsAtFrame` rely on it).
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.bounds, frameOnA)
    }

    func testUnknownCGBoundsLeaveTheKeyAlone() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: cgSnapshot()))
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(
            cgSnapshot: cgSnapshot(bounds: [cgWindow: CGRect(x: 9000, y: 9000, width: 10, height: 10)])
        ))
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
    }

    func testScreenParametersChangeReattributesFromStoredBounds() {
        let box = TableBox(tableAB)
        let tracker = makeTracker(tableProvider: { box.table })
        // The seat's stored AX frame is in region B, but the key still said A
        // when it was loaded (simulates a display table that just changed).
        tracker.installFixtureForTesting(makeApp(bounds: frameOnB, displayUUID: "A"))
        tracker.rebuildSnapshotForTesting()

        // The display table changes to "region B is now called C".
        box.table = WindowDisplayAttribution.Table(
            displays: [
                .init(uuid: "A", cgFrame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
                .init(uuid: "C", cgFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800)),
            ],
            primaryUUID: "A"
        )
        tracker.screenParametersChangedForTesting()

        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "C")
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-\(cgWindow)")]?.displayUUID, "C")
    }

    func testNewSeatTakesItsDisplayFromTheAXFrame() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(AppEntry(
            pid: pid,
            bundleIdentifier: "com.example.fixture",
            appName: "Fixture",
            activationPolicy: .regular,
            executablePath: "/Applications/Fixture.app",
            windowsByID: [:],
            windowOrder: [],
            isHidden: false
        ))
        let changed = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnB, isMinimized: false)],
            readOutcome: .success(count: 1)
        )
        XCTAssertTrue(changed)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "B")
    }

    /// Optimistic update for a cross-display window drag: the key changes and publishes on the spot; during
    /// the freeze, stale positions read from AX / CG do not bounce it back; a rollback does not freeze.
    func testNoteWindowMovedPublishesAndHoldsAgainstStaleReads() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        tracker.rebuildSnapshotForTesting()

        XCTAssertTrue(tracker.noteWindowMoved(pid: pid, cgWindowID: cgWindow, displayUUID: "B"))
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-\(cgWindow)")]?.displayUUID, "B")

        // During the freeze: the frame AX reads is still on A
        // -> no change; the CG walk does not change it either.
        let changed = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: Date(),
            eligible: [makeSnapshot(bounds: frameOnA, isMinimized: false)],
            readOutcome: .success(count: 1)
        )
        XCTAssertFalse(changed)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "B")
        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnA])))

        // After the freeze (the read's now is past the hold): the true value corrects it back to A.
        let later = Date().addingTimeInterval(AppTracker.displayMoveHold + 1)
        let corrected = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: later,
            eligible: [makeSnapshot(bounds: frameOnA, isMinimized: false)],
            readOutcome: .success(count: 1)
        )
        XCTAssertTrue(corrected)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")

        // A rollback (hold: .none) takes effect at once and does not freeze.
        XCTAssertTrue(tracker.noteWindowMoved(pid: pid, cgWindowID: cgWindow, displayUUID: "B"))
        XCTAssertTrue(tracker.noteWindowMoved(pid: pid, cgWindowID: cgWindow, displayUUID: "A", hold: .none))
        XCTAssertTrue(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnB])))
        XCTAssertFalse(tracker.noteWindowMoved(pid: pid, cgWindowID: 999, displayUUID: "B"), "unregistered seats are ignored")
    }

    /// Off-screen / phantom window with no AX handle: dragging it to another bar =
    /// change of address, and the key stays pinned until it is next visible in AX.
    /// Stale CG coordinates and display-parameter recomputes do not count; only a
    /// visible frame actually read from AX makes it follow the frame and unpin.
    func testUntilVisibleHoldSurvivesCGAndStaleReadsUntilAXShowsTheWindow() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))
        XCTAssertTrue(tracker.noteWindowMoved(pid: pid, cgWindowID: cgWindow, displayUUID: "B", hold: .untilVisible))

        XCTAssertFalse(tracker.refreshDisplayAttributionFromCGForTesting(cgSnapshot: cgSnapshot(bounds: [cgWindow: frameOnA])))
        tracker.screenParametersChangedForTesting()
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "B")

        // Much later AX still has not seen it visible (minimized) -> still pinned (the
        // minimized flag itself changing counts as a change, unrelated to the key).
        let later = Date().addingTimeInterval(3600)
        _ = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: later,
            eligible: [makeSnapshot(bounds: frameOnA, isMinimized: true)],
            readOutcome: .success(count: 1)
        )
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "B")

        // AX reads a visible frame on A -> follow the frame, release the pin.
        XCTAssertTrue(tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cgSnapshot(), now: later,
            eligible: [makeSnapshot(bounds: frameOnA, isMinimized: false)],
            readOutcome: .success(count: 1)
        ))
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
        XCTAssertNil(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUIDHoldUntil)
    }

    /// During the freeze of a cross-display move the seat follows the moved window and is not "torn" away
    /// by another window on the old frame: otherwise the old seat inherits the key just written as B,
    /// the moved window gets a new seat, both cards sit on B, and the old one
    /// jumps back to A once the freeze ends (seen 2026-09-03, multi-tab Finder).
    func testMoveHoldKeepsTheSeatOnTheMovedWindowInsteadOfTearingItOut() {
        let tracker = makeTracker()
        // The fixture seat uses s9: the counter for new seats starts at s1, otherwise it
        // collides with the fixture token and the assertions cannot tell which is which.
        tracker.installFixtureForTesting(makeApp(displayUUID: "A", token: "tabgrp-\(pid)-s9"))
        XCTAssertTrue(tracker.noteWindowMoved(pid: pid, cgWindowID: cgWindow, displayUUID: "B"))
        let other: CGWindowID = 92
        let cg = AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindow, other], onScreenWindowIDs: [cgWindow, other],
            windowIDsByPID: [pid: [cgWindow, other]], alphaByWindowID: [:], boundsByWindowID: [:]
        )
        _ = tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: cg, now: Date(),
            eligible: [makeSnapshot(bounds: frameOnB, isMinimized: false),
                       makeSnapshot(bounds: frameOnA, isMinimized: false, cgWindowID: other)],
            readOutcome: .success(count: 2)
        )
        let app = tracker.fixtureAppForTesting(pid: pid)
        XCTAssertEqual(app?.windowsByID[cgWindow]?.token, "tabgrp-\(pid)-s9", "the seat follows the moved window")
        XCTAssertEqual(app?.windowsByID[cgWindow]?.displayUUID, "B")
        XCTAssertNotEqual(app?.windowsByID[other]?.token, "tabgrp-\(pid)-s9", "the window on the old frame gets its own seat")
        XCTAssertEqual(app?.windowsByID[other]?.displayUUID, "A")
    }

    /// Verdict after a failed AX frame write: window on screen -> roll back; not
    /// on screen -> pin to the target display; seat not registered -> no change.
    func testFailedMoveRollsBackOnScreenWindowsAndPinsOffScreenOnes() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(displayUUID: "A"))

        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [cgWindow])
        XCTAssertTrue(tracker.noteWindowMoved(pid: pid, cgWindowID: cgWindow, displayUUID: "B"))
        XCTAssertEqual(tracker.resolveFailedWindowMove(pid: pid, cgWindowID: cgWindow, target: "B", previous: "A"), .rolledBack)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "A")
        XCTAssertNil(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUIDHoldUntil)

        tracker.rebuildSnapshotForTesting(onScreenCGIDs: [])
        XCTAssertTrue(tracker.noteWindowMoved(pid: pid, cgWindowID: cgWindow, displayUUID: "B"))
        XCTAssertEqual(tracker.resolveFailedWindowMove(pid: pid, cgWindowID: cgWindow, target: "B", previous: "A"), .pinnedToTarget)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUID, "B")
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pid)?.windowsByID[cgWindow]?.displayUUIDHoldUntil, .distantFuture)

        XCTAssertEqual(tracker.resolveFailedWindowMove(pid: pid, cgWindowID: 999, target: "B", previous: "A"), .seatGone)
    }

    /// The "running but no window" fallback card lands on the display the window
    /// was last on; dragging it to another bar (`noteNoWindowHome`) changes that.
    func testFallbackCardRemembersLastWindowDisplayAndAcceptsANewHome() {
        let tracker = makeTracker()
        tracker.installFixtureForTesting(makeApp(bounds: frameOnB, displayUUID: "B"))
        tracker.rebuildSnapshotForTesting()

        // Window closed (gone from AX and from CG) -> seat released -> the fallback card carries "last on B".
        let empty = AppTrackerCGWindowSnapshot(allWindowIDs: [], onScreenWindowIDs: [], windowIDsByPID: [:], alphaByWindowID: [:])
        XCTAssertTrue(tracker.reconcileFixtureForTesting(
            pid: pid, cgSnapshot: empty, now: Date(), eligible: [], readOutcome: .success(count: 0)
        ))
        tracker.rebuildSnapshotForTesting()
        let fallbackID = WindowID(rawValue: "app-com.example.fixture")
        XCTAssertEqual(tracker.snapshot.windows[fallbackID]?.displayUUID, "B")

        tracker.noteNoWindowHome(bundleID: "com.example.fixture", displayUUID: "A")
        XCTAssertEqual(tracker.snapshot.windows[fallbackID]?.displayUUID, "A")
        tracker.noteNoWindowHome(bundleID: "com.other", displayUUID: "B")
        XCTAssertEqual(tracker.snapshot.windows[fallbackID]?.displayUUID, "A", "other bundles are unaffected")
    }

    // MARK: - Fixtures

    private final class TableBox {
        var table: WindowDisplayAttribution.Table
        init(_ table: WindowDisplayAttribution.Table) { self.table = table }
    }

    private func makeTracker(
        tableProvider: (@MainActor () -> WindowDisplayAttribution.Table)? = nil
    ) -> AppTracker {
        let table = tableAB
        return AppTracker(
            reader: DisplayAttributionNoopReader(),
            processProvider: DisplayAttributionFixedProcessProvider(),
            eventAXAsyncEnabled: true,
            displayTableProvider: tableProvider ?? { table }
        )
    }

    private func cgSnapshot(bounds: [CGWindowID: CGRect] = [:]) -> AppTrackerCGWindowSnapshot {
        AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindow],
            onScreenWindowIDs: [cgWindow],
            windowIDsByPID: [pid: [cgWindow]],
            alphaByWindowID: [:],
            boundsByWindowID: bounds
        )
    }

    private func makeApp(
        bounds: CGRect? = nil,
        displayUUID: String?,
        isMinimized: Bool = false,
        isHidden: Bool = false,
        token: String? = nil
    ) -> AppEntry {
        let seat = WindowEntry(
            cgWindowID: cgWindow,
            token: token ?? "tabgrp-\(pid)-s1",
            title: "Window",
            bounds: bounds ?? frameOnA,
            isMinimized: isMinimized,
            isFocused: false,
            everSeenVisible: true,
            displayUUID: displayUUID
        )
        return AppEntry(
            pid: pid,
            bundleIdentifier: "com.example.fixture",
            appName: "Fixture",
            activationPolicy: .regular,
            executablePath: "/Applications/Fixture.app",
            windowsByID: [cgWindow: seat],
            windowOrder: [cgWindow],
            isHidden: isHidden
        )
    }

    private func makeSnapshot(bounds: CGRect, isMinimized: Bool, cgWindowID: CGWindowID? = nil) -> AXWindowSnapshot {
        AXWindowSnapshot(
            pid: pid,
            cgWindowID: cgWindowID ?? cgWindow,
            titleRead: .value("Window"),
            bounds: bounds,
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            isMinimized: isMinimized,
            isFocusedWindow: false,
            element: AXUIElementCreateApplication(pid)
        )
    }
}

private struct DisplayAttributionNoopReader: AppTrackerWindowReading {
    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] { [] }
    func windowReadResult(forPID pid: pid_t) -> AXWindowReadResult { .success([]) }
    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval) -> AXWindowReadResult { .success([]) }
}

private struct DisplayAttributionFixedProcessProvider: AppTrackerProcessProviding {
    func isAlive(pid: pid_t) -> Bool { true }

    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        ScanAdmissionDecision.ProcessIdentity(pid: pid, startTimeSec: 1, startTimeUsec: 2, bundleID: bundleID)
    }
}
