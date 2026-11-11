import Foundation

/// Usage count for one file. `count` only accumulates from when
/// the feature shipped (macOS keeps no history of open counts).
struct DocumentUsageRecord: Equatable, Codable {
    var count: Int
    var lastOpened: Date
}

/// Count ledger for one app. `lastTop` = top of the system recent list at the last sample (used to tell
/// whether something new was opened), `touchedAt` = last change to this ledger (for bundle-level eviction).
struct BundleDocumentUsage: Equatable, Codable {
    var files: [String: DocumentUsageRecord] = [:]
    var lastTop: String?
    var touchedAt: Date = .distantPast
}

/// Pure logic for "most used files": ranking, counting, eviction. Side
/// effects (disk, subscriptions, menus) live in `DocumentUsageStore`.
enum DocumentUsageRanking {
    static let fileCap = 200
    static let bundleCap = 40

    /// Ranking: count descending, then lastOpened descending, then system recent order. Files that
    /// only appear in the recent list and were never counted rank as 0, after all counted ones, so
    /// right after upgrading the menu matches the old "Recents" and gets more accurate with use.
    /// Candidates = system recent list ∪ counted files (deduplicated by path).
    static func ranked(
        counts: [String: DocumentUsageRecord],
        recentPaths: [String],
        limit: Int = 10
    ) -> [String] {
        var recentOrder: [String: Int] = [:]
        for (index, path) in recentPaths.enumerated() where recentOrder[path] == nil {
            recentOrder[path] = index
        }
        var candidates = Set(recentPaths)
        candidates.formUnion(counts.keys)
        let sorted = candidates.sorted { a, b in
            let na = counts[a]?.count ?? 0
            let nb = counts[b]?.count ?? 0
            if na != nb { return na > nb }
            let da = counts[a]?.lastOpened ?? .distantPast
            let db = counts[b]?.lastOpened ?? .distantPast
            if da != db { return da > db }
            let oa = recentOrder[a] ?? Int.max
            let ob = recentOrder[b] ?? Int.max
            if oa != ob { return oa < ob }
            return a < b
        }
        return Array(sorted.prefix(limit))
    }

    /// +1 for a file. Over `cap`, evicts the one with the lowest count,
    /// least recently opened among those (never the one just incremented).
    static func bumped(
        _ files: [String: DocumentUsageRecord],
        path: String,
        at date: Date,
        cap: Int = fileCap
    ) -> [String: DocumentUsageRecord] {
        var files = files
        var record = files[path] ?? DocumentUsageRecord(count: 0, lastOpened: date)
        record.count += 1
        record.lastOpened = date
        files[path] = record
        while files.count > cap {
            let victim = files.min { a, b in
                if a.value.count != b.value.count { return a.value.count < b.value.count }
                if a.value.lastOpened != b.value.lastOpened { return a.value.lastOpened < b.value.lastOpened }
                return a.key < b.key
            }?.key
            guard let victim, victim != path else { break }
            files.removeValue(forKey: victim)
        }
        return files
    }

    /// Only a change of the top entry counts as an open. The first sample (previous
    /// == nil) only sets the baseline without counting (it may be a stale top
    /// entry, not a fresh open); a cleared list (new == nil) does not count either.
    static func shouldCountTopChange(previousTop: String?, newTop: String?) -> Bool {
        guard let previousTop, let newTop else { return false }
        return previousTop != newTop
    }

    /// Bundle-level eviction: keep only the `maxBundles` most recently touched ledgers.
    static func prunedBundles(
        _ store: [String: BundleDocumentUsage],
        maxBundles: Int = bundleCap
    ) -> [String: BundleDocumentUsage] {
        guard store.count > maxBundles else { return store }
        let kept = store.sorted { $0.value.touchedAt > $1.value.touchedAt }.prefix(maxBundles)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }
}
