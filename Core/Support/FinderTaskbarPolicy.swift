import Foundation

/// Finder's membership and permanence policy on the taskbar side (decided
/// 2026-08-20, reversing "Finder is always permanent and has no Keep state").
///
/// Finder now uses the same "Keep in Dock" as ordinary apps: checked (the default) there is always an
/// app-level entry; unchecked, the entry card disappears when all Finder windows are closed and window
/// cards return when a window opens. The drawer is opened up too, **the messaging zone still is not**:
/// an icon there stands for "this app's main window", and Finder has no such main-window semantics.
///
/// The tracking layer (`AppTracker` / `FinderWindowRules`) is unaffected: Finder is always
/// adopted and its entry survives process restarts. "Disappearing" happens only in the projection
/// layer (`DockStripView.makeProjection`), so the card returns instantly when a window opens.
enum FinderTaskbarPolicy {
    /// Finder constant for the Core/App side. The Platform side has its
    /// own `FinderWindowRules.bundleIdentifier`: that one governs window
    /// trackability, which is separate from membership. Do not merge them.
    static let bundleID = "com.apple.finder"

    static func isFinder(_ bundleID: String?) -> Bool {
        bundleID == Self.bundleID
    }

    /// Whether Finder's app-level entry (the card shown with no
    /// windows) is displayed. Decided only by "Keep in Dock".
    ///
    /// Ordinary apps still get a fallback card while running with no windows, but Finder
    /// runs from boot, so without a gate here the checkbox would have no effect on Finder.
    static func showsAppLevelEntry(isKept: Bool) -> Bool {
        isKept
    }

    /// Whether it can be pinned to the messaging zone. Never for Finder.
    static func canMarkMessaging(_ bundleID: String) -> Bool {
        !bundleID.isEmpty && !isFinder(bundleID)
    }
}
