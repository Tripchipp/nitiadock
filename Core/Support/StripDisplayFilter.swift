import Foundation

/// Whether one taskbar should draw an entry under multi-screen mode ④. Used **only after the
/// shared ordering layer** (after `orderedLive` in `DockStripView.makeProjection`): the id sets
/// fed to `StripOrderStore.reconciled / sync / reorder` must be identical on every screen,
/// otherwise the screens mark each other's cards as "absent" and evict them from memory after 5s.
///
/// - `scope == nil`: no filtering (①②③, or non-pinned units under ④).
/// - `.launcher` (kept placeholders that are not running, messaging zone, folders,
///   shelf) is always shown: these are not windows and have no running dot.
/// - `.runningWithoutWindow` (app-level fallback cards, kept apps that are running with only a placeholder
///   left) is on one bar only: the screen its window was last on (`AppEntry.lastWindowDisplayUUID`, also
///   updated when dragged to another bar), or the main screen (menu bar screen) when unreadable.
///   **Has a running dot = on one bar only** (2026-09-02: after
///   closing all Chrome windows it appeared on both bars).
/// - `.window`: ownership key is nil (position unreadable from the list) or points
///   to a screen no longer present -> main screen only; otherwise key == scope.
struct StripDisplayFilter: Equatable {
    enum Subject: Equatable {
        case launcher
        case runningWithoutWindow(displayUUID: String?)
        case window(displayUUID: String?)
    }

    let scope: String?
    let connectedUUIDs: Set<String>
    let primaryUUID: String?

    static let unfiltered = StripDisplayFilter(scope: nil, connectedUUIDs: [], primaryUUID: nil)

    func shows(_ subject: Subject) -> Bool {
        guard let scope else { return true }
        switch subject {
        case .launcher:
            return true
        case .runningWithoutWindow(let key), .window(let key):
            guard let key, connectedUUIDs.contains(key) else { return scope == primaryUUID }
            return key == scope
        }
    }
}
