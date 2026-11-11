import Foundation

/// Persistence layer for the pinned folder zone: ordered list of folder paths (order is
/// display order; drag reordering and drop-to-pin both edit this array). The app is not
/// sandboxed, so normalized plain paths suffice; no security-scoped bookmark needed.
@MainActor
final class PinnedFolderStore: ObservableObject {
    @Published private(set) var folderPaths: [String] = []
    /// Per-folder sort order (normalized path →
    /// FolderSortOrder.rawValue). Absent = default sort, not persisted.
    @Published private(set) var sortOrders: [String: String] = [:]
    private let key = "pinnedFolderPaths"
    private let sortKey = "pinnedFolderSortOrders"

    init() {
        folderPaths = UserDefaults.standard.stringArray(forKey: key) ?? []
        sortOrders = UserDefaults.standard.dictionary(forKey: sortKey) as? [String: String] ?? [:]
    }

    func contains(_ path: String) -> Bool { folderPaths.contains(Self.normalized(path)) }

    func add(_ path: String) {
        let normalized = Self.normalized(path)
        guard !normalized.isEmpty, !folderPaths.contains(normalized) else { return }
        folderPaths.append(normalized)
        persist()
    }

    /// Drop-to-pin: insert at display index. An already pinned path moves
    /// to the new position (Dock semantics: dropping again reorders).
    func insert(_ path: String, at index: Int) {
        let normalized = Self.normalized(path)
        guard !normalized.isEmpty else { return }
        var next = folderPaths
        var target = min(max(0, index), next.count)
        if let existing = next.firstIndex(of: normalized) {
            next.remove(at: existing)
            if existing < target { target -= 1 }
        }
        next.insert(normalized, at: min(target, next.count))
        guard next != folderPaths else { return }
        folderPaths = next
        persist()
    }

    /// Drag reordering inside the zone: move draggedPath to the left/right
    /// of targetPath (reuses the pure StripOrdering functions).
    func reorder(draggedPath: String, relativeTo targetPath: String, after: Bool) {
        let next = StripOrdering.reordering(folderPaths,
                                            move: Self.normalized(draggedPath),
                                            relativeTo: Self.normalized(targetPath),
                                            after: after)
        guard next != folderPaths else { return }
        folderPaths = next
        persist()
    }

    func remove(_ path: String) {
        let normalized = Self.normalized(path)
        folderPaths.removeAll { $0 == normalized }
        if sortOrders.removeValue(forKey: normalized) != nil {
            UserDefaults.standard.set(sortOrders, forKey: sortKey)
        }
        persist()
    }

    func sortOrder(for path: String) -> FolderSortOrder {
        FolderSortOrder(rawValue: sortOrders[Self.normalized(path)] ?? "") ?? .default
    }

    func setSortOrder(_ order: FolderSortOrder, for path: String) {
        let normalized = Self.normalized(path)
        guard sortOrders[normalized] != order.rawValue else { return }
        sortOrders[normalized] = order.rawValue
        UserDefaults.standard.set(sortOrders, forKey: sortKey)
    }

    private func persist() {
        UserDefaults.standard.set(folderPaths, forKey: key)
    }

    /// Normalize: expand ~, collapse .. and strip the trailing slash, so one folder is pinned only once.
    static func normalized(_ path: String) -> String {
        FilePathNormalization.normalized(path)
    }
}
