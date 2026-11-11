import Foundation
import UniformTypeIdentifiers

/// Sort order for the pinned folder popover/cover (matches the "Sort By" of native Stacks). rawValue is
/// persisted (`PinnedFolderStore.sortOrders`, path -> rawValue). Declaration order is the menu order.
enum FolderSortOrder: String, CaseIterable {
    case name
    case dateAdded      // default: date added, newest first (same as the only sort convention of older versions)
    case dateModified   // date modified, newest first
    case kind

    static let `default`: FolderSortOrder = .dateAdded

    var menuTitle: String {
        switch self {
        case .name: return String(localized: "Name")
        case .dateAdded: return String(localized: "Date Added")
        case .dateModified: return String(localized: "Date Modified")
        case .kind: return String(localized: "Kind")
        }
    }
}

/// Whether a stored path is still there, told apart from "there but not readable": only `ENOENT` /
/// `ENOTDIR` mean gone. Anything else (`EPERM` from a privacy-protected folder such as the Desktop,
/// `EACCES`, I/O errors) must never delete a shelf reference.
enum FileReachability: Equatable {
    case exists, missing, inaccessible

    static func of(path: String) -> FileReachability {
        var info = stat()
        let result = lstat(path, &info)
        return classify(result: result, errorNumber: result == 0 ? 0 : errno)
    }

    static func classify(result: Int32, errorNumber: Int32) -> FileReachability {
        if result == 0 { return .exists }
        return errorNumber == ENOENT || errorNumber == ENOTDIR ? .missing : .inaccessible
    }
}

/// Reads and sorts pinned folder / Trash contents. `load` hits
/// the file system (callers run it on a background queue);
/// sorting and cover selection are pure functions and unit tested. Enumeration always skips hidden files.
enum FolderContentsLoader {
    struct Entry: Equatable {
        var url: URL
        var name: String
        var isDirectory: Bool
        var dateAdded: Date?
        var dateModified: Date?
        /// false = the path exists but this process may not read it (privacy permission).
        var isAccessible = true
    }

    static func load(directory: URL) throws -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .addedToDirectoryDateKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Entry(
                url: url,
                name: FileManager.default.displayName(atPath: url.path),
                // A package (.app, .rtfd, .photoslibrary) is one item to the user: it opens, it is
                // not browsed, and its insides are never offered for trashing.
                isDirectory: (values?.isDirectory ?? false) && !(values?.isPackage ?? false),
                dateAdded: values?.addedToDirectoryDate,
                dateModified: values?.contentModificationDate
            )
        }
    }

    /// Date added descending (newest first); dateAdded can be nil on
    /// network volumes and the like, so modification date is the fallback;
    /// ties are then broken by localized file name ascending to keep the sort stable.
    static func sortedByDateAdded(_ entries: [Entry]) -> [Entry] {
        entries.sorted { a, b in
            let da = a.dateAdded ?? a.dateModified ?? .distantPast
            let db = b.dateAdded ?? b.dateModified ?? .distantPast
            if da != db { return da > db }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Sorts by the user's chosen order (shared by the popover grid and the
    /// cover). All stable: the last level breaks ties by localized file name.
    static func sorted(_ entries: [Entry], by order: FolderSortOrder) -> [Entry] {
        switch order {
        case .dateAdded:
            return sortedByDateAdded(entries)
        case .name:
            return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .dateModified:
            return entries.sorted { a, b in
                let da = a.dateModified ?? a.dateAdded ?? .distantPast
                let db = b.dateModified ?? b.dateAdded ?? .distantPast
                if da != db { return da > db }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        case .kind:
            // Two explicit levels: group number -> kind name within the group -> file name. No sentinel
            // character concatenated into the string: localizedStandardCompare ignores control characters,
            // so a "\0" prefix cannot guarantee folders always come first (caught by a unit test).
            return entries.sorted { a, b in
                let ra = kindRank(for: a), rb = kindRank(for: b)
                if ra != rb { return ra < rb }
                let ka = kindName(for: a), kb = kindName(for: b)
                if ka != kb { return ka.localizedStandardCompare(kb) == .orderedAscending }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    /// Groups for the kind sort: folders (0) -> files with an
    /// extension (1) -> files without an extension (2, last).
    static func kindRank(for entry: Entry) -> Int {
        if entry.isDirectory { return 0 }
        return entry.url.pathExtension.isEmpty ? 2 : 1
    }

    /// Kind group name: files are grouped by the localized UTType description
    /// (falling back to the extension). Folders/extensionless files return an
    /// empty string (each is its own group, already decided by kindRank).
    static func kindName(for entry: Entry) -> String {
        guard !entry.isDirectory else { return "" }
        let ext = entry.url.pathExtension.lowercased()
        guard !ext.isEmpty else { return "" }
        if let type = UTType(filenameExtension: ext), let desc = type.localizedDescription {
            return desc
        }
        return ext
    }

    /// For the cover: the first **file** under the current sort (subfolders are not
    /// used as covers). With the default sort this is the old "newest file" convention.
    static func coverFile(in entries: [Entry], order: FolderSortOrder = .default) -> Entry? {
        sorted(entries, by: order).first { !$0.isDirectory }
    }

    /// Old convention kept (used by unit tests): the newest file.
    static func newestFile(in entries: [Entry]) -> Entry? {
        coverFile(in: entries, order: .dateAdded)
    }

    /// Shelf: builds entries from the given path list (keeping the
    /// passed order = staging order), skipping ones known not to exist.
    /// Unreadable paths stay as `isAccessible == false` entries: without the folder's privacy
    /// permission an existing file looks the same as a deleted one to `fileExists`.
    static func entries(forPaths paths: [String]) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .addedToDirectoryDateKey, .contentModificationDateKey]
        return paths.compactMap { path in
            let reachability = FileReachability.of(path: path)
            guard reachability != .missing else { return nil }
            let url = URL(fileURLWithPath: path)
            guard reachability == .exists else {
                return Entry(url: url, name: url.lastPathComponent, isDirectory: false,
                             dateAdded: nil, dateModified: nil, isAccessible: false)
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Entry(
                url: url,
                name: FileManager.default.displayName(atPath: path),
                // A package (.app, .rtfd, .photoslibrary) is one item to the user: it opens, it is
                // not browsed, and its insides are never offered for trashing.
                isDirectory: (values?.isDirectory ?? false) && !(values?.isPackage ?? false),
                dateAdded: values?.addedToDirectoryDate,
                dateModified: values?.contentModificationDate
            )
        }
    }

    /// Popover "load first, then show" (root-cause fix for the piecemeal look): background enumeration +
    /// sort, waiting at most `timeout` (a local folder usually takes <20ms). Returns nil on timeout or read
    /// failure (rare cases such as network volumes), and the caller takes the original async backfill path.
    /// After a timeout the background block runs to completion and is released; its result is no longer read.
    static func preload(url: URL, timeout: TimeInterval, order: FolderSortOrder = .default) -> [Entry]? {
        final class Box { var entries: [Entry]? }
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box()
        DispatchQueue.global(qos: .userInteractive).async {
            box.entries = (try? load(directory: url)).map { sorted($0, by: order) }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.entries
    }
}
