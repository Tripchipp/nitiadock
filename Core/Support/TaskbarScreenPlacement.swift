import Foundation

/// Taskbar screen placement mode (four multi-display levels: ② shipped 2026-08-26, ③④ started 2026-09-02).
/// rawValue is the persisted UserDefaults value. An old version that reads an unknown rawValue runs as
/// followMouse and **does not rewrite the key** (`AppSettingsStore`), so new modes are only added, never
/// renamed.
/// **Unrelated to the deleted old `com.tungsten.edge.displayMode` key**: that key is orphaned and never read
/// again.
enum TaskbarScreenMode: String {
    case followMouse
    case pinned
    /// ③ Shown on all displays, same content.
    case allScreens
    /// ④ Shown on all displays, each showing only its own windows.
    case allScreensPerDisplay
}

/// Persisted identity of the pinned display. `uuid` comes from `CGDisplayCreateUUIDFromDisplayID` (EDID
/// based, stable across replug / port change / sleep and wake); `name` is a snapshot of `localizedName` at
/// selection time, **for display in settings only** (the Picker can still show "XX (Not Connected)" after the
/// display is unplugged) and never used for matching.
struct PinnedScreenSelection: Equatable {
    let uuid: String
    let name: String
}

/// Where the taskbar is shown. Default `.followMouse` = existing behavior (dwell at the bottom edge to switch
/// display).
enum TaskbarScreenPlacement: Equatable {
    case followMouse
    case pinned(PinnedScreenSelection)
    case allScreens
    case allScreensPerDisplay

    /// Hover display switching (bottom-edge dwell moves the dock) only applies in follow-mouse mode: when
    /// every display has a bar there is nothing to move.
    var allowsHoverScreenSwitching: Bool {
        self == .followMouse
    }

    /// ③④: one taskbar unit per connected display.
    var showsOnEveryDisplay: Bool {
        switch self {
        case .allScreens, .allScreensPerDisplay: return true
        case .followMouse, .pinned: return false
        }
    }

    var mode: TaskbarScreenMode {
        switch self {
        case .followMouse: return .followMouse
        case .pinned: return .pinned
        case .allScreens: return .allScreens
        case .allScreensPerDisplay: return .allScreensPerDisplay
        }
    }

    var pinnedSelection: PinnedScreenSelection? {
        switch self {
        case .pinned(let selection): return selection
        case .followMouse, .allScreens, .allScreensPerDisplay: return nil
        }
    }
}

/// Placement of a single taskbar unit (one `PanelCoordinator`). Under ①② the only unit, `.followSettings`,
/// reads the settings and decides itself; under ③④ the orchestration layer creates one `.fixed` unit per
/// display. Its behavior **is** the fixed mode (no display switching, wakes only at its own bottom edge,
/// falls back to the main display while its own is absent), except that the display is assigned by the
/// orchestration layer instead of by settings.
enum TaskbarUnitPlacement: Equatable {
    case followSettings
    case fixed(displayUUID: String)
}

/// Pure resolution of the pinned display against the current screen set. No extra runtime state: on every
/// screen parameter / settings change it is re-resolved idempotently, and the bar moves back by itself once
/// the display returns.
enum TaskbarScreenResolution {
    enum Outcome: Equatable {
        /// The pinned display is present, at this index.
        case matched(index: Int)
        /// The pinned display is absent: falls back to the main display (0 if there is none).
        case fallback(index: Int)
    }

    /// - Parameters:
    ///   - pinnedUUID: the stored UUID of the pinned display.
    ///   - screenUUIDs: UUIDs read one by one from the current `NSScreen.screens`; nil where unreadable (no
    ///     false match).
    ///   - mainIndex: index of `NSScreen.main` in screens (may be nil).
    /// - Returns: nil when the screen set is empty (nowhere to place it; the caller handles the fallback).
    static func resolve(pinnedUUID: String, screenUUIDs: [String?], mainIndex: Int?) -> Outcome? {
        guard !screenUUIDs.isEmpty else { return nil }
        if let index = screenUUIDs.firstIndex(where: { $0 == pinnedUUID }) {
            return .matched(index: index)
        }
        if let mainIndex, screenUUIDs.indices.contains(mainIndex) {
            return .fallback(index: mainIndex)
        }
        return .fallback(index: 0)
    }

    /// De-duplicates display names for the settings Picker: when two monitors of the same model share a name,
    /// the second and later ones get a number ("LG HDR 4K", "LG HDR 4K (2)"). Same order as the input.
    static func displayTitles(names: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for name in names {
            counts[name, default: 0] += 1
        }
        var seen: [String: Int] = [:]
        return names.map { name in
            guard counts[name, default: 0] > 1 else { return name }
            let ordinal = seen[name, default: 0] + 1
            seen[name] = ordinal
            return ordinal == 1 ? name : "\(name) (\(ordinal))"
        }
    }
}

