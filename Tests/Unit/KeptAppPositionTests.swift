import XCTest
@testable import NitiaDock

@MainActor
final class KeptAppPositionTests: XCTestCase {

    /// Mutable time box so the `now` closure can be advanced from test methods.
    private final class TimeBox {
        var time: Date
        init(_ time: Date) { self.time = time }
    }

    private func makeStore(timeBox: TimeBox, keptIDs: Set<String> = []) -> StripOrderStore {
        let suite = "test-kept-pos-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return StripOrderStore(
            defaults: defaults,
            now: { timeBox.time },
            keptIDsProvider: { keptIDs }
        )
    }

    // MARK: - a. app exit → tabgrp-* grace → app-* placeholder → position = rightmost tabgrp-*

    func testExitPlaceholderInheritsRightmostWindowPosition() {
        let timeBox = TimeBox(Date())
        let store = makeStore(timeBox: timeBox)
        // Two windows from com.app, already ordered
        store.sync(current: ["tabgrp-100-s1", "tabgrp-100-s2"],
                   appKeyOf: ["tabgrp-100-s1": "com.app", "tabgrp-100-s2": "com.app"])
        // App exits → placeholder injected (DockStripView would do this)
        store.sync(current: ["app-com.app"],
                   appKeyOf: ["app-com.app": "com.app"])
        // Grace: tabgrp-* still in liveOrder; placeholder inserted after rightmost tabgrp-*
        // reconciled returns only ids in current (the user sees just the placeholder), but liveOrder keeps
        // the full positions
        XCTAssertEqual(store.liveOrder, ["tabgrp-100-s1", "tabgrp-100-s2", "app-com.app"])
        XCTAssertEqual(store.reconciled(current: ["app-com.app"],
                                        appKeyOf: ["app-com.app": "com.app"]),
                       ["app-com.app"])
    }

    // MARK: - b. grace expires → tabgrp-* gone → placeholder keeps position

    func testGraceExpiresPlaceholderStaysInPlace() {
        let timeBox = TimeBox(Date())
        let store = makeStore(timeBox: timeBox)
        // com.app has two windows on the left, com.other one on the right; a placeholder "staying put" =
        // staying left of com.other
        store.sync(current: ["tabgrp-100-s1", "tabgrp-100-s2", "tabgrp-300-s1"],
                   appKeyOf: ["tabgrp-100-s1": "com.app", "tabgrp-100-s2": "com.app",
                              "tabgrp-300-s1": "com.other"])
        store.sync(current: ["app-com.app", "tabgrp-300-s1"],
                   appKeyOf: ["app-com.app": "com.app", "tabgrp-300-s1": "com.other"])
        // Within grace: the placeholder is inserted after this app's rightmost window card, still left of
        // com.other
        XCTAssertEqual(store.liveOrder,
                       ["tabgrp-100-s1", "tabgrp-100-s2", "app-com.app", "tabgrp-300-s1"])
        // Advance past grace (5s)
        timeBox.time = Date().addingTimeInterval(6)
        store.sync(current: ["app-com.app", "tabgrp-300-s1"],
                   appKeyOf: ["app-com.app": "com.app", "tabgrp-300-s1": "com.other"])
        // Grace expired: tabgrp-100-* really leaves liveOrder, the placeholder stays put (left of com.other)
        XCTAssertEqual(store.liveOrder, ["app-com.app", "tabgrp-300-s1"])
        XCTAssertEqual(store.reconciled(current: ["app-com.app", "tabgrp-300-s1"],
                                        appKeyOf: ["app-com.app": "com.app",
                                                   "tabgrp-300-s1": "com.other"]),
                       ["app-com.app", "tabgrp-300-s1"])
    }

    // MARK: - c. click placeholder → new tabgrp-* inserts next to placeholder → placeholder stops → window block returns

    func testLaunchFromPlaceholderInsertsNextToIt() {
        let timeBox = TimeBox(Date())
        let store = makeStore(timeBox: timeBox)
        store.sync(current: ["tabgrp-100-s1", "tabgrp-100-s2"],
                   appKeyOf: ["tabgrp-100-s1": "com.app", "tabgrp-100-s2": "com.app"])
        // Exit → placeholder
        store.sync(current: ["app-com.app"],
                   appKeyOf: ["app-com.app": "com.app"])
        // Advance past grace
        timeBox.time = Date().addingTimeInterval(6)
        store.sync(current: ["app-com.app"],
                   appKeyOf: ["app-com.app": "com.app"])
        // New window appears → sticky appKey for "app-com.app" = "com.app"
        // New tabgrp-* should insert after "app-com.app" (same appKey)
        store.sync(current: ["app-com.app", "tabgrp-100-s3"],
                   appKeyOf: ["app-com.app": "com.app", "tabgrp-100-s3": "com.app"])
        let reconciled = store.reconciled(current: ["app-com.app", "tabgrp-100-s3"],
                                          appKeyOf: ["app-com.app": "com.app", "tabgrp-100-s3": "com.app"])
        XCTAssertEqual(reconciled, ["app-com.app", "tabgrp-100-s3"])
        // Now placeholder stops injecting (app running with real window)
        store.sync(current: ["tabgrp-100-s3"],
                   appKeyOf: ["tabgrp-100-s3": "com.app"])
        // app-com.app enters grace, still in liveOrder temporarily
        // reconciled returns only current (the user sees just tabgrp-100-s3), but liveOrder keeps
        // app-com.app's position
        XCTAssertEqual(store.liveOrder, ["app-com.app", "tabgrp-100-s3"])
        XCTAssertEqual(store.reconciled(current: ["tabgrp-100-s3"],
                                        appKeyOf: ["tabgrp-100-s3": "com.app"]),
                       ["tabgrp-100-s3"])
    }

    // MARK: - d. multiple kept apps alternate exit/launch without cross-contamination

    func testMultipleKeptAppsNoCrossContamination() {
        let timeBox = TimeBox(Date())
        let store = makeStore(timeBox: timeBox)
        // Two apps with windows, interleaved in order
        store.sync(current: ["tabgrp-100-s1", "tabgrp-200-s1", "tabgrp-100-s2"],
                   appKeyOf: ["tabgrp-100-s1": "com.a", "tabgrp-200-s1": "com.b", "tabgrp-100-s2": "com.a"])
        // App A exits → placeholder
        store.sync(current: ["tabgrp-200-s1", "app-com.a"],
                   appKeyOf: ["tabgrp-200-s1": "com.b", "app-com.a": "com.a"])
        // Advance past grace for tabgrp-100-*
        timeBox.time = Date().addingTimeInterval(6)
        store.sync(current: ["tabgrp-200-s1", "app-com.a"],
                   appKeyOf: ["tabgrp-200-s1": "com.b", "app-com.a": "com.a"])
        // App B exits → placeholder
        store.sync(current: ["app-com.a", "app-com.b"],
                   appKeyOf: ["app-com.a": "com.a", "app-com.b": "com.b"])
        // Advance past grace for tabgrp-200-s1
        timeBox.time = Date().addingTimeInterval(12)
        store.sync(current: ["app-com.a", "app-com.b"],
                   appKeyOf: ["app-com.a": "com.a", "app-com.b": "com.b"])
        // Both placeholders in order: A before B (matching original interleaving)
        let reconciled = store.reconciled(current: ["app-com.a", "app-com.b"],
                                          appKeyOf: ["app-com.a": "com.a", "app-com.b": "com.b"])
        XCTAssertEqual(reconciled, ["app-com.a", "app-com.b"])
        // App A relaunches → new window inserts next to app-com.a
        store.sync(current: ["app-com.a", "tabgrp-100-s3", "app-com.b"],
                   appKeyOf: ["app-com.a": "com.a", "tabgrp-100-s3": "com.a", "app-com.b": "com.b"])
        let reconciled2 = store.reconciled(current: ["app-com.a", "tabgrp-100-s3", "app-com.b"],
                                           appKeyOf: ["app-com.a": "com.a", "tabgrp-100-s3": "com.a", "app-com.b": "com.b"])
        XCTAssertEqual(reconciled2, ["app-com.a", "tabgrp-100-s3", "app-com.b"])
    }

    // MARK: - e. sticky appKey pruning

    func testStickyAppKeyPruning() {
        let timeBox = TimeBox(Date())
        let store = makeStore(timeBox: timeBox)
        // com.app on the left, com.other on the right. If the sticky key / old id is not cleared, a reopened
        // window wrongly rejoins the old spot on the left
        store.sync(current: ["tabgrp-100-s1", "tabgrp-300-s1"],
                   appKeyOf: ["tabgrp-100-s1": "com.app", "tabgrp-300-s1": "com.other"])
        // com.app closes (not kept, no placeholder injected); after grace expires both the id and the sticky
        // key should be cleared
        store.sync(current: ["tabgrp-300-s1"],
                   appKeyOf: ["tabgrp-300-s1": "com.other"])
        timeBox.time = Date().addingTimeInterval(6)
        store.sync(current: ["tabgrp-300-s1"],
                   appKeyOf: ["tabgrp-300-s1": "com.other"])
        XCTAssertEqual(store.liveOrder, ["tabgrp-300-s1"])
        // A new window reopens: no leftover memory to match → appended at the end (right of com.other), the
        // old position is not revived
        store.sync(current: ["tabgrp-300-s1", "tabgrp-100-s2"],
                   appKeyOf: ["tabgrp-300-s1": "com.other", "tabgrp-100-s2": "com.app"])
        XCTAssertEqual(store.liveOrder, ["tabgrp-300-s1", "tabgrp-100-s2"])
    }

    // MARK: - f. persistableLiveOrder with keptIDs

    func testPersistableLiveOrderWithKeptIDs() {
        let order = ["tabgrp-1-s1", "app-com.kept", "app-com.notkept", "tabgrp-2-s1"]
        let result = StripOrdering.persistableLiveOrder(order, keptIDs: ["com.kept"])
        XCTAssertEqual(result, ["tabgrp-1-s1", "app-com.kept", "tabgrp-2-s1"])
    }

    func testPersistableLiveOrderWithoutKeptIDs() {
        let order = ["tabgrp-1-s1", "app-com.kept", "tabgrp-2-s1"]
        let result = StripOrdering.persistableLiveOrder(order)
        XCTAssertEqual(result, ["tabgrp-1-s1", "tabgrp-2-s1"])
    }

    // MARK: - Cross-boot stable kept app blocks

    func testDifferentBootRestoresRunningKeptAppsAsStableBlocks() {
        let suite = "test-kept-cross-boot-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(["com.b", "com.a"], forKey: "stripKeptAppOrderV1")
        defaults.set(["tabgrp-old-a", "tabgrp-old-b"], forKey: "stripLiveOrder")
        defaults.set(1, forKey: "stripLiveOrderBootTime")
        let store = StripOrderStore(
            defaults: defaults,
            keptIDsProvider: { ["com.a", "com.b"] },
            stableKeptOrderProvider: { ["com.a", "com.b"] },
            bootTimeProvider: { 2 }
        )
        let current = ["tabgrp-new-a", "tabgrp-temp", "tabgrp-new-b1", "tabgrp-new-b2"]
        let keys = [
            "tabgrp-new-a": "com.a",
            "tabgrp-temp": "com.temp",
            "tabgrp-new-b1": "com.b",
            "tabgrp-new-b2": "com.b",
        ]

        XCTAssertEqual(
            store.reconciled(current: current, appKeyOf: keys),
            ["tabgrp-new-b1", "tabgrp-new-b2", "tabgrp-new-a", "tabgrp-temp"]
        )
        store.sync(current: current, appKeyOf: keys)
        XCTAssertEqual(store.liveOrder, ["tabgrp-new-b1", "tabgrp-new-b2", "tabgrp-new-a", "tabgrp-temp"])
    }

    func testColdStartKeepsMessagingPopoutAheadOfStableKeptBlocks() {
        let suite = "test-kept-message-head-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(["com.kept"], forKey: "stripKeptAppOrderV1")
        let store = StripOrderStore(
            defaults: defaults,
            keptIDsProvider: { ["com.kept", "com.message"] },
            stableKeptOrderProvider: { ["com.kept"] },
            bootTimeProvider: { 2 }
        )
        let current = ["tabgrp-temp", "tabgrp-kept", "tabgrp-message"]
        let keys = [
            "tabgrp-temp": "com.temp",
            "tabgrp-kept": "com.kept",
            "tabgrp-message": "com.message",
        ]
        XCTAssertEqual(
            store.reconciled(current: current, appKeyOf: keys, headPreferred: ["com.message"]),
            ["tabgrp-message", "tabgrp-kept", "tabgrp-temp"]
        )
    }

    /// Cross-restart ranking is **not a one-off cold-start mode**. At login the taskbar starts before most
    /// apps (AppTracker still has four rescans at 0.5/1/2/4 seconds), and at the first sync `current` often
    /// holds only the placeholder icons of kept apps that are not running. Late windows must follow the same
    /// ranking rule, otherwise "keep app order across restarts" does nothing for apps **already running at
    /// boot** (they drop to the end). This locks that timing.
    func testStableRankStillAppliesToWindowsArrivingAfterTheFirstSync() {
        let suite = "test-kept-late-arrival-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(["com.a", "com.b"], forKey: "stripKeptAppOrderV1")
        defaults.set(["tabgrp-old"], forKey: "stripLiveOrder")
        defaults.set(1, forKey: "stripLiveOrderBootTime")
        let store = StripOrderStore(
            defaults: defaults,
            keptIDsProvider: { ["com.a", "com.b"] },
            stableKeptOrderProvider: { ["com.a", "com.b"] },
            bootTimeProvider: { 2 }   // boot time changed = the machine was restarted
        )

        // First sync: com.b is not up yet, only com.a's placeholder icon and one transient window.
        let firstKeys = ["app-com.a": "com.a", "tabgrp-temp": "com.temp"]
        store.sync(current: ["app-com.a", "tabgrp-temp"], appKeyOf: firstKeys)
        XCTAssertEqual(store.liveOrder, ["app-com.a", "tabgrp-temp"])

        // com.b's window shows up later: by rank it lands after com.a and before the transient window, not at
        // the end.
        let lateCurrent = ["app-com.a", "tabgrp-temp", "tabgrp-b1"]
        let lateKeys = firstKeys.merging(["tabgrp-b1": "com.b"]) { _, new in new }
        XCTAssertEqual(
            store.reconciled(current: lateCurrent, appKeyOf: lateKeys),
            ["app-com.a", "tabgrp-b1", "tabgrp-temp"],
            "the render path must share its source with sync, otherwise a first-frame tail insert that bounces back = shadow slide"
        )
        store.sync(current: lateCurrent, appKeyOf: lateKeys)
        XCTAssertEqual(store.liveOrder, ["app-com.a", "tabgrp-b1", "tabgrp-temp"])
    }

    func testSameBootKeepsExactChipOrderInsteadOfRebuildingBlocks() {
        let suite = "test-kept-same-boot-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(["com.kept"], forKey: "stripKeptAppOrderV1")
        defaults.set(["tabgrp-temp", "tabgrp-kept"], forKey: "stripLiveOrder")
        defaults.set(7, forKey: "stripLiveOrderBootTime")
        let store = StripOrderStore(
            defaults: defaults,
            keptIDsProvider: { ["com.kept"] },
            stableKeptOrderProvider: { ["com.kept"] },
            bootTimeProvider: { 7 }
        )
        XCTAssertEqual(
            store.reconciled(
                current: ["tabgrp-kept", "tabgrp-temp"],
                appKeyOf: ["tabgrp-kept": "com.kept", "tabgrp-temp": "com.temp"]
            ),
            ["tabgrp-temp", "tabgrp-kept"]
        )
    }

    func testStableOrderMigratesLegacyPlaceholdersAndAppendsKeptStoreOrder() {
        let suite = "test-kept-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(["tabgrp-old", "app-com.b", "app-com.a"], forKey: "stripLiveOrder")
        let store = StripOrderStore(
            defaults: defaults,
            keptIDsProvider: { ["com.a", "com.b", "com.c"] },
            stableKeptOrderProvider: { ["com.a", "com.b", "com.c"] },
            bootTimeProvider: { 2 }
        )
        XCTAssertEqual(store.stableKeptAppOrder, ["com.b", "com.a", "com.c"])
    }

    func testExistingEmptyStableArchiveIsRepairedBeforeFirstColdRender() {
        let suite = "test-kept-empty-stable-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set([String](), forKey: "stripKeptAppOrderV1")
        defaults.set(1, forKey: "stripLiveOrderBootTime")
        let store = StripOrderStore(
            defaults: defaults,
            keptIDsProvider: { ["com.a", "com.b"] },
            stableKeptOrderProvider: { ["com.b", "com.a"] },
            bootTimeProvider: { 2 }
        )
        let current = ["temp", "a", "b"]
        let keys = ["temp": "com.temp", "a": "com.a", "b": "com.b"]
        XCTAssertEqual(store.stableKeptAppOrder, ["com.b", "com.a"])
        XCTAssertEqual(store.reconciled(current: current, appKeyOf: keys), ["b", "a", "temp"])
    }

    func testStableOrderFollowsDragAndPrunesCancelledKeep() {
        final class MembershipBox { var order = ["com.a", "com.b"] }
        let membership = MembershipBox()
        let suite = "test-kept-stable-drag-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(membership.order, forKey: "stripKeptAppOrderV1")
        let store = StripOrderStore(
            defaults: defaults,
            keptIDsProvider: { Set(membership.order) },
            stableKeptOrderProvider: { membership.order },
            bootTimeProvider: { 2 }
        )
        let keys = ["tabgrp-a": "com.a", "tabgrp-b": "com.b"]
        store.sync(current: ["tabgrp-a", "tabgrp-b"], appKeyOf: keys)
        store.reorder(
            draggedID: "tabgrp-b",
            relativeTo: "tabgrp-a",
            after: false,
            current: ["tabgrp-a", "tabgrp-b"]
        )
        XCTAssertEqual(store.stableKeptAppOrder, ["com.b", "com.a"])

        membership.order = ["com.a"]
        store.sync(current: ["tabgrp-b", "tabgrp-a"], appKeyOf: keys)
        XCTAssertEqual(store.stableKeptAppOrder, ["com.a"])
    }

    func testReconcileTraceReportsActualPlacementBranches() {
        let result = StripOrdering.reconcileWithTrace(
            remembered: ["a1"],
            current: ["a1", "a2", "message", "tail"],
            appKeyOf: ["a1": "a", "a2": "a", "message": "msg", "tail": "tail"],
            headPreferredKeys: ["msg"]
        )
        XCTAssertEqual(result.order, ["message", "a1", "a2", "tail"])
        XCTAssertEqual(result.placements.map(\.reason), [.sameAppSibling, .headPreferred, .tail])
    }

    // MARK: - g. pre-sync first-frame consistency (shadow slide fix)
    //
    // Key point: DockStripView renders the first frame with the **old liveOrder + new current** (reconciled),
    // and only `.onChange` triggers sync. These cases call reconciled directly, **without first running sync
    // for that current**, locking that the first frame no longer throws new app-*/tabgrp-* entries to the
    // tail (otherwise the spring pulls them back from the right = shadow slide).

    /// First frame on quit: a kept app between two entries quits; the placeholder lands in place on the first
    /// frame, never at the tail.
    func testExitFirstFramePreSyncKeepsPosition() {
        let timeBox = TimeBox(Date())
        let store = makeStore(timeBox: timeBox)
        store.sync(current: ["tabgrp-A", "tabgrp-K", "tabgrp-B"],
                   appKeyOf: ["tabgrp-A": "com.a", "tabgrp-K": "com.k", "tabgrp-B": "com.b"])
        // K quits: sync has not run, current already has the placeholder app-com.k
        let firstFrame = store.reconciled(
            current: ["tabgrp-A", "app-com.k", "tabgrp-B"],
            appKeyOf: ["tabgrp-A": "com.a", "app-com.k": "com.k", "tabgrp-B": "com.b"])
        XCTAssertEqual(firstFrame, ["tabgrp-A", "app-com.k", "tabgrp-B"])
    }

    /// First frame on reopen: the real mutually exclusive switch from placeholder to new window; visible
    /// order is identical pre-sync and post-sync.
    func testReopenFirstFramePreSyncMatchesPostSync() {
        let timeBox = TimeBox(Date())
        let store = makeStore(timeBox: timeBox)
        store.sync(current: ["tabgrp-A", "tabgrp-K", "tabgrp-B"],
                   appKeyOf: ["tabgrp-A": "com.a", "tabgrp-K": "com.k", "tabgrp-B": "com.b"])
        store.sync(current: ["tabgrp-A", "app-com.k", "tabgrp-B"],
                   appKeyOf: ["tabgrp-A": "com.a", "app-com.k": "com.k", "tabgrp-B": "com.b"])
        timeBox.time = timeBox.time.addingTimeInterval(6) // past grace, the old tabgrp-K settles
        store.sync(current: ["tabgrp-A", "app-com.k", "tabgrp-B"],
                   appKeyOf: ["tabgrp-A": "com.a", "app-com.k": "com.k", "tabgrp-B": "com.b"])
        XCTAssertEqual(store.liveOrder, ["tabgrp-A", "app-com.k", "tabgrp-B"])
        // Reopen: placeholder → new window tabgrp-new (mutually exclusive, never both). First-frame render
        // (sync not run).
        let keys = ["tabgrp-A": "com.a", "tabgrp-new": "com.k", "tabgrp-B": "com.b"]
        let preSync = store.reconciled(current: ["tabgrp-A", "tabgrp-new", "tabgrp-B"], appKeyOf: keys)
        store.sync(current: ["tabgrp-A", "tabgrp-new", "tabgrp-B"], appKeyOf: keys)
        let postSync = store.reconciled(current: ["tabgrp-A", "tabgrp-new", "tabgrp-B"], appKeyOf: keys)
        XCTAssertEqual(preSync, ["tabgrp-A", "tabgrp-new", "tabgrp-B"])
        XCTAssertEqual(preSync, postSync)
    }

    /// A multi-window kept app collapses into one placeholder: the first frame inherits the whole window
    /// block's rank (between its two neighbors).
    func testMultiWindowKeptCollapsesToPlaceholderKeepingRank() {
        let timeBox = TimeBox(Date())
        let store = makeStore(timeBox: timeBox)
        store.sync(current: ["tabgrp-L", "tabgrp-K1", "tabgrp-K2", "tabgrp-R"],
                   appKeyOf: ["tabgrp-L": "com.l", "tabgrp-K1": "com.k",
                              "tabgrp-K2": "com.k", "tabgrp-R": "com.r"])
        // Both windows quit together → single placeholder, first-frame render
        let firstFrame = store.reconciled(
            current: ["tabgrp-L", "app-com.k", "tabgrp-R"],
            appKeyOf: ["tabgrp-L": "com.l", "app-com.k": "com.k", "tabgrp-R": "com.r"])
        XCTAssertEqual(firstFrame, ["tabgrp-L", "app-com.k", "tabgrp-R"])
    }

    /// An ordinary (non-kept) app gets a new seat within grace: the first frame inherits the old position.
    /// Reopening after grace lands at the tail, covered by the existing `testStickyAppKeyPruning`.
    func testPlainAppNewSeatWithinGraceInheritsPositionFirstFrame() {
        let timeBox = TimeBox(Date())
        let store = makeStore(timeBox: timeBox)
        store.sync(current: ["tabgrp-L", "tabgrp-K1", "tabgrp-R"],
                   appKeyOf: ["tabgrp-L": "com.l", "tabgrp-K1": "com.k", "tabgrp-R": "com.r"])
        // K1 closes (ordinary app, no placeholder injected) → sync stamps it, liveOrder still holds K1
        // (within grace)
        store.sync(current: ["tabgrp-L", "tabgrp-R"],
                   appKeyOf: ["tabgrp-L": "com.l", "tabgrp-R": "com.r"])
        XCTAssertEqual(store.liveOrder, ["tabgrp-L", "tabgrp-K1", "tabgrp-R"])
        timeBox.time = timeBox.time.addingTimeInterval(2) // still within grace
        // New window K2 first-frame render (sync not run) → inherits K1's position, not thrown to the tail
        let firstFrame = store.reconciled(
            current: ["tabgrp-L", "tabgrp-K2", "tabgrp-R"],
            appKeyOf: ["tabgrp-L": "com.l", "tabgrp-K2": "com.k", "tabgrp-R": "com.r"])
        XCTAssertEqual(firstFrame, ["tabgrp-L", "tabgrp-K2", "tabgrp-R"])
    }

    /// Several kept apps quit in the same frame (placeholders coexist): no position mix-up on the first
    /// frame.
    func testMultipleKeptAppsFirstFrameNoCrossContamination() {
        let timeBox = TimeBox(Date())
        let store = makeStore(timeBox: timeBox)
        store.sync(current: ["tabgrp-A1", "tabgrp-B1", "tabgrp-A2", "tabgrp-C1"],
                   appKeyOf: ["tabgrp-A1": "com.a", "tabgrp-B1": "com.b",
                              "tabgrp-A2": "com.a", "tabgrp-C1": "com.c"])
        // A and B quit in the same frame → a placeholder each; C stays. First-frame render.
        let firstFrame = store.reconciled(
            current: ["app-com.a", "app-com.b", "tabgrp-C1"],
            appKeyOf: ["app-com.a": "com.a", "app-com.b": "com.b", "tabgrp-C1": "com.c"])
        // A's placeholder inherits the A block (head of the old A1..A2 range = before B1); B's inherits B1's
        // position; C does not move.
        XCTAssertEqual(firstFrame, ["app-com.a", "app-com.b", "tabgrp-C1"])
    }
}
