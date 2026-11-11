import Foundation

/// Which window the messaging zone icon stands for: **pure
/// decision** (2026-08-23). Three rules, strongest first:
///
/// 1. Window title == app name -> main window. Feishu / QQ / aliased WeChat take this rule,
///    unchanged. **When several are titled with the app name**, prefer a non-minimized one,
///    then the largest area (measured 2026-08-23: on cold launch WeChat first shows a 700×640
///    login window also titled with the app name; after login it is ordered out but still
///    present in CG, so its seat is kept; taking the first by creation order would bind the
///    icon to this invisible window, the "icon can only activate, never minimize" bug).
/// 2. After removing the ones the exclusion table marks as "definitely not the main window", **exactly
///    one is left** -> that is the main window. Telegram and manually pinned Slack, single-window
///    apps, take this rule: nearly all non-Chinese messaging apps are single-window, and their titles
///    hold a conversation name / unread count / system number, so rule 1 can never pass.
/// 3. Neither holds -> `nil`. The caller degrades to a **toggle for the whole app**
///    (the no-main-window branch of `.messagingApp` in `DockStripView`), so the icon
///    always responds, only standalone chat windows are minimized along with it.
///
/// Rule 2 lifts the 2026-07-21 ban (back then, with WeChat's main window closed only "Notes" was left;
/// once that was adopted as the main window, the main window could never be brought back). **The
/// exclusion table is the precondition for lifting it**: with Notes excluded WeChat is back to "no main
/// window" and clicking the icon still brings back the main window. Discipline for the exclusion table:
/// - **Only exclusions, never designations** ("X is not the main window", not "the main window
///   is called X"): a wrong designation binds the icon to the wrong window, which the user
///   cannot make sense of at all; a wrong exclusion at worst falls back to the generic rules.
/// - **Add an entry only when a wrong binding was measured on
///   this machine**; do not guess for apps never installed.
/// - The Chinese in the table is window-title data, not copy, and is not localized (project rule).
enum MessagingMainWindowDecision {
    struct WindowFact: Equatable {
        let id: String
        let title: String
        /// A minimized window is not preferred as the main window (only matters when several share the name).
        let isMinimized: Bool
        /// Window area (pt²); with several sharing the name,
        /// larger looks more like the main window. 0 when unknown.
        let area: CGFloat

        init(id: String, title: String, isMinimized: Bool = false, area: CGFloat = 0) {
            self.id = id
            self.title = title
            self.isMinimized = isMinimized
            self.area = area
        }
    }

    /// Titles that are definitely not the main window (compared after normalization).
    /// WeChat "Notes" = the window wrongly bound in the 2026-07-21 measurement.
    static let excludedTitlesByBundleID: [String: Set<String>] = [
        "com.tencent.xinWeChat": ["笔记"],
    ]

    /// - Parameters:
    ///   - windows: The app's **real** windows (without the app-level fallback item), in any order.
    ///   - titleMatchesAppName: Criterion for rule 1, injected as
    ///     a closure to keep `AppNameRegistry` on the caller side.
    /// - Returns: The main window's id; `nil` = not recognized, the caller takes the app-level toggle.
    static func mainWindowID(
        bundleID: String,
        windows: [WindowFact],
        titleMatchesAppName: (String) -> Bool
    ) -> String? {
        let titled = windows.filter { titleMatchesAppName($0.title) }
        if let best = titled.max(by: { lhs, rhs in
            // "lhs < rhs" for max(by:): compare "not minimized" first,
            // then area; when all equal, keep the first one seen (stable).
            if lhs.isMinimized != rhs.isMinimized { return lhs.isMinimized }
            return lhs.area < rhs.area
        }) {
            return best.id
        }
        let excluded = excludedTitlesByBundleID[bundleID] ?? []
        let candidates = windows.filter { !excluded.contains(normalize($0.title)) }
        return candidates.count == 1 ? candidates[0].id : nil
    }

    static func normalize(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
