import AppKit
import CoreServices

/// "Launch at login" on macOS 12: `SMAppService` needs 13+, so 12 uses the old
/// login items list (`LSSharedFileList*`, the same table as "System Preferences
/// → Users & Groups → Login Items"; the user can see it and remove entries).
///
/// **The deprecation warnings here are expected; do not change the code to silence them.** Apple
/// deprecated this API set in 10.11, but macOS 12 no longer gets updates, the API will not change, and
/// this path is selected only on 12 (`LaunchAtLoginService.systemBackend()`). Delete the whole file
/// when the minimum deployment target moves to 13.
///
/// `LoginItemListing` sits between the backend and `SharedFileListLoginItems`, which actually
/// touches CoreServices; unit tests replace it with an in-memory list (`LaunchAtLoginServiceTests`).
protocol LoginItemListing: Sendable {
    /// Returns nil when the list cannot be opened, as distinct from "the list is empty".
    func itemURLs() -> [URL]?
    func insert(_ url: URL) throws
    /// Removes **all** entries in the list that resolve to this URL.
    func remove(_ url: URL) throws
}

struct LegacyLoginItemBackend: LaunchAtLoginBackend {
    let list: any LoginItemListing
    let bundleURL: URL

    func readState() -> LaunchAtLoginState {
        guard let urls = list.itemURLs() else { return .unsupported }
        return urls.contains { LoginItemURLMatcher.matches($0, bundleURL) } ? .on : .off
    }

    func setEnabled(_ enabled: Bool) throws {
        guard let urls = list.itemURLs() else { throw LaunchAtLoginError.unsupported }
        let matches = urls.filter { LoginItemURLMatcher.matches($0, bundleURL) }
        if enabled {
            // Already in the list: do not insert again. The old API does not
            // dedupe, and duplicates show as two rows in System Preferences.
            guard matches.isEmpty else { return }
            try list.insert(bundleURL)
        } else {
            for url in matches {
                try list.remove(url)
            }
        }
    }

    /// The old list has no "pending approval" step, so the menu's "Open Login Items Settings…" never
    /// appears on 12; kept for protocol completeness. On 12 login items live under "Users & Groups".
    func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preferences.users") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// URLs stored in the list are inconsistent about a trailing slash and
/// about going through the `/private` symlink; normalize before comparing.
enum LoginItemURLMatcher {
    static func matches(_ lhs: URL, _ rhs: URL) -> Bool {
        normalizedPath(lhs) == normalizedPath(rhs)
    }

    static func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}

/// The only place that touches `LSSharedFileList*`.
struct SharedFileListLoginItems: LoginItemListing {
    func itemURLs() -> [URL]? {
        guard let list = openList() else { return nil }
        return entries(in: list).map(\.url)
    }

    func insert(_ url: URL) throws {
        guard let list = openList() else { throw LaunchAtLoginError.unsupported }
        // The return value is CF_RETURNS_RETAINED; Swift gets the
        // object directly, do not call takeRetainedValue() again.
        let inserted = LSSharedFileListInsertItemURL(
            list,
            kLSSharedFileListItemLast.takeUnretainedValue(),
            nil,
            nil,
            url as CFURL,
            nil,
            nil
        )
        guard inserted != nil else { throw LaunchAtLoginError.writeFailed }
    }

    func remove(_ url: URL) throws {
        guard let list = openList() else { throw LaunchAtLoginError.unsupported }
        for entry in entries(in: list) where LoginItemURLMatcher.matches(entry.url, url) {
            guard LSSharedFileListItemRemove(list, entry.item) == noErr else {
                throw LaunchAtLoginError.writeFailed
            }
        }
    }

    private func openList() -> LSSharedFileList? {
        LSSharedFileListCreate(nil, kLSSharedFileListSessionLoginItems.takeUnretainedValue(), nil)?
            .takeRetainedValue()
    }

    private func entries(in list: LSSharedFileList) -> [(item: LSSharedFileListItem, url: URL)] {
        var seed: UInt32 = 0
        let items = LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue() as? [LSSharedFileListItem] ?? []
        // Do not show UI or mount volumes when resolving entries: this runs on a background
        // queue, and the list may hold other login items pointing at external disks.
        let flags = UInt32(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)
        return items.compactMap { item in
            guard let url = LSSharedFileListItemCopyResolvedURL(item, flags, nil)?.takeRetainedValue() as URL? else {
                return nil
            }
            return (item, url)
        }
    }
}
