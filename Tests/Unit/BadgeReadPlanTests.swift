import XCTest

/// Decision matrix of the badge read plan: pause priority, each reason for
/// a full tree walk, targeted-read passthrough, 10s self-heal boundary.
final class BadgeReadPlanTests: XCTestCase {
    private func input(
        messagingBundleIDs: [String] = ["com.tencent.xinWeChat"],
        taskbarVisible: Bool = true,
        hasCache: Bool = true,
        cacheAgeSeconds: TimeInterval = 3,
        rewalkRequested: Bool = false
    ) -> BadgeReadPlan.Input {
        BadgeReadPlan.Input(
            messagingBundleIDs: messagingBundleIDs,
            taskbarVisible: taskbarVisible,
            hasCache: hasCache,
            cacheAgeSeconds: cacheAgeSeconds,
            rewalkRequested: rewalkRequested
        )
    }

    func testEmptyMessagingListPausesBeforeEverything() {
        // pause takes priority over the tree walk: with nothing
        // readable, not even the cache is rebuilt (zero AX traffic).
        XCTAssertEqual(
            BadgeReadPlan.verdict(input(messagingBundleIDs: [], hasCache: false, rewalkRequested: true)),
            .pause
        )
    }

    func testHiddenTaskbarPausesBeforeEverything() {
        XCTAssertEqual(
            BadgeReadPlan.verdict(input(taskbarVisible: false, hasCache: false, rewalkRequested: true)),
            .pause
        )
    }

    func testMissingCacheWalks() {
        XCTAssertEqual(
            BadgeReadPlan.verdict(input(hasCache: false)),
            .fullWalk(.noCache)
        )
    }

    func testRequestedRewalkWalks() {
        XCTAssertEqual(
            BadgeReadPlan.verdict(input(rewalkRequested: true)),
            .fullWalk(.rewalkRequested)
        )
    }

    func testSelfHealBoundaryIsInclusive() {
        XCTAssertEqual(
            BadgeReadPlan.verdict(input(cacheAgeSeconds: BadgeReadPlan.defaultFullWalkInterval)),
            .fullWalk(.selfHealDue)
        )
        XCTAssertEqual(
            BadgeReadPlan.verdict(input(cacheAgeSeconds: BadgeReadPlan.defaultFullWalkInterval - 0.001)),
            .targeted(["com.tencent.xinWeChat"])
        )
    }

    func testQuietTickReadsTargetedMessagingSet() {
        XCTAssertEqual(
            BadgeReadPlan.verdict(input(messagingBundleIDs: ["a", "b"])),
            .targeted(["a", "b"])
        )
    }
}