/// Pure presentation model of the status menu submenu "Show NitiaDock bar on ▸" (entry moved from the
/// settings window to the menu on 2026-08-26). Same house rule as `LaunchAtLoginMenuPresentation`: decisions
/// live here and are unit-testable, the controller only renders.
struct TaskbarScreenMenuPresentation {
    /// The choice a row stands for. `token` is the string round trip for `NSMenuItem.representedObject` (the
    /// controller also compiles in the test target, so ClosureMenuItem cannot be used).
    enum Selection: Equatable {
        case followMouse
        case screen(uuid: String)
        case allScreens
        case allScreensPerDisplay

        private static let screenPrefix = "screen:"

        var token: String {
            switch self {
            case .followMouse: return "followMouse"
            case .allScreens: return "allScreens"
            case .allScreensPerDisplay: return "allScreensPerDisplay"
            case .screen(let uuid): return Self.screenPrefix + uuid
            }
        }

        init?(token: String) {
            switch token {
            case "followMouse": self = .followMouse
            case "allScreens": self = .allScreens
            case "allScreensPerDisplay": self = .allScreensPerDisplay
            default:
                guard token.hasPrefix(Self.screenPrefix) else { return nil }
                let uuid = String(token.dropFirst(Self.screenPrefix.count))
                guard !uuid.isEmpty else { return nil }
                self = .screen(uuid: uuid)
            }
        }

        /// Lets old tests / callers look up by display UUID; nil for non-display rows.
        var screenUUID: String? {
            if case .screen(let uuid) = self { return uuid }
            return nil
        }
    }

    struct Item: Equatable {
        let selection: Selection
        let title: String
        let isChecked: Bool
    }

    /// One submenu row: gray group header (not clickable) / separator / selectable item. Two groups with
    /// headers is the form settled on 2026-09-02 (as five flat rows, "All Displays" and "All Displays, each
    /// showing only its own windows" were unclear).
    enum Row: Equatable {
        case header(String)
        case separator
        case option(Item)
    }

    /// The whole row (with its submenu) is hidden.
    let isHidden: Bool
    let rows: [Row]
    /// Selectable items (in order of appearance), for tests / old callers.
    var items: [Item] {
        rows.compactMap { row in
            if case let .option(item) = row { return item }
            return nil
        }
    }

    /// - Parameter connectedScreens: displays currently present, `title` already de-duplicated
    ///   (`displayTitles`).
    init(placement: TaskbarScreenPlacement, connectedScreens: [(uuid: String, title: String)]) {
        let pinned = placement.pinnedSelection
        // Hide only with a single display **and** a current mode that is neither fixed nor all-displays.
        // Without the second half there is a dead end: pin to an external display then unplug it / unplug
        // down to one display with "All Displays" on, and the whole row vanishes -> no way back to "Follow
        // Mouse".
        isHidden = connectedScreens.count < 2 && pinned == nil && !placement.showsOnEveryDisplay

        // Group 1 (single-display mode): hover-to-switch, or pinned to one screen.
        var rows: [Row] = [
            .header(String(localized: "One taskbar")),
            .option(Item(
                selection: .followMouse,
                title: String(localized: "Where the pointer is"),
                isChecked: placement == .followMouse
            ))
        ]
        rows += connectedScreens.map { screen in
            .option(Item(
                selection: .screen(uuid: screen.uuid),
                title: screen.title,
                isChecked: pinned?.uuid == screen.uuid
            ))
        }
        // The pinned display is absent right now: append "XX (Not Connected)" to the first group and keep it
        // selected, so the choice is not lost and applies again on reconnect.
        if let pinned, !connectedScreens.contains(where: { $0.uuid == pinned.uuid }) {
            rows.append(.option(Item(
                selection: .screen(uuid: pinned.uuid),
                title: String(format: String(localized: "%@ (disconnected)"), pinned.name),
                isChecked: true
            )))
        }
        // Group 2 (multi-display mode): ③ same content everywhere / ④ each bar lists only its own screen.
        rows.append(.separator)
        rows.append(.header(String(localized: "A taskbar on every display")))
        rows.append(.option(Item(
            selection: .allScreens,
            title: String(localized: "Each listing every window"),
            isChecked: placement == .allScreens
        )))
        rows.append(.option(Item(
            selection: .allScreensPerDisplay,
            title: String(localized: "Each listing its own windows"),
            isChecked: placement == .allScreensPerDisplay
        )))
        self.rows = rows
    }
}
