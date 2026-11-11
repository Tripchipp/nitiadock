import Foundation

/// fork: with several displays, an app's windows are cards only on the bar of the display they are on;
/// on the other bars the app is a single icon (`AppSettingsStore.collapseForeignWindows`).
///
/// Pure decision over the strip's live entries, in order. The caller maps each entry to an `Item`
/// and applies the outcomes: `keep` the entry, `drop` it, or swap it for the app's icon.
enum ForkForeignWindowCollapse {
    struct Item: Equatable {
        /// nil / empty for entries that are not apps (folders, the shelf, dividers).
        let bundleID: String?
        let displayUUID: String?
        /// A real window card. App-level (windowless) cards and launcher chips are never collapsed.
        let isRealWindow: Bool
        /// Apps the collapse must leave alone (the messaging zone's apps keep their pop-out cards).
        let isExempt: Bool
    }

    enum Outcome: Equatable {
        case keep
        case drop
        /// Replace this entry with the app's icon (one per app, in the place of its first foreign window).
        case icon
    }

    /// - Parameter isLocal: whether a window on `displayUUID` belongs to this bar's display. The caller
    ///   passes `StripDisplayFilter.shows(.window(displayUUID:))`, which sends an unknown or
    ///   disconnected display to the primary one.
    static func outcomes(for items: [Item], isLocal: (String?) -> Bool) -> [Outcome] {
        func isCollapsible(_ item: Item) -> Bool {
            item.isRealWindow && !item.isExempt && !(item.bundleID ?? "").isEmpty
        }
        var hasLocalWindow: Set<String> = []
        for item in items where isCollapsible(item) && isLocal(item.displayUUID) {
            hasLocalWindow.insert(item.bundleID ?? "")
        }
        var iconPlaced: Set<String> = []
        return items.map { item in
            guard isCollapsible(item), let bundleID = item.bundleID else { return .keep }
            if isLocal(item.displayUUID) { return .keep }
            if hasLocalWindow.contains(bundleID) { return .drop }
            return iconPlaced.insert(bundleID).inserted ? .icon : .drop
        }
    }
}
