import XCTest

/// Behavior lock for BadgeStore's targeted-read rework: scope filtering,
/// transient failure keeps the old value, a list change re-walks, 10s self-heal.
@MainActor
final class BadgeStoreTests: XCTestCase {
    private let wechat = "com.tencent.xinWeChat"

    func testFullWalkThenTargetedPublishesMessagingScopedBadges() async {
        let reader = StubBadgeReader()
        reader.fullWalkResult = DockBadgeWalkOutcome(
            badges: [wechat: "3", "com.apple.mail": "12"],
            cache: DockItemCache(dockPID: 1, elementsByBundleID: [:]),
            pathToBundleID: [:]
        )
        reader.targetedResult = .ok([wechat: "5"])
        let store = BadgeStore(reader: reader, targetedEnabled: true, uptimeProvider: { 100 })
        store.updateMessagingContext(visibleMessagingIDs: [wechat], runningBundleIDs: [wechat])

        store.readOnceForTesting()
        await waitUntil { !store.isReadingForTesting }
        // Full tree walk applied: the published scope narrows to
        // messaging apps (Mail's badge stays out of the dictionary).
        XCTAssertEqual(store.badgesByBundleID, [wechat: "3"])
        XCTAssertEqual(reader.fullWalkCount, 1)

        store.readOnceForTesting()
        await waitUntil { !store.isReadingForTesting }
        XCTAssertEqual(store.badgesByBundleID, [wechat: "5"])
        XCTAssertEqual(reader.targetedCount, 1)
        XCTAssertEqual(reader.fullWalkCount, 1)
    }

    func testEmptyReadableSetMakesZeroReads() async {
        let reader = StubBadgeReader()
        let store = BadgeStore(reader: reader, targetedEnabled: true, uptimeProvider: { 100 })
        // A kept messaging app that is not running has no Dock
        // tile: readable set = visible ∩ running = empty.
        store.updateMessagingContext(visibleMessagingIDs: [wechat], runningBundleIDs: [])

        store.readOnceForTesting()
        await waitUntil { !store.isReadingForTesting }
        XCTAssertEqual(reader.fullWalkCount, 0)
        XCTAssertEqual(reader.targetedCount, 0)
        XCTAssertEqual(store.badgesByBundleID, [:])
    }

    func testCacheInvalidKeepsPreviousBadgesAndRewalksNextTick() async {
        let reader = StubBadgeReader()
        reader.fullWalkResult = DockBadgeWalkOutcome(
            badges: [wechat: "3"],
            cache: DockItemCache(dockPID: 1, elementsByBundleID: [:]),
            pathToBundleID: [:]
        )
        reader.targetedResult = .cacheInvalid
        let store = BadgeStore(reader: reader, targetedEnabled: true, uptimeProvider: { 100 })
        store.updateMessagingContext(visibleMessagingIDs: [wechat], runningBundleIDs: [wechat])

        store.readOnceForTesting()
        await waitUntil { !store.isReadingForTesting }
        store.readOnceForTesting()
        await waitUntil { !store.isReadingForTesting }
        // Transient failure: keep the last published value, the badge does not flicker away.
        XCTAssertEqual(store.badgesByBundleID, [wechat: "3"])

        store.readOnceForTesting()
        await waitUntil { !store.isReadingForTesting }
        // The next tick re-walks the full tree and recovers.
        XCTAssertEqual(reader.fullWalkCount, 2)
    }

