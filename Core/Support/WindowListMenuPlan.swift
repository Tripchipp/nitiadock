import Foundation

/// "Window list" entries at the top of an app-level icon's context menu (like the native Dock: ✓ = frontmost
/// window, ◇ = minimized). Only for entries where "one icon stands for the whole app" (kept / message zone /
/// drawer / the permanent Finder card); a concrete window card is that window itself and lists nothing
/// (2026-08-24).
struct WindowMenuEntry: Equatable {
    enum Marker: Equatable {
        case none
        /// The app's frontmost (active) window: the row the native Dock marks with ✓.
        case front
        /// The whole group is minimized: the row the native Dock marks with ◇. Clicking goes through
        /// activate, which restores it.
        case minimized
    }

    /// Action target handed to `runtime.activate(windowID:)` on click (the group's current representative
    /// member).
    let actionWindowID: String
    let title: String
    let marker: Marker
}

enum WindowListMenuPlan {
    /// Takes all windows of a bundle from the snapshot, in strip order, folded by `groupID` (one row per
    /// native tab group, background tabs not listed separately, consistent with the taskbar's single-seat
    /// model). **Snapshot only, no AX**: the menu is built synchronously at right-click time (menus.md), and
    /// any live inventory would stall that moment.
    static func entries(
        snapshot: DockSnapshot,
        bundleID: String,
        fallbackTitle: String
    ) -> [WindowMenuEntry] {
        var groups: [[WindowRecord]] = []
        var indexByGroup: [String: Int] = [:]
        for id in snapshot.orderedWindowIDs {
            guard let record = snapshot.windows[id],
                  record.bundleIdentifier == bundleID,
                  // app-* fallback seats are not real windows; ones that are closing / already gone are not
                  // listed either.
                  !record.groupID.hasPrefix("app-"),
                  record.status != .closedPending,
                  record.status != .disappeared
            else { continue }
            if let idx = indexByGroup[record.groupID] {
                groups[idx].append(record)
            } else {
                indexByGroup[record.groupID] = groups.count
                groups.append([record])
            }
        }
        return groups.map { members in
            // Representative window follows the same rule as `StripItem.init(members:)`: active ?? first
            // visible member ?? first.
            let representative = members.first { $0.status == .active }
                ?? members.first { $0.status != .minimized && $0.status != .hidden }
                ?? members[0]
            let marker: WindowMenuEntry.Marker
            if representative.status == .active {
                marker = .front
            } else if members.allSatisfy({ $0.status == .minimized }) {
                marker = .minimized
            } else {
                marker = .none
            }
            return WindowMenuEntry(
                actionWindowID: representative.id.rawValue,
                title: WindowDisplayTitle.resolve(
                    rawTitle: representative.title,
                    fallbackName: fallbackTitle
                ),
                marker: marker
            )
        }
    }
}
