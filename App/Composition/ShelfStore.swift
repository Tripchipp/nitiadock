import Foundation

/// Persistence layer for the shelf (temporary file staging): a list of paths, **references only, nothing is
/// moved**. Files stay where they are, and on drag-out the destination copies/moves by system semantics.
/// New stashes go to the head (newest first); v1 stores plain paths, not bookmarks, so an entry becomes
/// invalid once the file is moved/deleted and is removed by `prune()` (called when the popup opens).
/// List operations are pure static functions (stashing/pruned), covered by unit tests.
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var itemPaths: [String] = []
    private let key = "shelfItemPaths"

    init() {
        itemPaths = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func stash(paths: [String]) {
        let next = Self.stashing(itemPaths, adding: paths.map(Self.normalized))
        guard next != itemPaths else { return }
        itemPaths = next
        persist()
    }

    func remove(_ path: String) {
        let normalized = Self.normalized(path)
        guard itemPaths.contains(normalized) else { return }
        itemPaths.removeAll { $0 == normalized }
        persist()
    }

    func clear() {
        guard !itemPaths.isEmpty else { return }
        itemPaths = []
        persist()
    }

    /// Removes paths that no longer exist (called when the
    /// shelf popup opens). Returns whether anything changed.
    /// Only a definitely missing path is dropped: an unreadable one (e.g. a Desktop file while the
    /// Desktop permission is not granted) is still the user's file.
    @discardableResult
    func prune() -> Bool {
        let kept = Self.pruned(itemPaths) { FileReachability.of(path: $0) != .missing }
        guard kept != itemPaths else { return false }
        itemPaths = kept
        persist()
        return true
    }

    private func persist() {
        UserDefaults.standard.set(itemPaths, forKey: key)
    }

    // MARK: - Pure logic (unit-tested)

    /// Normalize: expand ~, collapse .. and strip the trailing slash (same
    /// rule as PinnedFolderStore, implemented in `FilePathNormalization`).
    nonisolated static func normalized(_ path: String) -> String {
        FilePathNormalization.normalized(path)
    }

    /// Stash merge: new entries (deduped, empties removed) go to the head; entries
    /// already in the list move to the head (stashing again = bring to front).
    nonisolated static func stashing(_ current: [String], adding: [String]) -> [String] {
        var seen = Set<String>()
        let incoming = adding.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !incoming.isEmpty else { return current }
        return incoming + current.filter { !seen.contains($0) }
    }

    /// Removes paths that do not exist (exists is injected, so tests never touch the real file system).
    nonisolated static func pruned(_ paths: [String], exists: (String) -> Bool) -> [String] {
        paths.filter(exists)
    }
}
