import AppKit

/// NSScreen -> display UUID (`CGDisplayCreateUUIDFromDisplayID`, EDID-based, stable across replug / port
/// change / sleep-wake). It is the persisted identity for pinning a taskbar to a display; **never record a
/// display by its index in `NSScreen.screens`**. Same logic as
/// `ManagedSpaceLayoutReader.displayUUIDString(for:)` in `FullscreenIntentMonitor.swift` (that file's details
/// are frozen by a project rule, so the implementation is deliberately not shared).
enum DisplayIdentity {
    @MainActor
    static func uuidString(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value))
        else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String?
    }

    /// Table of present displays: the Quartz frame of every display whose UUID can be read + the primary
    /// display (`NSScreen.screens.first`, the one with the menu bar; **not** `NSScreen.main`, which follows
    /// the key window). Fed to `WindowDisplayAttribution` / `StripDisplayFilter`. Compute once when screen
    /// parameters change (`DisplayTopologyStore`), not on a hot path.
    @MainActor
    static func attributionTable() -> WindowDisplayAttribution.Table {
        attributionTable(screens: NSScreen.screens)
    }

    /// Builds the table from screens the caller already sampled, so one topology transaction
    /// never reads `NSScreen.screens` twice.
    @MainActor
    static func attributionTable(screens: [NSScreen]) -> WindowDisplayAttribution.Table {
        let primaryHeight = screens.first?.frame.maxY ?? 0
        var primaryUUID: String?
        let displays: [WindowDisplayAttribution.Display] = screens.enumerated().compactMap { index, screen in
            guard let uuid = uuidString(for: screen) else { return nil }
            if index == 0 { primaryUUID = uuid }
            return WindowDisplayAttribution.Display(
                uuid: uuid,
                cgFrame: WindowLiftAvoidance.quartzFrame(fromAppKit: screen.frame, primaryScreenHeight: primaryHeight),
                visibleCGFrame: WindowLiftAvoidance.quartzFrame(fromAppKit: screen.visibleFrame,
                                                                primaryScreenHeight: primaryHeight)
            )
        }
        return WindowDisplayAttribution.Table(
            displays: displays,
            primaryUUID: primaryUUID
        )
    }

    /// Derives the physical display count, the ordered UUIDs and the attribution table from a
    /// single read.
    @MainActor
    static func topologySnapshot() -> ScreenTopologySnapshot {
        let screens = NSScreen.screens
        let table = attributionTable(screens: screens)
        return ScreenTopologySnapshot(
            physicalDisplayCount: screens.count,
            identifiedDisplayUUIDs: table.displays.map(\.uuid),
            attributionTable: table
        )
    }

    /// Present displays -> (display UUID, deduplicated display name). Displays whose UUID cannot be read are
    /// left out (they cannot be pinned to). **Does system I/O (`localizedName` reads IODisplay), do not
    /// compute on the menu popup path**: callers should cache it when screen parameters change (as
    /// `StatusMenuController` does).
    @MainActor
    static func connectedScreenOptions() -> [(uuid: String, title: String)] {
        let identified: [(uuid: String, name: String)] = NSScreen.screens.compactMap { screen in
            guard let uuid = uuidString(for: screen) else { return nil }
            return (uuid, screen.localizedName)
        }
        let titles = TaskbarScreenResolution.displayTitles(names: identified.map(\.name))
        return zip(identified, titles).map { ($0.uuid, $1) }
    }
}
