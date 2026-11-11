import ApplicationServices
import CoreGraphics
import XCTest

/// Storage and invalidation rules of the AX element side cache.
///
/// Getting this rule wrong fails in two opposite directions, both hard to spot:
/// - leaving a stale element pointing at a destroyed window: after the cgWindowID is reused it may act on
///   **another window**;
/// - wrongly evicting a window that left `AXWindows` after minimizing: the cache is empty exactly when it
///   matters most, built for nothing.
final class AXElementCacheTests: XCTestCase {

    // MARK: - Retention

    /// Eviction goes by the **full CG list** only: gone from CG means really closed.
    func testExpiredIsExactlyWhatLeftTheCGList() {
        let expired = AXElementCacheRetention.expired(
            cachedCGWindowIDs: [1, 2, 3],
            liveCGWindowIDs: [2, 3, 4]
        )
        XCTAssertEqual(expired, [1])
    }

    /// **Still in CG means it must stay**, even if AX did not report it at all this round. Safari-family
    /// windows vanish from `AXWindows` entirely once minimized (the premise of the phantom seat self-healing
    /// rule), which is exactly when "click a minimized window to bring it back" needs the cache. Evicting on
    /// AX absence = the cache fails in the scenario it most needs to save.
    func testWindowStillInCGListSurvivesEvenWhenAXNoLongerReportsIt() {
        let expired = AXElementCacheRetention.expired(
            cachedCGWindowIDs: [7],
            liveCGWindowIDs: [7]
        )
        XCTAssertTrue(expired.isEmpty)
    }

    func testEmptyCacheExpiresNothing() {
        XCTAssertTrue(
            AXElementCacheRetention.expired(cachedCGWindowIDs: [], liveCGWindowIDs: [1, 2]).isEmpty
        )
    }

    /// When the full CG list reads empty (extreme case) the whole cache is invalidated, in line with the
    /// existing rule that only CG presence keeps a seat.
    func testEmptyLiveListExpiresEverything() {
        XCTAssertEqual(
            AXElementCacheRetention.expired(cachedCGWindowIDs: [1, 2], liveCGWindowIDs: []),
            [1, 2]
        )
    }

    // MARK: - Storage

    func testStoreAndLookupIsKeyedByPidAndWindow() {
        let cache = AXElementCache()
        let element = AXUIElementCreateApplication(getpid())

        cache.store(pid: 42, cgWindowID: 7, element: element)

        XCTAssertNotNil(cache.element(pid: 42, cgWindowID: 7))
        XCTAssertNil(cache.element(pid: 42, cgWindowID: 8), "same pid, different window must not mix")
        XCTAssertNil(cache.element(pid: 43, cgWindowID: 7), "same window number, different pid must not mix")
    }

    /// `pid <= 0` and `cgWindowID == 0` are not valid identities; storing them is asking for trouble.
    func testInvalidIdentitiesAreRejectedOnStoreAndLookup() {
        let cache = AXElementCache()
        let element = AXUIElementCreateApplication(getpid())

        cache.store(pid: 0, cgWindowID: 7, element: element)
        cache.store(pid: -1, cgWindowID: 7, element: element)
        cache.store(pid: 42, cgWindowID: 0, element: element)

        XCTAssertEqual(cache.countForTesting, 0)
        XCTAssertNil(cache.element(pid: 0, cgWindowID: 7))
        XCTAssertNil(cache.element(pid: 42, cgWindowID: 0))
    }

    func testRemoveAllDropsOnlyThatProcess() {
        let cache = AXElementCache()
        let element = AXUIElementCreateApplication(getpid())
        cache.store(pid: 42, cgWindowID: 1, element: element)
        cache.store(pid: 42, cgWindowID: 2, element: element)
        cache.store(pid: 99, cgWindowID: 3, element: element)

        cache.removeAll(pid: 42)

        XCTAssertFalse(cache.containsForTesting(pid: 42, cgWindowID: 1))
        XCTAssertFalse(cache.containsForTesting(pid: 42, cgWindowID: 2))
        XCTAssertTrue(cache.containsForTesting(pid: 99, cgWindowID: 3))
    }

    /// `retain` works per pid: another process's entries must not be cleared in passing by this reconcile
    /// (each reconcile only gets the current pid's context).
    func testRetainOnlyPrunesTheGivenProcess() {
        let cache = AXElementCache()
        let element = AXUIElementCreateApplication(getpid())
        cache.store(pid: 42, cgWindowID: 1, element: element)
        cache.store(pid: 42, cgWindowID: 2, element: element)
        cache.store(pid: 99, cgWindowID: 1, element: element)

        cache.retain(pid: 42, liveCGWindowIDs: [2])

        XCTAssertFalse(cache.containsForTesting(pid: 42, cgWindowID: 1), "gone from CG, evicted")
        XCTAssertTrue(cache.containsForTesting(pid: 42, cgWindowID: 2), "still in CG, kept")
        XCTAssertTrue(cache.containsForTesting(pid: 99, cgWindowID: 1), "other processes unaffected")
    }

    func testRemoveDropsExactlyOneEntry() {
        let cache = AXElementCache()
        let element = AXUIElementCreateApplication(getpid())
        cache.store(pid: 42, cgWindowID: 1, element: element)
        cache.store(pid: 42, cgWindowID: 2, element: element)

        cache.remove(pid: 42, cgWindowID: 1)

        XCTAssertFalse(cache.containsForTesting(pid: 42, cgWindowID: 1))
        XCTAssertTrue(cache.containsForTesting(pid: 42, cgWindowID: 2))
    }
}
