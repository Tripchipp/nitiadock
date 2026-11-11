import XCTest

final class DocumentUsageRankingTests: XCTestCase {
    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: offset)
    }

    func testCountedFilesOutrankRecentOnlyAndTiesFallToRecency() {
        let counts = [
            "/a": DocumentUsageRecord(count: 3, lastOpened: date(10)),
            "/b": DocumentUsageRecord(count: 3, lastOpened: date(20)),
            "/c": DocumentUsageRecord(count: 1, lastOpened: date(99)),
        ]
        let ranked = DocumentUsageRanking.ranked(counts: counts, recentPaths: ["/new1", "/new2", "/a"])
        XCTAssertEqual(ranked.prefix(3), ["/b", "/a", "/c"], "equal counts compare lastOpened, a higher count always comes first")
        XCTAssertEqual(Array(ranked.suffix(2)), ["/new1", "/new2"], "uncounted entries go last, in system recent order")
    }

    func testRankedDeduplicatesAndHonorsLimit() {
        let ranked = DocumentUsageRanking.ranked(
            counts: [:],
            recentPaths: ["/x", "/x", "/y", "/z"],
            limit: 2
        )
        XCTAssertEqual(ranked, ["/x", "/y"])
    }

    func testEmptyCountsMatchesSystemRecentOrder() {
        let ranked = DocumentUsageRanking.ranked(counts: [:], recentPaths: ["/1", "/2", "/3"])
        XCTAssertEqual(ranked, ["/1", "/2", "/3"], "first days after upgrading = the old 'recent' order")
    }

    func testBumpIncrementsAndEvictsLowestWhenOverCap() {
        var files = [
            "/low": DocumentUsageRecord(count: 1, lastOpened: date(1)),
            "/mid": DocumentUsageRecord(count: 1, lastOpened: date(50)),
            "/high": DocumentUsageRecord(count: 9, lastOpened: date(2)),
        ]
        files = DocumentUsageRanking.bumped(files, path: "/new", at: date(100), cap: 3)
        XCTAssertEqual(files["/new"]?.count, 1)
        XCTAssertNil(files["/low"], "evicts the lowest count, least recently opened")
        XCTAssertNotNil(files["/mid"])
        XCTAssertNotNil(files["/high"])

        files = DocumentUsageRanking.bumped(files, path: "/new", at: date(101), cap: 3)
        XCTAssertEqual(files["/new"]?.count, 2, "repeated +1 accumulates and no longer evicts (under capacity)")
    }

    func testBumpNeverEvictsTheJustBumpedPath() {
        let files = DocumentUsageRanking.bumped([:], path: "/only", at: date(1), cap: 0)
        XCTAssertNotNil(files["/only"], "however small the cap, the one just used is never evicted")
    }

    func testTopChangeCountsOnlyRealTransitions() {
        XCTAssertFalse(DocumentUsageRanking.shouldCountTopChange(previousTop: nil, newTop: "/a"), "the first sample only sets the baseline")
        XCTAssertFalse(DocumentUsageRanking.shouldCountTopChange(previousTop: "/a", newTop: "/a"), "a repeated sample is not counted")
        XCTAssertFalse(DocumentUsageRanking.shouldCountTopChange(previousTop: "/a", newTop: nil), "clearing is not counted")
        XCTAssertTrue(DocumentUsageRanking.shouldCountTopChange(previousTop: "/a", newTop: "/b"))
    }

    func testBundlePruneKeepsMostRecentlyTouched() {
        let store = [
            "com.old": BundleDocumentUsage(files: [:], lastTop: nil, touchedAt: date(1)),
            "com.mid": BundleDocumentUsage(files: [:], lastTop: nil, touchedAt: date(50)),
            "com.new": BundleDocumentUsage(files: [:], lastTop: nil, touchedAt: date(99)),
        ]
        let pruned = DocumentUsageRanking.prunedBundles(store, maxBundles: 2)
        XCTAssertEqual(Set(pruned.keys), ["com.mid", "com.new"])
        XCTAssertEqual(DocumentUsageRanking.prunedBundles(store, maxBundles: 3).count, 3, "under the limit, nothing changes")
    }
}
