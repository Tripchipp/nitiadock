import Foundation

/// One searchable row of the settings window. `title` must equal the row's title exactly: a search
/// result scrolls to and highlights the row with that title.
struct SettingsSearchEntry: Identifiable, Equatable {
    let page: SettingsTab
    let title: String
    /// Extra words people might type for this row (English, lower case).
    let keywords: [String]

    var id: String { "\(page.rawValue)/\(title)" }
}

enum SettingsSearchIndex {
    static var entries: [SettingsSearchEntry] {
        func e(_ page: SettingsTab, _ title: String, _ keywords: String = "") -> SettingsSearchEntry {
            SettingsSearchEntry(page: page, title: title, keywords: keywords.split(separator: " ").map(String.init))
        }
        return [
            e(.general, String(localized: "Open at login"), "startup launch boot login items"),
            e(.general, String(localized: "Taskbar size"), "height big small large icons"),
            e(.general, String(localized: "Hide the taskbar"), "auto hide autohide visible always"),
            e(.general, String(localized: "Show/hide shortcut"), "hotkey keyboard toggle"),
            e(.general, String(localized: "macOS Dock"), "dock hide apple"),
            e(.general, String(localized: "Restore the Dock"), "uninstall remove reset show dock"),
            e(.general, String(localized: "Setup guide"), "welcome onboarding first launch"),

            e(.appearance, String(localized: "Taskbar tint"), "dark light colour color theme mode"),
            e(.appearance, String(localized: "Taskbar opacity"), "transparent glass background"),
            e(.appearance, String(localized: "Distance from the bottom"), "margin gap position edge"),
            e(.appearance, String(localized: "Padding at the ends"), "edge space width"),
            e(.appearance, String(localized: "Dot colour"), "running indicator color"),
            e(.appearance, String(localized: "Dot size"), "running indicator"),
            e(.appearance, String(localized: "Reset appearance"), "default original"),

            e(.windowCards, String(localized: "Card tint"), "dark light colour color"),
            e(.windowCards, String(localized: "Card opacity"), "transparent"),
            e(.windowCards, String(localized: "Corner radius"), "rounded corners"),
            e(.windowCards, String(localized: "Title size"), "font text"),
            e(.windowCards, String(localized: "Maximum card width"), "wide narrow"),
            e(.windowCards, String(localized: "Long titles"), "truncate ellipsis"),
            e(.windowCards, String(localized: "Equal-width cards"), "windows same width"),
            e(.windowCards, String(localized: "Space between items"), "gap spacing"),
            e(.windowCards, String(localized: "Space between an app’s windows"), "gap spacing group"),

            e(.displays, String(localized: "With more than one display"), "monitor screen multiple external"),
            e(.displays, String(localized: "Show the taskbar on"), "pin monitor screen main"),
            e(.displays, String(localized: "Windows only on their own display"), "monitor screen"),

            e(.badges, String(localized: "Also show badges for"), "unread count notifications mail"),

            e(.extras, String(localized: "Shelf"), "files stash drop"),
            e(.extras, String(localized: "Drawer"), "hidden apps rarely"),
            e(.extras, String(localized: "Trash"), "bin delete"),

            e(.mouse, String(localized: "Show app names on hover"), "tooltip label name"),
            e(.mouse, String(localized: "Middle-click for a new window"), "mouse button wheel click"),
            e(.mouse, String(localized: "Haptic feedback"), "force touch vibration"),

            e(.windows, String(localized: "Keep maximized windows above the taskbar"), "zoom fill overlap"),
            e(.windows, String(localized: "Reserve space for the taskbar"), "overlap move resize"),
            e(.windows, String(localized: "Smooth full-screen switching"), "fullscreen flicker flash"),

            e(.privacy, String(localized: "Accessibility"), "permission privacy security"),
            e(.privacy, String(localized: "Finder automation"), "permission apple events"),
            e(.privacy, String(localized: "Check for updates automatically"), "update sparkle version"),
            e(.privacy, String(localized: "Updates"), "update version"),

            e(.about, String(localized: "Check for updates"), "update version new"),
            e(.about, String(localized: "What’s new"), "changelog release notes"),
            e(.about, String(localized: "Send feedback"), "bug report issue contact help"),
            e(.about, String(localized: "Source code"), "github open source"),
            e(.about, String(localized: "License"), "gpl licence"),
        ].filter { entry in
            // Rows that only exist with the updater on (or off).
            let updaterOnly = [String(localized: "Check for updates automatically"), String(localized: "Check for updates")]
            let offlineOnly = [String(localized: "Updates")]
            return !ForkDefaults.updatesEnabled ? !updaterOnly.contains(entry.title) : !offlineOnly.contains(entry.title)
        }
    }

    /// Rows whose title, page or keywords contain every word typed, best match (title prefix) first.
    static func matches(for query: String) -> [SettingsSearchEntry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let hits = entries.filter { entry in
            let haystack = ([entry.title, entry.page.title] + entry.keywords).joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        return hits.sorted { lhs, rhs in
            let l = lhs.title.lowercased().hasPrefix(words[0])
            let r = rhs.title.lowercased().hasPrefix(words[0])
            return l && !r
        }
    }
}
