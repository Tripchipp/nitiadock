import ApplicationServices
import CoreGraphics
import XCTest

/// Behavior lock for the periodic reconcile's batched background
/// read (schedulePeriodicBatchRead / completePeriodicBatch):
/// each pid is read exactly once and applied, an in-flight event read suppresses the batch
/// read, a generation change discards the result, `.unread` leaves seat state untouched.
@MainActor
final class AppTrackerPeriodicBatchTests: XCTestCase {
    private let pidA: pid_t = 4242
    private let pidB: pid_t = 4343
    private let cgWindowA: CGWindowID = 77
    private let cgWindowB: CGWindowID = 88

    func testBatchReadsEachTrackedPidOnceAndAppliesResult() async {
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Renamed A")]),
            pidB: .success([makeSnapshot(pid: pidB, cgWindowID: cgWindowB, title: "Renamed B")]),
        ])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.installFixtureForTesting(makeApp(pid: pidB, cgWindowID: cgWindowB))

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        XCTAssertTrue(tracker.hasPendingEventReadForTesting(pid: pidA))
        XCTAssertTrue(tracker.hasPendingEventReadForTesting(pid: pidB))

        await waitUntil {
            !tracker.hasPendingEventReadForTesting(pid: self.pidA)
                && !tracker.hasPendingEventReadForTesting(pid: self.pidB)
        }

        XCTAssertEqual(reader.readCount, 2)
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA]?.title, "Renamed A")
        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pidB)?.windowsByID[cgWindowB]?.title, "Renamed B")
    }

    func testInFlightEventReadSuppressesPeriodicBatchForThatPid() async {
        let reader = PeriodicBatchReader(
            resultsByPID: [pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")])],
            blocksTimedReads: true
        )
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            cgSnapshotProvider: { [snapshot = cgSnapshot()] in snapshot },
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))

        tracker.scheduleEventReadForTesting(pid: pidA, source: .windowCreated)
        XCTAssertTrue(tracker.hasPendingEventReadForTesting(pid: pidA))

        // Event read in flight -> this batch round must skip the pid and not register a second pending.
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())

        reader.releaseOne()
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        // Only the one event read; the batch did not queue a second read for the same pid.
        XCTAssertEqual(reader.readCount, 1)
    }

    func testGenerationBumpMidFlightDiscardsBatchLanding() async {
        let provider = BatchMutableProcessProvider()
        let reader = PeriodicBatchReader(
            resultsByPID: [pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Renamed A")])],
            blocksTimedReads: true
        )
        let tracker = AppTracker(
            reader: reader,
            processProvider: provider,
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        // The read is still stuck in the probe and the generation changes
        // now (pid reuse): the identity check must block the result.
        provider.advanceGeneration()
        reader.releaseOne()
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }

        XCTAssertEqual(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA]?.title, "Window")
    }

    func testUnreadBatchRoundLeavesSeatStateUntouched() async {
        let absence = Date(timeIntervalSince1970: 10)
        let reader = PeriodicBatchReader(resultsByPID: [pidA: .unread(.cannotComplete)])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            eventAXAsyncEnabled: true
        )
        var app = makeApp(pid: pidA, cgWindowID: cgWindowA)
        app.windowsByID[cgWindowA]?.isMinimized = true
        app.windowsByID[cgWindowA]?.minAbsentSince = absence
        app.shadowTabCgIDs = [91, 92]
        tracker.installFixtureForTesting(app)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }

        let after = tracker.fixtureAppForTesting(pid: pidA)
        XCTAssertEqual(after?.windowOrder, [cgWindowA])
        XCTAssertEqual(after?.windowsByID[cgWindowA]?.title, "Window")
        XCTAssertEqual(after?.windowsByID[cgWindowA]?.minAbsentSince, absence)
        XCTAssertEqual(after?.shadowTabCgIDs, [91, 92])
        XCTAssertEqual(reader.readCount, 1)
    }

    // MARK: - Read-skip gate integration (DOCK_RECONCILE_SKIP on by default)

    func testQuiescentPidIsSkippedOnSecondBatch() async {
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")]),
        ])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 1)

        // Second round: no events, CG set unchanged, no change
        // last round -> skipped, not even a pending is registered.
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        XCTAssertFalse(tracker.hasPendingEventReadForTesting(pid: pidA))
        await waitUntil(timeoutNanoseconds: 300_000_000) { reader.readCount > 1 }   // short wait to prove no read actually happened
        XCTAssertEqual(reader.readCount, 1)
    }

    func testMinimizeEventReopensGate() async {
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")]),
        ])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            cgSnapshotProvider: { [snapshot = cgSnapshot()] in snapshot },
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        XCTAssertEqual(reader.readCount, 1)

        // An AX minimize event marks it dirty -> the next round must do a full read.
        tracker.minimizeForTesting(pid: pidA, cgWindowID: cgWindowA)
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 2)
    }

    func testCGSetChangeReopensGate() async {
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")]),
        ])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        XCTAssertEqual(reader.readCount, 1)

        // The pid's CG layer-0 set gained a window -> must do a full read.
        let grown = AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowA, cgWindowB, 99],
            onScreenWindowIDs: [cgWindowA, cgWindowB, 99],
            windowIDsByPID: [pidA: [cgWindowA, 99], pidB: [cgWindowB]],
            alphaByWindowID: [:]
        )
        tracker.runPeriodicBatchForTesting(cgSnapshot: grown)
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 2)
    }

    func testAbsenceClockKeepsReadingEveryBatch() async {
        // Phantom evidence must be sampled at the original cadence: a
        // pid with an absence clock is read every round, never skipped.
        let reader = PeriodicBatchReader(resultsByPID: [pidA: .success([])])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            eventAXAsyncEnabled: true
        )
        var app = makeApp(pid: pidA, cgWindowID: cgWindowA)
        app.windowsByID[cgWindowA]?.isMinimized = true
        app.windowsByID[cgWindowA]?.isFocused = false
        app.windowsByID[cgWindowA]?.minAbsentSince = Date(timeIntervalSince1970: 10)
        app.windowsByID[cgWindowA]?.absenceEpisodeID = UUID()
        tracker.installFixtureForTesting(app)
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 1)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 2)
    }

    func testRefreshDueForcesReadAfterMaxSkipInterval() async {
        let uptime = UptimeBox(value: 1000)
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")]),
        ])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            eventAXAsyncEnabled: true,
            uptimeProvider: { uptime.value }
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        XCTAssertEqual(reader.readCount, 1)

        // Past the 30s monotonic-clock fallback -> forced full read.
        uptime.value = 1031
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 2)
    }

    func testUnreadRoundIsAlwaysRetried() async {
        let reader = PeriodicBatchReader(resultsByPID: [pidA: .unread(.cannotComplete)])
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        tracker.runPeriodicBatchForTesting(cgSnapshot: cgSnapshot())
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 2)
    }

    // MARK: - Frontmost cache (next round A)

    func testFrontmostCacheDrivesActiveHighlightWithoutWorkspaceQuery() {
        let tracker = AppTracker(
            reader: PeriodicBatchReader(resultsByPID: [:]),
            processProvider: BatchFixedProcessProvider(),
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))

        // The cache says pidA is frontmost -> this window is active (the
        // real frontmostApplication in the test process is someone else).
        tracker.setFrontmostPIDForTesting(pidA)
        tracker.rebuildSnapshotForTesting()
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-\(cgWindowA)")]?.status, .active)

        // The cache now points to another process -> the same seat drops to inactive at once.
        tracker.setFrontmostPIDForTesting(pidB)
        tracker.rebuildSnapshotForTesting()
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-\(cgWindowA)")]?.status, .inactive)
    }

    func testFrontmostCacheKillSwitchIgnoresCachedValue() {
        let tracker = AppTracker(
            reader: PeriodicBatchReader(resultsByPID: [:]),
            processProvider: BatchFixedProcessProvider(),
            eventAXAsyncEnabled: true,
            frontmostCacheEnabled: false
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))

        // DOCK_FRONTMOST_CACHE=0: NSWorkspace is queried for real each
        // time and the cached value takes no part in the decision;
        // the test process's real frontmost app is not pidA, so the seat is not lit.
        tracker.setFrontmostPIDForTesting(pidA)
        tracker.rebuildSnapshotForTesting()
        XCTAssertEqual(tracker.snapshot.windows[WindowID(rawValue: "cgw-\(cgWindowA)")]?.status, .inactive)
    }

    // MARK: - CG full-table reuse gate (DOCK_CG_SNAPSHOT_REUSE on by default)

    private func makeCountingTracker(
        reuseEnabled: Bool = true,
        probeBox: ProbeBox,
        counters: CGCallCounters,
        uptime: UptimeBox? = nil
    ) -> AppTracker {
        let reader = PeriodicBatchReader(resultsByPID: [
            pidA: .success([makeSnapshot(pid: pidA, cgWindowID: cgWindowA, title: "Window")]),
        ])
        let snapshot = cgSnapshot()
        let box = uptime
        return AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            cgSnapshotProvider: { counters.noteCapture(); return snapshot },
            onScreenWindowIDsProvider: { counters.noteProbe(); return probeBox.value },
            eventAXAsyncEnabled: true,
            cgSnapshotReuseEnabled: reuseEnabled,
            uptimeProvider: { box?.value ?? 1000 }
        )
    }

    private func runEventRead(_ tracker: AppTracker) async {
        tracker.scheduleEventReadForTesting(pid: pidA, source: .frontmostPoll)
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
    }

    func testQuietSecondEventReadReusesCachedTable() async {
        let counters = CGCallCounters()
        let tracker = makeCountingTracker(probeBox: ProbeBox(value: [cgWindowA]), counters: counters)
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        await runEventRead(tracker)          // no cache -> probe + fresh capture, cache attached
        XCTAssertNotNil(tracker.cgSnapshotCacheForTesting())
        let capturesAfterFirst = counters.captures

        await runEventRead(tracker)          // quiet tick: same probe -> reuse, full-capture count unchanged
        XCTAssertEqual(counters.captures, capturesAfterFirst)
    }

    func testProbeChangeForcesFreshCapture() async {
        let counters = CGCallCounters()
        let probeBox = ProbeBox(value: [cgWindowA])
        let tracker = makeCountingTracker(probeBox: probeBox, counters: counters)
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        await runEventRead(tracker)
        let capturesAfterFirst = counters.captures

        probeBox.value = [cgWindowA, cgWindowB]   // on-screen set changed (e.g. a tab switch)
        await runEventRead(tracker)
        XCTAssertEqual(counters.captures, capturesAfterFirst + 1)
    }

    func testEventGenerationBumpForcesFreshCapture() async {
        let counters = CGCallCounters()
        let tracker = makeCountingTracker(probeBox: ProbeBox(value: [cgWindowA]), counters: counters)
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        await runEventRead(tracker)
        let capturesAfterFirst = counters.captures

        tracker.bumpCGEventGenerationForTesting()  // an AX/workspace event arrived in between
        await runEventRead(tracker)
        XCTAssertEqual(counters.captures, capturesAfterFirst + 1)
    }

    func testCacheExpiryForcesFreshCapture() async {
        let counters = CGCallCounters()
        let uptime = UptimeBox(value: 1000)
        let tracker = makeCountingTracker(
            probeBox: ProbeBox(value: [cgWindowA]), counters: counters, uptime: uptime
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        await runEventRead(tracker)
        let capturesAfterFirst = counters.captures

        uptime.value = 1000 + CGSnapshotReuseDecision.defaultMaxCacheAge + 0.1
        await runEventRead(tracker)
        XCTAssertEqual(counters.captures, capturesAfterFirst + 1)
    }

    func testKillSwitchCapturesEveryTimeAndNeverProbes() async {
        let counters = CGCallCounters()
        let tracker = makeCountingTracker(
            reuseEnabled: false, probeBox: ProbeBox(value: [cgWindowA]), counters: counters
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))
        tracker.setObserverActiveForTesting(pid: pidA, active: true)

        await runEventRead(tracker)
        await runEventRead(tracker)
        // Bit-for-bit the same as with the gate off: each event read
        // captures its own snapshot. Probe counts can only come from
        // rebuildSnapshot's on-screen fallback (seats do not change here,
        // no rebuild); the event-read path must not take a single probe.
        XCTAssertEqual(counters.captures, 2)
        XCTAssertEqual(counters.probes, 0)
        XCTAssertNil(tracker.cgSnapshotCacheForTesting())
    }

    // MARK: - Fixtures

    /// A window-close event must go through the timed background read and must not trigger an untimed
    /// read on the main actor (the main thread freezes ~12s when the closing window's app hangs).
    func testWindowDestroyedUsesTimedBackgroundReadNeverUntimedMainActorRead() async {
        let reader = PeriodicBatchReader(resultsByPID: [pidA: .success([])])
        let emptyCG = AppTrackerCGWindowSnapshot(
            allWindowIDs: [], onScreenWindowIDs: [], windowIDsByPID: [:], alphaByWindowID: [:]
        )
        let tracker = AppTracker(
            reader: reader,
            processProvider: BatchFixedProcessProvider(),
            cgSnapshotProvider: { emptyCG },
            eventAXAsyncEnabled: true
        )
        tracker.installFixtureForTesting(makeApp(pid: pidA, cgWindowID: cgWindowA))

        tracker.destroyForTesting(pid: pidA, cgWindowID: cgWindowA)

        XCTAssertEqual(reader.untimedReadCount, 0, "the destroy handler must not do an untimed AX read on the main actor")
        XCTAssertTrue(tracker.hasPendingEventReadForTesting(pid: pidA))
        await waitUntil { !tracker.hasPendingEventReadForTesting(pid: self.pidA) }
        XCTAssertEqual(reader.readCount, 1)
        XCTAssertEqual(reader.untimedReadCount, 0)
        // AX empty + the window gone from the full CG list -> the seat is really deleted.
        XCTAssertNil(tracker.fixtureAppForTesting(pid: pidA)?.windowsByID[cgWindowA])
    }

    private func cgSnapshot() -> AppTrackerCGWindowSnapshot {
        AppTrackerCGWindowSnapshot(
            allWindowIDs: [cgWindowA, cgWindowB],
            onScreenWindowIDs: [cgWindowA, cgWindowB],
            windowIDsByPID: [pidA: [cgWindowA], pidB: [cgWindowB]],
            alphaByWindowID: [:]
        )
    }

    private func makeApp(pid: pid_t, cgWindowID: CGWindowID) -> AppEntry {
        let seat = WindowEntry(
            cgWindowID: cgWindowID,
            token: "tabgrp-\(pid)-s1",
            title: "Window",
            bounds: CGRect(x: 10, y: 20, width: 500, height: 400),
            isMinimized: false,
            isFocused: true,
            everSeenVisible: true
        )
        return AppEntry(
            pid: pid,
            bundleIdentifier: "com.example.fixture\(pid)",
            appName: "Fixture\(pid)",
            activationPolicy: .regular,
            executablePath: "/Applications/Fixture.app",
            windowsByID: [cgWindowID: seat],
            windowOrder: [cgWindowID],
            isHidden: false
        )
    }

    private func makeSnapshot(pid: pid_t, cgWindowID: CGWindowID, title: String) -> AXWindowSnapshot {
        AXWindowSnapshot(
            pid: pid,
            cgWindowID: cgWindowID,
            titleRead: .value(title),
            bounds: CGRect(x: 10, y: 20, width: 500, height: 400),
            role: kAXWindowRole as String,
            subrole: kAXStandardWindowSubrole as String,
            isMinimized: false,
            isFocusedWindow: true,
            element: AXUIElementCreateApplication(pid)
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let start = DispatchTime.now().uptimeNanoseconds
        while !condition(), DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

/// Timed-read probe with injectable per-pid results; can optionally block
/// mid-read (simulates the window while a batch read is in flight).
private final class PeriodicBatchReader: AppTrackerWindowReading, @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var count = 0
    private var untimedCount = 0
    private let resultsByPID: [pid_t: AXWindowReadResult]
    private let blocksTimedReads: Bool

    init(resultsByPID: [pid_t: AXWindowReadResult], blocksTimedReads: Bool = false) {
        self.resultsByPID = resultsByPID
        self.blocksTimedReads = blocksTimedReads
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func releaseOne() {
        semaphore.signal()
    }

    func windows(forPID pid: pid_t) -> [AXWindowSnapshot] { [] }

    var untimedReadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return untimedCount
    }

    func windowReadResult(forPID pid: pid_t) -> AXWindowReadResult {
        lock.lock()
        untimedCount += 1
        lock.unlock()
        return resultsByPID[pid] ?? .unread(.cannotComplete)
    }

    func inventoryWindows(forPID pid: pid_t, messagingTimeout: TimeInterval) -> AXWindowReadResult {
        lock.lock()
        count += 1
        lock.unlock()
        if blocksTimedReads { semaphore.wait() }
        return resultsByPID[pid] ?? .unread(.cannotComplete)
    }
}

private final class CGCallCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var captureCount = 0
    private var probeCount = 0

    func noteCapture() { lock.lock(); captureCount += 1; lock.unlock() }
    func noteProbe() { lock.lock(); probeCount += 1; lock.unlock() }

    var captures: Int { lock.lock(); defer { lock.unlock() }; return captureCount }
    var probes: Int { lock.lock(); defer { lock.unlock() }; return probeCount }
}

private final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Set<CGWindowID>

    init(value: Set<CGWindowID>) { self.storage = value }

    var value: Set<CGWindowID> {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

private final class UptimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: TimeInterval

    init(value: TimeInterval) {
        self.storage = value
    }

    var value: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

private struct BatchFixedProcessProvider: AppTrackerProcessProviding {
    func isAlive(pid: pid_t) -> Bool { true }

    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        ScanAdmissionDecision.ProcessIdentity(pid: pid, startTimeSec: 1, startTimeUsec: 2, bundleID: bundleID)
    }
}

private final class BatchMutableProcessProvider: AppTrackerProcessProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var generation: Int64 = 1

    func advanceGeneration() {
        lock.lock()
        generation += 1
        lock.unlock()
    }

    func isAlive(pid: pid_t) -> Bool { true }

    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        lock.lock()
        let current = generation
        lock.unlock()
        return ScanAdmissionDecision.ProcessIdentity(
            pid: pid,
            startTimeSec: current,
            startTimeUsec: 0,
            bundleID: bundleID
        )
    }
}
