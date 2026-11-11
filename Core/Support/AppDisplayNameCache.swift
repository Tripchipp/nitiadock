import Foundation

final class AppDisplayNameCache {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func value(for bundleID: String, loader: () -> String?) -> String {
        lock.lock()
        let cached = values[bundleID]
        lock.unlock()
        if let cached { return cached }

        guard let resolved = loader(), !resolved.isEmpty, resolved != bundleID else {
            return bundleID
        }
        lock.lock()
        values[bundleID] = resolved
        lock.unlock()
        return resolved
    }

    func invalidate(bundleID: String) {
        lock.lock()
        values.removeValue(forKey: bundleID)
        lock.unlock()
    }
}

/// All known spellings of an app's name, stored as a set after normalization (trim + lowercase).
///
/// **Why it exists**: the messaging zone absorbs by "window title == app name", and the app name used to be
/// looked up live every frame via
/// `NSRunningApplication.runningApplications(withBundleIdentifier:).first?.localizedName`.
/// That is a LaunchServices call, which can **transiently return empty** for a live process (same cause as
/// the `ProcessLiveness` hard constraint). One hiccup -> the main window is not absorbed that frame -> the
/// app renders one card in the messaging zone and one in the live zone -> the row widens and pushes the right
/// side away, and the mismatch sticks until the next unrelated reorder (measured sticking from 2 seconds to
/// 79 minutes).
///
/// Measured 2026-08-11: on this machine `Bundle.localizedInfoDictionary` resolves to English for
/// Feishu/WeChat (`{feishu, lark}` / `{wechat}`); their Chinese window titles are not among the
/// bundle-derived names at all, so these two apps can **only** rely on that live lookup. That is why they
/// mismatch as a pair while QQ (which has `qq` in its bundle) never does.
///
/// **Fix**: the name set only grows: bundle-derived names ∪ every `localizedName` ever observed successfully.
/// After one successful observation no later hiccup affects the decision; before that every query retries, so
/// "the first frame of a cold launch happens to hiccup" does not pin an incomplete set as a complete cache
/// forever (which would be worse than before).
///
/// Side effect: less I/O. After a successful observation there are zero LaunchServices calls per frame (it
/// used to be one per frame per messaging app, and inside the evaluation of `DockStripView.body`).
final class AppNameRegistry {
    /// Bundle-derived names (reads Info.plist, once). Returns a normalized set.
    private let bundleNamesLoader: (String) -> Set<String>
    /// `localizedName` of the running instance; nil when the process is not running or LaunchServices
    /// hiccups.
    private let runningNameLoader: (String) -> String?

    private struct Entry {
        var names: Set<String>
        /// Whether the running name has been observed successfully. While false every query retries.
        var sawRunningName: Bool
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    /// Product aliases, **added only when measured, never guessed** (2026-08-23): another brand name the same
    /// app gives its main window under some UI language, absent from Info.plist and not the running name
    /// either. With an English UI (mainland account) WeChat's main window is titled `Weixin`, while on an
    /// English system the app is called `WeChat`, and neither equals the Chinese name. Users on an English
    /// system with a mainland account (overseas Chinese) therefore could not get into the messaging zone, or
    /// got in without the main window being recognized. Normalized (lowercase).
    static let productAliases: [String: Set<String>] = [
        "com.tencent.xinWeChat": ["weixin"],
    ]

    init(bundleNamesLoader: @escaping (String) -> Set<String>,
         runningNameLoader: @escaping (String) -> String?) {
        self.bundleNamesLoader = bundleNamesLoader
        self.runningNameLoader = runningNameLoader
    }

    /// Normalization: trim leading and trailing whitespace + lowercase. An empty string means "not a name",
    /// and callers treat it as no match.
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The full set of known names. Retries `runningNameLoader` until a running name has been observed.
    func knownNames(for bundleID: String) -> Set<String> {
        lock.lock()
        let cached = entries[bundleID]
        lock.unlock()

        // Disk reads happen outside the lock. Read only when the entry is missing, then cached for good.
        var entry = cached ?? Entry(names: baseNames(for: bundleID), sawRunningName: false)

        // No running name seen yet -> try again. Once seen, never queried again, so a hiccup cannot affect
        // the remembered names.
        if !entry.sawRunningName {
            let normalized = runningNameLoader(bundleID).map(Self.normalize)
            if let normalized, !normalized.isEmpty {
                entry.names.insert(normalized)
                entry.sawRunningName = true
            }
        }

        return commit(entry, for: bundleID)
    }

    /// Under concurrency two threads may each compute an entry; **merge instead of overwrite**, so the later
    /// write does not erase the earlier one's observation (the set only grows, so merging is always safe).
    /// Returns the merged name set.
    @discardableResult
    private func commit(_ entry: Entry, for bundleID: String) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        var merged = entry
        if let existing = entries[bundleID] {
            merged.names.formUnion(existing.names)
            merged.sawRunningName = merged.sawRunningName || existing.sawRunningName
        }
        entries[bundleID] = merged
        return merged.names
    }

    /// A name supplied directly from outside (e.g. the ready-made `NSRunningApplication` in an `NSWorkspace`
    /// launch notification), saving one lookup. Also only grows.
    func observe(name raw: String, for bundleID: String) {
        let normalized = Self.normalize(raw)
        guard !normalized.isEmpty else { return }

        lock.lock()
        let existing = entries[bundleID]
        lock.unlock()

        // The first time this bundle is seen, the bundle names must be included too: `knownNames` reads the
        // disk only when the entry is missing, so if only the running name were inserted here, the bundle
        // names could never be filled in. Disk reads happen outside the lock.
        var names = existing?.names ?? baseNames(for: bundleID)
        names.insert(normalized)
        commit(Entry(names: names, sawRunningName: true), for: bundleID)
    }

    /// Bundle-derived names ∪ product aliases: the starting point when an entry is first created; both
    /// entry-creating paths must go through here.
    private func baseNames(for bundleID: String) -> Set<String> {
        bundleNamesLoader(bundleID).union(Self.productAliases[bundleID] ?? [])
    }

    func matches(title: String, bundleID: String) -> Bool {
        let normalized = Self.normalize(title)
        guard !normalized.isEmpty else { return false }
        return knownNames(for: bundleID).contains(normalized)
    }

    func invalidate(bundleID: String) {
        lock.lock()
        entries.removeValue(forKey: bundleID)
        lock.unlock()
    }
}