    func testMessagingContextChangeTriggersRewalk() async {
        let reader = StubBadgeReader()
        reader.fullWalkResult = DockBadgeWalkOutcome(
            badges: [wechat: "3"],
            cache: DockItemCache(dockPID: 1, elementsByBundleID: [:]),
            pathToBundleID: [:]
        )
        reader.targetedResult = .ok([wechat: "3"])
        let store = BadgeStore(reader: reader, targetedEnabled: true, uptimeProvider: { 100 })
        store.updateMessagingContext(visibleMessagingIDs: [wechat], runningBundleIDs: [wechat])

        store.readOnceForTesting()
        await waitUntil { !store.isReadingForTesting }
        XCTAssertEqual(reader.fullWalkCount, 1)

        // A new messaging app entering the running set = a new Dock
        // tile -> the tree must be re-walked to cache the new tile.
        store.updateMessagingContext(
            visibleMessagingIDs: [wechat, "com.electron.lark"],
            runningBundleIDs: [wechat, "com.electron.lark"]
        )
        store.readOnceForTesting()
        await waitUntil { !store.isReadingForTesting }
        XCTAssertEqual(reader.fullWalkCount, 2)
    }

    func testSelfHealRewalksAfterInterval() async {
        let uptime = BadgeUptimeBox(value: 100)
        let reader = StubBadgeReader()
        reader.fullWalkResult = DockBadgeWalkOutcome(
            badges: [wechat: "3"],
            cache: DockItemCache(dockPID: 1, elementsByBundleID: [:]),
            pathToBundleID: [:]
        )
        reader.targetedResult = .ok([wechat: "3"])
        let store = BadgeStore(reader: reader, targetedEnabled: true, uptimeProvider: { uptime.value })
        store.updateMessagingContext(visibleMessagingIDs: [wechat], runningBundleIDs: [wechat])

        store.readOnceForTesting()
        await waitUntil { !store.isReadingForTesting }
        store.readOnceForTesting()
        await waitUntil { !store.isReadingForTesting }
        XCTAssertEqual(reader.fullWalkCount, 1)
        XCTAssertEqual(reader.targetedCount, 1)

        uptime.value = 111   // past the 10s self-heal interval
        store.readOnceForTesting()
        await waitUntil { !store.isReadingForTesting }
        XCTAssertEqual(reader.fullWalkCount, 2)
    }

    func testLegacyKillSwitchReadsFullTreeUnscoped() async {
        let reader = StubBadgeReader()
        reader.legacyResult = [wechat: "3", "com.apple.mail": "12"]
        let store = BadgeStore(reader: reader, targetedEnabled: false, uptimeProvider: { 100 })

        store.readOnceForTesting()
        await waitUntil { !store.isReadingForTesting }
        // Old path unchanged: ignores the messaging list and publishes every badge.
        XCTAssertEqual(store.badgesByBundleID, [wechat: "3", "com.apple.mail": "12"])
        XCTAssertEqual(reader.legacyCount, 1)
    }

    // MARK: - Zero-perception gate (WI-6)

    func testStartWithEmptyContextStaysPausedUntilMessagingAppears() async {
        let reader = StubBadgeReader()
        reader.fullWalkResult = DockBadgeWalkOutcome(
            badges: [wechat: "3"],
            cache: DockItemCache(dockPID: 1, elementsByBundleID: [:]),
            pathToBundleID: [:]
        )
        let store = BadgeStore(reader: reader, targetedEnabled: true, uptimeProvider: { 100 })
        defer { store.stop() }

        store.start()
        // No readable messaging app at all: not even the timer starts, zero AX traffic.
        XCTAssertFalse(store.isTimerRunningForTesting)
        XCTAssertEqual(reader.fullWalkCount, 0)

        store.updateMessagingContext(visibleMessagingIDs: [wechat], runningBundleIDs: [wechat])
        // Resume condition appears: the timer is rebuilt and reads once immediately.
        XCTAssertTrue(store.isTimerRunningForTesting)
        await waitUntil { !store.isReadingForTesting && reader.fullWalkCount == 1 }
        XCTAssertEqual(reader.fullWalkCount, 1)
        XCTAssertEqual(store.badgesByBundleID, [wechat: "3"])
    }

