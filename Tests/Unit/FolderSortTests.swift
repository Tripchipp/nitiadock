import XCTest

/// The four FolderSortOrder pure sort functions (FolderContentsLoader.sorted(_:by:)).
final class FolderSortTests: XCTestCase {
    private func entry(
        _ name: String,
        isDirectory: Bool = false,
        added: TimeInterval? = nil,
        modified: TimeInterval? = nil
    ) -> FolderContentsLoader.Entry {
        FolderContentsLoader.Entry(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            name: name,
            isDirectory: isDirectory,
            dateAdded: added.map { Date(timeIntervalSince1970: $0) },
            dateModified: modified.map { Date(timeIntervalSince1970: $0) }
        )
    }

    func testNameSortIsLocalizedNumericAware() {
        let sorted = FolderContentsLoader.sorted([
            entry("file10"), entry("file2"), entry("File1"),
        ], by: .name)
        // localizedStandardCompare: number-aware (file2 < file10), case-insensitive.
        XCTAssertEqual(sorted.map(\.name), ["File1", "file2", "file10"])
    }

    func testDateAddedSortMatchesLegacyOrder() {
        let entries = [
            entry("old", added: 100),
            entry("new", added: 300),
            entry("mid", added: 200),
        ]
        XCTAssertEqual(
            FolderContentsLoader.sorted(entries, by: .dateAdded),
            FolderContentsLoader.sortedByDateAdded(entries)
        )
    }

    func testDateModifiedNewestFirstWithFallbackToDateAdded() {
        let sorted = FolderContentsLoader.sorted([
            entry("modified-early", modified: 100),
            entry("modified-late", modified: 300),
            entry("no-modified-uses-added", added: 200),
        ], by: .dateModified)
        XCTAssertEqual(sorted.map(\.name),
                       ["modified-late", "no-modified-uses-added", "modified-early"])
    }

    func testKindSortGroupsDirectoriesFirst() {
        let sorted = FolderContentsLoader.sorted([
            entry("b.png"), entry("zeta", isDirectory: true),
            entry("a.png"), entry("alpha", isDirectory: true),
        ], by: .kind)
        // Folders always come first (by name within the group); files are grouped by kind.
        XCTAssertEqual(sorted.map(\.name), ["alpha", "zeta", "a.png", "b.png"])
    }

    func testKindSortGroupsSameExtensionTogether() {
        let sorted = FolderContentsLoader.sorted([
            entry("1.png"), entry("2.txt"), entry("3.png"), entry("4.txt"),
        ], by: .kind)
        // Do not assert the order of localized kind names, only that equal extensions are adjacent.
        let extensions = sorted.map { $0.url.pathExtension }
        XCTAssertEqual(Set(extensions.prefix(2)).count, 1)
        XCTAssertEqual(Set(extensions.suffix(2)).count, 1)
    }

    func testKindRankOrdersDirectoryThenFileThenNoExtension() {
        XCTAssertEqual(FolderContentsLoader.kindRank(for: entry("dir", isDirectory: true)), 0)
        XCTAssertEqual(FolderContentsLoader.kindRank(for: entry("a.png")), 1)
        XCTAssertEqual(FolderContentsLoader.kindRank(for: entry("README")), 2)
    }

    func testKindSortPutsNoExtensionFilesLast() {
        let sorted = FolderContentsLoader.sorted([
            entry("README"), entry("a.png"), entry("dir", isDirectory: true),
        ], by: .kind)
        XCTAssertEqual(sorted.map(\.name), ["dir", "a.png", "README"])
    }

    func testCoverFileFollowsSortOrderAndSkipsDirectories() {
        let entries = [
            entry("zzz.png", added: 300),
            // Not "aaa": in Norwegian and Danish collation "aa" is "å" and sorts after "z".
            entry("bbb.png", added: 100),
            entry("newest-dir", isDirectory: true, added: 400),
        ]
        XCTAssertEqual(FolderContentsLoader.coverFile(in: entries, order: .dateAdded)?.name, "zzz.png")
        XCTAssertEqual(FolderContentsLoader.coverFile(in: entries, order: .name)?.name, "bbb.png")
    }
}
