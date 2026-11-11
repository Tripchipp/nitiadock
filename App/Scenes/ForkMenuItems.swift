import AppKit

// fork: menu items NitiaDock adds to upstream's native menus.
extension AppMenuBuilder {
    /// "NitiaDock Settings…" in an app's right-click menu.
    ///
    /// It sits directly under the keep/messaging group ("Keep in Dock", "Pin to Messaging Zone"):
    /// callers there pass `separated: false`. The calls at the very end of the menus stay as the
    /// fallback for menus without that group and do nothing once the item is in.
    ///
    /// The bar's own menu (which has Settings…) only opens from a right-click on blank plate: the
    /// bar's ends and the gaps around zone dividers. With small edge padding and no spacing there is
    /// next to no blank plate, and with the menu bar icon tucked away by a menu bar manager there is
    /// no other way in. Upstream keeps Quit as the last item of these menus; this goes below it,
    /// behind a separator, so Quit stays where muscle memory expects it within the app's own group.
    @MainActor
    static func appendForkSettingsItem(to menu: NSMenu, separated: Bool = true) {
        guard let open = ForkSettingsContext.openSettings else { return }
        if menu.items.contains(where: { $0.identifier == forkSettingsItemID }) { return }
        if separated, !menu.items.isEmpty, menu.items.last?.isSeparatorItem == false {
            menu.addItem(.separator())
        }
        let item = ClosureMenuItem(String(localized: "NitiaDock Settings…")) {
            // Let the menu finish closing first, as the status menu's own Settings item does.
            DispatchQueue.main.async { open() }
        }
        item.identifier = forkSettingsItemID
        item.keyEquivalentModifierMask = []
        menu.addItem(item)
    }

    private static let forkSettingsItemID = NSUserInterfaceItemIdentifier("fork.nitiadock-settings")
}