    func testHiddenTaskbarPausesAndKeepsBadgesThenResumeReadsImmediately() async {
        let reader = StubBadgeReader()
        reader.fullWalkResult = DockBadgeWalkOutcome(
            badges: [wechat: "3"],
            cache: DockItemCache(dockPID: 1, elementsByBundleID: [:]),
            pathToBundleID: [:]
        )
        reader.targetedResult = .ok([wechat: "3"])
        let store = BadgeStore(reader: reader, targetedEnabled: true, uptimeProvider: { 100 })
        defer { store.stop() }
        store.updateMessagingContext(visibleMessagingIDs: [wechat], runningBundleIDs: [wechat])
        store.start()
        await waitUntil { !store.isReadingForTesting && reader.fullWalkCount == 1 }

        store.setTaskbarVisible(false)
        XCTAssertFalse(store.isTimerRunningForTesting)
        // The last value is kept while hidden: on re-show the
        // chip appears with the old badge at once, no flicker.
        XCTAssertEqual(store.badgesByBundleID, [wechat: "3"])
        let readsWhileHidden = reader.fullWalkCount + reader.targetedCount

        store.setTaskbarVisible(true)
        XCTAssertTrue(store.isTimerRunningForTesting)
        await waitUntil { !store.isReadingForTesting && reader.fullWalkCount + reader.targetedCount > readsWhileHidden }
        // Resume must read once immediately, not wait for the next 0.5s tick.
        XCTAssertEqual(reader.fullWalkCount + reader.targetedCount, readsWhileHidden + 1)
    }

    func testPauseKillSwitchKeepsTimerRunning() {
        let reader = StubBadgeReader()
        let store = BadgeStore(
            reader: reader,
            targetedEnabled: true,
            pauseEnabled: false,
            uptimeProvider: { 100 }
        )
        defer { store.stop() }

        store.start()
        // DOCK_BADGE_PAUSE=0: the timer stays alive; an empty-list
        // tick itself has zero AX traffic (no calls are observed).
        XCTAssertTrue(store.isTimerRunningForTesting)
        XCTAssertEqual(reader.fullWalkCount, 0)
        XCTAssertEqual(reader.targetedCount, 0)
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

private final class StubBadgeReader: DockBadgeReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _fullWalkResult = DockBadgeWalkOutcome(badges: [:], cache: nil, pathToBundleID: [:])
    private var _targetedResult = DockBadgeTargetedOutcome.ok([:])
    private var _legacyResult: [String: String] = [:]
    private var _fullWalkCount = 0
    private var _targetedCount = 0
    private var _legacyCount = 0

    var fullWalkResult: DockBadgeWalkOutcome {
        get { lock.lock(); defer { lock.unlock() }; return _fullWalkResult }
        set { lock.lock(); _fullWalkResult = newValue; lock.unlock() }
    }

    var targetedResult: DockBadgeTargetedOutcome {
        get { lock.lock(); defer { lock.unlock() }; return _targetedResult }
        set { lock.lock(); _targetedResult = newValue; lock.unlock() }
    }

    var legacyResult: [String: String] {
        get { lock.lock(); defer { lock.unlock() }; return _legacyResult }
        set { lock.lock(); _legacyResult = newValue; lock.unlock() }
    }

    var fullWalkCount: Int { lock.lock(); defer { lock.unlock() }; return _fullWalkCount }
    var targetedCount: Int { lock.lock(); defer { lock.unlock() }; return _targetedCount }
    var legacyCount: Int { lock.lock(); defer { lock.unlock() }; return _legacyCount }

    func readBadges() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        _legacyCount += 1
        return _legacyResult
    }

    func fullWalk(previousPathMap: [String: String]) -> DockBadgeWalkOutcome {
        lock.lock(); defer { lock.unlock() }
        _fullWalkCount += 1
        return _fullWalkResult
    }

    func targetedRead(
        cache: DockItemCache,
        bundleIDs: [String],
        previousBadges: [String: String]
    ) -> DockBadgeTargetedOutcome {
        lock.lock(); defer { lock.unlock() }
        _targetedCount += 1
        return _targetedResult
    }
}

private final class BadgeUptimeBox: @unchecked Sendable {
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
