import Foundation

/// The **pure decision layer** of the launcher icon (LauncherChip) context menu: given
/// "running state of the display zone + whether there are membership items", produces
/// the kinds of menu items to show (order is render order). Extracted as pure logic
/// for unit testing; the side effect of building the NSMenu stays in LauncherChip.
///
/// Key point: `isRunning` is the **display state of the zone the icon is in**
/// (`LauncherChip.isRunning`, assigned per zone), **not** the process liveness from
/// `NSWorkspace`. In the not-running zone the process may still be alive (closing windows
/// does not quit / resident apps), but it is shown as "not running" and the menu must treat
/// it as not running too, otherwise "Hide / Quit" would appear and contradict the appearance.

enum LauncherMenuItemKind: Equatable {
    /// "Open": appears only when not running, strictly before recent files
    /// and membership items. In the running state Show/Hide/Quit replace it.
    case open
    /// Dock-style window list (✓ frontmost / ◇ minimized):
    /// placed first when running with real windows (2026-08-24).
    /// Belongs only to app-level icons; specific window cards do not go through this plan.
    case windowList
    case recentDocuments
    case show
    case hide
    /// Quit (including its Option alternate, Force Quit): **always
    /// the last item**, membership items always come before it.
    case quit
    /// Membership / management section (the checkable Keep in Dock / Pin
    /// to Messaging Zone; one or several items, decided by the caller).
    case membership
}

enum LauncherMenuPlan {
    /// - Parameters:
    ///   - isRunning: **Display state** of the zone the icon is in (not process liveness).
    ///   - isHidden: Whether the app is hidden in the display state (decides "Show" vs "Hide").
    ///   - hasWindows: Whether the app has real windows in the
    ///     snapshot (decides whether to show the window list).
    ///   - hasMembership: Whether there are membership/management items.
    static func itemKinds(isRunning: Bool,
                          isHidden: Bool,
                          hasWindows: Bool,
                          hasMembership: Bool) -> [LauncherMenuItemKind] {
        // Order (2026-08-24): window list -> recent
        // files -> action items -> membership items -> Quit.
        // Quit must always be last: membership items after Quit would
        // push "Quit" to third from last, against user expectations.
        var kinds: [LauncherMenuItemKind] = []
        if !isRunning { kinds.append(.open) }
        if isRunning && hasWindows { kinds.append(.windowList) }
        if isRunning || hasMembership { kinds.append(.recentDocuments) }
        if isRunning { kinds.append(isHidden ? .show : .hide) }
        if hasMembership { kinds.append(.membership) }
        if isRunning { kinds.append(.quit) }
        return kinds
    }
}
