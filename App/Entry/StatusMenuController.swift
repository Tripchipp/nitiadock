import AppKit
import Combine

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let store: AppSettingsStore
    private let settingsCoordinator: SettingsCoordinator
    // Injected as a closure instead of depending on PermissionService directly: the test target compiles this
    // file but not PermissionService.swift.
    private let isAccessibilityTrusted: () -> Bool
    private let onShowDebugConsole: () -> Void
    private let onExportDebugSnapshot: () -> Void
    private let onShowSettings: () -> Void
    /// Menu opened / closed. The taskbar's edge auto-hide has to pause while the menu is open, otherwise the
    /// idle timer keeps running and the taskbar retracts from under the open menu (same as
    /// `folderPopupOpen`). A closure because `PanelCoordinator` does not exist at all before permission
    /// onboarding completes.
    private let onMenuVisibilityChanged: (Bool) -> Void
    private let onQuit: () -> Void
    /// Display glyphs of the current show/hide shortcut. Fetched through a closure each time: after the user
    /// rebinds, the section title must follow on the next open.
    private let hotKeyGlyphs: () -> String
    // Closure injection: registration state belongs to the GlobalHotKeyMonitor held by AppDelegate and is
    // queried on every menu refresh.
    private let isToggleHotKeyRegistered: () -> Bool
    /// Source of the connected-screen snapshot. Injected as a closure instead of calling `DisplayIdentity`
    /// directly: the test target compiles this file but not `Platform/` (same reason as
    /// `isAccessibilityTrusted`).
    private let connectedScreens: () -> [(uuid: String, title: String)]
    /// Screen snapshot cache. **The menu path only reads it, never computes it on the spot**: `localizedName`
    /// reads IODisplay, and main-thread system I/O on the menu path makes macOS coalesce mouse-moved events
    /// (the menu stops following the pointer).
    private var connectedScreensCache: [(uuid: String, title: String)] = []
    private var screenParametersObserver: NSObjectProtocol?
    private var edgeDelaySubscription: AnyCancellable?
    /// Pending-update hint: the dot on the icon has to light up while the menu is closed too, hence the
    /// separate subscription.
    private var pendingUpdateSubscription: AnyCancellable?
    private var systemTruthRefreshTask: Task<Void, Never>?
    private var isMenuOpen = false
    private var isPreparedForTaskbarPresentation = false
    /// Whether this menu was opened by right-clicking the taskbar. The menu is anchored to the taskbar's top
    /// edge and is left hanging once the taskbar retracts, so this path does **no live preview**
    /// (2026-08-03); the status bar icon path is unaffected.
    private var isPresentedFromTaskbar = false

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let permissionWarningItem = NSMenuItem(title: String(localized: "Accessibility Permission Required"), action: #selector(openAccessibilitySettings), keyEquivalent: "")
    private let permissionWarningSeparator = NSMenuItem.separator()
    private let settingsItem = NSMenuItem(title: String(localized: "Settings…"), action: #selector(showSettings), keyEquivalent: ",")
    /// The login item moved twice on 2026-08-24: first to the Settings window with the menu dedup, then on
    /// reconsideration **back to the menu as the first item**, no longer in the Settings window (still not
    /// duplicated). Do not move it back to the Settings window without a new decision.
    private let launchAtLoginItem = NSMenuItem(title: String(localized: "Open at Login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let openLoginItemsSettingsItem = NSMenuItem(title: String(localized: "Open Login Items Settings…"), action: #selector(openLoginItemsSettings), keyEquivalent: "")
    /// "Install vX.Y.Z…": **visible only when an update is pending** (menu dedup, 2026-08-24). Login item,
    /// check for updates and version number live only in the Settings window now; this row is the menu's only
    /// update surface because it is a **message**, not a command:
    /// the red dot has to be seen even when the user has not gone looking. Visibility may only flip in
    /// `prepareMenuForPresentation` (adding/removing rows while the menu is open makes the taskbar anchor
    /// drift, see refreshInstallUpdateItem).
    private let installUpdateItem = NSMenuItem(title: "", action: #selector(installPendingUpdate), keyEquivalent: "")
    /// Section title of the NitiaDock group, never clickable (the title is set in refreshEdgeSectionTitle
    /// according to hotkey registration state).
    private let edgeSectionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    // Shelf / show app names on hover / maximize lift avoidance / taskbar size moved from the Settings window
    // back to the menu on 2026-09-01 (decided then, reversing the 2026-08-03 split): they get toggled
    // casually while tuning the look, not worth opening a window for.
    // The four items joined the NitiaDock group (no header of their own), in the same group as "Show taskbar
    // on ▸".
    // Login item / check for updates / version number still follow the 2026-08-24 dedup: Settings window
    // only.

    /// Section title, never clickable (the title is set in configureMenu).
    private let nativeDockSectionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// The only commit entry for the slider draft, hidden by default. It hosts a **real button**, not a plain
    /// menu text row:
    /// as a menu row it has the same visual weight as its neighbor ("Dock Settings…") and does not stand out
    /// in the menu, while the user who just finished dragging is still looking at the slider; missing it
    /// turns "flickers but took effect" into "thought it was set but it never took effect", worse than the
    /// original flicker (pointed out in acceptance, 2026-08-02).
    private let nativeDockApplyItem = NSMenuItem()
    private let nativeDockApplyRow = NativeDockApplyRowView()
    private let openNativeDockSettingsItem = NSMenuItem(title: String(localized: "Dock Settings…"), action: #selector(openNativeDockSettings), keyEquivalent: "")
    /// "Show taskbar on ▸": a submenu with "Follow mouse" + one item per connected screen (2026-08-26: this
    /// setting moved from the Settings window to the menu, not kept in both). A submenu so that **the main
    /// menu gains one row and keeps a constant height**:
    /// a changing screen count does not change the main menu height, so the taskbar path that positions by
    /// the top-left corner does not drift.
    /// The row's visibility may only flip in `prepareMenuForPresentation` (the standing rule about
    /// adding/removing rows while the menu is open).
    private let taskbarScreenItem = NSMenuItem(title: String(localized: "Show taskbar on"), action: nil, keyEquivalent: "")
    /// **Deliberately no delegate**: `menuWillOpen` / `menuDidClose` do not distinguish the menu argument, so
    /// a submenu opening and closing would be taken for the main menu and lift the edge auto-hide suppression
    /// early. The content is instead built before the parent menu shows (`prepareMenuForPresentation`).
    private let taskbarScreenMenu = NSMenu()
    /// "Taskbar Size ▸": a static four-size submenu, built once by `configureMenu`, afterwards only
    /// checkmarks flip.
    /// A submenu rather than four flat rows, for the same reason as "Show taskbar on ▸": the main menu gains
    /// only one row.
    private let dockSizeItem = NSMenuItem(title: String(localized: "Taskbar Size"), action: nil, keyEquivalent: "")
    private let dockSizeMenu = NSMenu()
    /// The four below are plain checkmark items, **always present** (no adding/removing rows while the menu
    /// is open); checkmark state is set by refreshCheckmarks.
    private let showShelfItem = NSMenuItem(title: String(localized: "Show Shelf"), action: #selector(toggleShowShelf), keyEquivalent: "")
    /// fork: the drawer capsule on the right of the strip. Off hides the whole drawer.
    private let showDrawerItem = NSMenuItem(title: String(localized: "Show Drawer"), action: #selector(toggleShowDrawer), keyEquivalent: "")
    private let showTrashItem = NSMenuItem(title: String(localized: "Show Trash"), action: #selector(toggleShowTrash), keyEquivalent: "")
    private let hoverNameItem = NSMenuItem(title: String(localized: "Show app names on hover"), action: #selector(toggleHoverName), keyEquivalent: "")
    private let windowLiftItem = NSMenuItem(title: String(localized: "Keep maximized windows above the taskbar"), action: #selector(toggleWindowLift), keyEquivalent: "")
    /// fork: `ForkReservedSpaceController`.
    private let reserveSpaceItem = NSMenuItem(title: String(localized: "Reserve space for the taskbar"), action: #selector(toggleReserveSpace), keyEquivalent: "")
    private let nativeDockSliderView: PreferenceSliderMenuItemView
    private let edgeSliderView: PreferenceSliderMenuItemView

    init(store: AppSettingsStore,
         settingsCoordinator: SettingsCoordinator,
         isAccessibilityTrusted: @escaping () -> Bool,
         onShowDebugConsole: @escaping () -> Void,
         onExportDebugSnapshot: @escaping () -> Void,
         onShowSettings: @escaping () -> Void,
         onMenuVisibilityChanged: @escaping (Bool) -> Void = { _ in },
         onQuit: @escaping () -> Void,
         hotKeyGlyphs: @escaping () -> String,
         isToggleHotKeyRegistered: @escaping () -> Bool = { false },
         connectedScreens: @escaping () -> [(uuid: String, title: String)] = { [] }) {
        self.store = store
        self.settingsCoordinator = settingsCoordinator
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.onShowDebugConsole = onShowDebugConsole
        self.onExportDebugSnapshot = onExportDebugSnapshot
        self.onShowSettings = onShowSettings
        self.onMenuVisibilityChanged = onMenuVisibilityChanged
        self.onQuit = onQuit
        self.hotKeyGlyphs = hotKeyGlyphs
        self.isToggleHotKeyRegistered = isToggleHotKeyRegistered
        self.connectedScreens = connectedScreens
        nativeDockSliderView = PreferenceSliderMenuItemView(accessibilityTitle: String(localized: "Dock wake delay"))
        edgeSliderView = PreferenceSliderMenuItemView(accessibilityTitle: String(localized: "NitiaDock wake delay"))
        super.init()
        configureStatusItem()
        configureMenu()
        refreshCheckmarks()
        refreshInstallUpdateItem(allowsLayoutChange: true)
        // The NitiaDock slider is a local value that applies immediately: ⌥⇧⌘D and the Settings window may
        // both change it while the menu is open, and the slider has to follow.
        // The sink uses the new value emitted by the publisher: @Published publishes before the assignment
        // completes, so reading the store back now gives the old value.
        //
        // The system Dock group deliberately has **no** such subscription: until the draft is written to the
        // system on release the system has not changed, so the slider should not move.
        // Its position is synced once in menuWillOpen and once after a commit completes.
        edgeDelaySubscription = store.$edgeAutoHideDelay
            .removeDuplicates()
            .sink { [weak self] delay in
                self?.edgeSliderView.sync(delay: delay)
            }
        // The update hint has to appear on the icon **while the menu is closed**, that is its whole point, so
        // it cannot wait for `menuWillOpen`. `objectWillChange` fires before the assignment completes, and
        // the new value is only readable one pass later (same reason as the comment above).
        pendingUpdateSubscription = settingsCoordinator.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.refreshStatusItemBadge()
                // Text and enabled state may change at any time; **row visibility may not**: adding/removing
                // rows while the menu is open, with the taskbar path positioning by the top-left corner,
                // makes the bottom edge drift off the taskbar's top edge (constant row count rule).
                self.refreshInstallUpdateItem(allowsLayoutChange: !self.isMenuOpen)
            }
        refreshStatusItemBadge()
        refreshSystemTruth()
        // The screen list is recomputed only on plug/unplug; menu open reads the cache (see
        // connectedScreensCache).
        connectedScreensCache = connectedScreens()
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.connectedScreensCache = self.connectedScreens()
            }
        }
    }

    deinit {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    private func configureStatusItem() {
        statusItem.button?.image = Self.statusItemImage(badged: false)
        statusItem.menu = menu
    }

    private func configureMenu() {
        menu.delegate = self

        permissionWarningItem.target = self
        permissionWarningItem.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: String(localized: "Warning"))
        permissionWarningItem.isHidden = true
        permissionWarningSeparator.isHidden = true
        menu.addItem(permissionWarningItem)
        menu.addItem(permissionWarningSeparator)

        // Open at Login = first menu item (decided 2026-08-24; the permission warning only appears in an
        // abnormal state and does not count).
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)
        openLoginItemsSettingsItem.target = self
        menu.addItem(openLoginItemsSettingsItem)
        menu.addItem(.separator())

        // The NitiaDock group comes before the system Dock group: this is NitiaDock's own menu, its own
        // settings go first.
        // Both groups have a gray section title as a "header": formerly only the system Dock had one, the
        // only header in the whole menu sat on top, so the NitiaDock commands below it looked like they
        // belonged to it too (feedback 2026-08-03).
        edgeSectionItem.isEnabled = false
        menu.addItem(edgeSectionItem)

        // The NitiaDock slider applies immediately: every step dragged is written to the store. But **writing
        // the value alone shows no effect**:
        // opening the menu sets the `taskbarMenuOpen` suppressor, the taskbar is forced to stay visible and
        // may not hide, so nothing moves even at 0.5s until the menu is closed (the 2026-08-03 "only takes
        // effect after dismissing the menu" report).
        //
        // So **touching this slider lifts the suppression** and lets the taskbar really move with the new
        // setting: touching the slider = asking to see the effect.
        // Without touching the slider the suppression stays, and the taskbar does not retract from under an
        // idle open menu.
        //
        // **The menu opened by right-clicking the taskbar is the exception**: it is anchored to the taskbar's
        // top edge and is left hanging in mid-air once the taskbar retracts, which is worse than not seeing
        // the effect (2026-08-03). That path only writes the value without lifting the suppression, and it
        // takes effect when the menu closes. `menuDidClose` calls it with false once more afterwards,
        // idempotent.
        edgeSliderView.onDelayChange = { [weak self, weak store] delay in
            store?.setEdgeAutoHideDelay(delay)
            guard let self, !self.isPresentedFromTaskbar else { return }
            self.onMenuVisibilityChanged(false)
        }
        let edgeItem = NSMenuItem()
        edgeItem.view = edgeSliderView
        menu.addItem(edgeItem)
        menu.addItem(.separator())

        nativeDockSectionItem.attributedTitle = Self.sectionTitle(AutoHideToggleMenuModel.nativeDockSectionTitle)
        nativeDockSectionItem.isEnabled = false
        menu.addItem(nativeDockSectionItem)

        // The system Dock slider is **not wired** to the store: a `setNativeDockAutoHideDelay` call persists
        // active + remembered together, while the system side is only written once the user clicks the
        // confirm row; a half-dragged value should not become persistent state.
        // onDraftChange only refreshes the confirm row and touches no persistent state.
        nativeDockSliderView.onDraftChange = { [weak self] draft in
            self?.refreshNativeDockApplyItem(draft: draft)
        }
        nativeDockSliderView.onDelayCommit = { [weak self] target in
            self?.scheduleNativeDockWrite(target: target)
        }
        let nativeDockSliderItem = NSMenuItem()
        nativeDockSliderItem.view = nativeDockSliderView
        menu.addItem(nativeDockSliderItem)

        nativeDockApplyRow.onApply = { [weak self] in
            self?.applyNativeDockDelay()
        }
        nativeDockApplyItem.view = nativeDockApplyRow
        nativeDockApplyItem.isHidden = true
        menu.addItem(nativeDockApplyItem)

        menu.addItem(.separator())

        // The taskbar's own five items (2026-09-01, outcome of two decisions that day): **a block of their
        // own, without a section title**, placed after the two wake sliders. Joining the NitiaDock group was
        // tried first; on the real machine they had to leave the sliders and form their own block.
        // With no header, only the separators above and below set it apart, so **nothing else may be inserted
        // into this block**:
        // once rows unrelated to the taskbar get mixed in, readers can only guess from the wording what they
        // belong to.
        // The visibility of `taskbarScreenItem` still flips only in `prepareMenuForPresentation`
        // (adding/removing rows while the menu is on screen makes the anchor of the taskbar popup path
        // drift).
        taskbarScreenItem.submenu = taskbarScreenMenu
        taskbarScreenItem.isHidden = true
        menu.addItem(taskbarScreenItem)

        // The size submenu is four static sizes, built once; checkmarks are left to refreshCheckmarks.
        for size in DockSize.allCases {
            let sizeItem = NSMenuItem(title: size.title, action: #selector(selectDockSize(_:)), keyEquivalent: "")
            sizeItem.target = self
            // rawValue goes through representedObject. **`ClosureMenuItem` cannot be used**:
            // `AppMenuFragments.swift` is compiled into the app target only, while this file also compiles in
            // the test target.
            sizeItem.representedObject = size.rawValue
            dockSizeMenu.addItem(sizeItem)
        }
        dockSizeItem.submenu = dockSizeMenu
        menu.addItem(dockSizeItem)

        // Four toggles. In the Settings window each has a gray description line; the menu has no place for
        // subtitles, so the descriptions were dropped with the move (cost accepted 2026-09-01).
        showShelfItem.target = self
        menu.addItem(showShelfItem)
        showDrawerItem.target = self
        menu.addItem(showDrawerItem)
        showTrashItem.target = self
        menu.addItem(showTrashItem)
        hoverNameItem.target = self
        menu.addItem(hoverNameItem)
        windowLiftItem.target = self
        menu.addItem(windowLiftItem)
        reserveSpaceItem.target = self
        reserveSpaceItem.toolTip = String(localized: "Moves or shrinks the front window when it would end up under the taskbar. Only while the taskbar is always visible. Windows are not moved back when you turn this off.")
        menu.addItem(reserveSpaceItem)
        menu.addItem(.separator())
        #if DEBUG
        let debugMenu = NSMenu()
        let showDebug = NSMenuItem(title: String(localized: "Show Debug Console"), action: #selector(showDebugConsole), keyEquivalent: "")
        showDebug.target = self
        debugMenu.addItem(showDebug)
        let exportSnapshot = NSMenuItem(title: String(localized: "Export Taskbar Snapshot"), action: #selector(exportDebugSnapshot), keyEquivalent: "")
        exportSnapshot.target = self
        debugMenu.addItem(exportSnapshot)
        let debugItem = NSMenuItem(title: String(localized: "Debug"), action: nil, keyEquivalent: "")
        debugItem.submenu = debugMenu
        menu.addItem(debugItem)
        menu.addItem(.separator())
        #endif

        // "Settings…" and "Quit" form the bottom group (2026-08-03): the common habit of menu bar apps is to
        // put such "go to another interface" entries at the bottom and leave the top to casually flipped
        // toggles.
        // Login item / check for updates / version number were deduplicated on 2026-08-24, Settings window
        // only.
        settingsItem.target = self
        settingsItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsItem)

        // Alongside "Settings…": both "open another interface". That is why it left the system Dock group
        // (2026-08-03; it used to be that group's last row and looked like a pair with the next group's first
        // row).
        openNativeDockSettingsItem.target = self
        menu.addItem(openNativeDockSettingsItem)

        installUpdateItem.target = self
        installUpdateItem.isHidden = true
        menu.addItem(installUpdateItem)

        let quitItem = NSMenuItem(title: String(localized: "Quit NitiaDock"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }


    /// Popup entry point for right-click on the taskbar / capsule.
    ///
    /// **Shares the same `NSMenu` instance** with the status bar icon: the two sliders and the confirm button
    /// in the menu are stateful custom-drawn NSViews, and a clone would immediately give "two sliders each
    /// keeping their own draft". The existing `menuWillOpen` logic (reloading the system Dock's real value,
    /// refreshing checkmarks, discarding unconfirmed drafts) goes through the same delegate, so both entry
    /// points behave identically.
    func popUpFromTaskbar(with event: NSEvent, in view: NSView) {
        // Compute the anchor ourselves so the menu's **bottom edge sits on the taskbar's top edge** with the
        // left edge aligned to the mouse, floating above the bar like a right-click on the system Dock,
        // without covering it. Left to `NSMenu.popUpContextMenu` auto-flipping, the measured menu bottom
        // lands 28pt below the mouse and covers the whole taskbar (half the reason for the 2026-08-03 "does
        // not feel responsive" feedback).
        //
        // `MenuHostNSView` is a plain NSView (`isFlipped == false`, origin at bottom-left) that fills the
        // taskbar's visible area, so `bounds.maxY` is the taskbar's top edge; `popUp(positioning:at:in:)`
        // puts the menu's **top-left corner** at the given point, hence the extra lift by one menu height.
        isPresentedFromTaskbar = true
        prepareMenuForPresentation()
        isPreparedForTaskbarPresentation = true
        let local = view.convert(event.locationInWindow, from: nil)
        let anchor = NSPoint(x: local.x, y: view.bounds.maxY + menu.size.height)
        menu.popUp(positioning: nil, at: anchor, in: view)
        isPreparedForTaskbarPresentation = false
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        isPresentedFromTaskbar = false
        onMenuVisibilityChanged(false)
        // Prewarm once more after closing; all results go to the cache only, for direct use on the next
        // presentation.
        refreshSystemTruth()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        onMenuVisibilityChanged(true)
        if !isPreparedForTaskbarPresentation {
            prepareMenuForPresentation()
        }
        isPreparedForTaskbarPresentation = false
        refreshSystemTruth()
    }

    /// Only reads local caches and syncs AppKit objects, performs no system I/O.
    /// The taskbar entry point comes through here before measuring `menu.size`, so the anchor uses this
    /// presentation's real height.
    private func prepareMenuForPresentation() {
        let granted = isAccessibilityTrusted()
        permissionWarningItem.isHidden = granted
        permissionWarningSeparator.isHidden = granted
        refreshCheckmarks()
        refreshInstallUpdateItem(allowsLayoutChange: true)
        // Closing the menu without confirming = discard: nothing is written, and the next open starts over
        // from the system's real value.
        // (Otherwise "just nudging it to see" would also bring a killall Dock: the screen suddenly flashing
        // on closing a menu is exactly the oddity being removed here.)
        //
        // **Discarding happens "on open" rather than in `menuDidClose`** so as not to depend on the form of
        // the confirm control.
        // The confirm is currently an `NSButton` in a custom view whose action is sent directly, safe
        // anywhere; but as soon as someone turns it back into a plain `NSMenuItem`, `menuDidClose` becomes a
        // trap: AppKit's order is close the menu, `menuDidClose` callback, and only **then** send the menu
        // item action, so the draft would be cleared before the confirm, `commitDraft()` gets nil, and the
        // whole confirm feature silently fails (hit and fixed in this round).
        nativeDockSliderView.discardDraft()
        nativeDockSliderView.sync(delay: store.nativeDockAutoHideDelay)
        nativeDockApplyItem.isHidden = true
        edgeSliderView.sync(delay: store.edgeAutoHideDelay)
        refreshEdgeSectionTitle()
        rebuildTaskbarScreenMenu()
    }

    /// Rebuilds "Show taskbar on ▸". **Called only from `prepareMenuForPresentation`**, the only path allowed
    /// to change row visibility (adding/removing rows while the menu is on screen makes the taskbar anchor
    /// drift).
    private func rebuildTaskbarScreenMenu() {
        let presentation = TaskbarScreenMenuPresentation(
            placement: store.taskbarScreenPlacement,
            connectedScreens: connectedScreensCache
        )
        taskbarScreenItem.isHidden = presentation.isHidden
        taskbarScreenMenu.removeAllItems()
        for row in presentation.rows {
            switch row {
            case .header(let title):
                // Section title as for the two in the main menu: disabled + attributedTitle (secondary label
                // color), no keyEquivalent.
                let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                header.attributedTitle = Self.sectionTitle(title)
                header.isEnabled = false
                taskbarScreenMenu.addItem(header)
            case .separator:
                taskbarScreenMenu.addItem(.separator())
            case .option(let item):
                let menuItem = NSMenuItem(
                    title: item.title,
                    action: #selector(selectTaskbarScreen(_:)),
                    keyEquivalent: ""
                )
                menuItem.target = self
                // The selection goes through representedObject as a token string. **ClosureMenuItem cannot be
                // used**:
                // `AppMenuFragments.swift` is compiled into the app target only, while this file also
                // compiles in the test target.
                menuItem.representedObject = item.selection.token
                menuItem.state = item.isChecked ? .on : .off
                taskbarScreenMenu.addItem(menuItem)
            }
        }
    }

    /// System reads run on the service's dedicated queue. The taskbar menu positions by the top-left corner,
    /// and changing height after showing makes the bottom edge drift, so that path only updates the cache;
    /// the status bar menu has no such anchor constraint and can absorb the new real value in place.
    /// (The login item half was removed with the 2026-08-24 dedup and restored when the login item returned
    /// to the menu.)
    private func refreshSystemTruth() {
        systemTruthRefreshTask?.cancel()
        let settingsCoordinator = settingsCoordinator
        systemTruthRefreshTask = Task { @MainActor [weak self] in
            async let launchAccepted = settingsCoordinator.refreshLaunchAtLoginState()
            async let nativeDockAccepted = settingsCoordinator.reconcileNativeDockMirror()
            let accepted = await (launchAccepted, nativeDockAccepted)
            guard let self,
                  !Task.isCancelled,
                  self.isMenuOpen,
                  !self.isPresentedFromTaskbar else { return }
            if accepted.0 {
                self.refreshCheckmarks(allowsLayoutChange: false)
            }
            // The slider follows the real value only while the user has not started dragging: a hand mid-drag
            // must not see it jump.
            if accepted.1, !self.nativeDockSliderView.hasDraft {
                self.nativeDockSliderView.sync(delay: self.store.nativeDockAutoHideDelay)
            }
        }
    }

    /// Section titles get **no `keyEquivalent`**: on a disabled row it would be captured by the menu and make
    /// it look clickable.
    /// ⌥⇧⌘D is written into the title as plain text only, and only when Carbon registration succeeded: when
    /// it failed the keys do nothing, and listing them would be a lie.
    private func refreshEdgeSectionTitle() {
        edgeSectionItem.attributedTitle = Self.sectionTitle(
            AutoHideToggleMenuModel.edgeSectionTitle(
                isHotKeyRegistered: isToggleHotKeyRegistered(),
                glyphs: hotKeyGlyphs()
            )
        )
    }

    /// The confirm row only appears when the draft differs from the applied value. The applied value comes
    /// from the local mirror, which `menuWillOpen` just aligned with the system's real value.
    private func refreshNativeDockApplyItem(draft: Double) {
        let shouldShow = AutoHideToggleMenuModel.shouldShowNativeApply(
            draft: draft,
            applied: store.nativeDockAutoHideDelay
        )
        nativeDockApplyItem.isHidden = !shouldShow
        if shouldShow {
            // The button title is always "Apply"; the target setting goes into accessibility only: the slider
            // already expresses it once with the value and end-point dots, and repeating it in the button
            // would crowd it; but VoiceOver hears only this one sentence, so it must include the setting.
            nativeDockApplyRow.updateTarget(description: AutoHideToggleMenuModel.nativeApplyTitle(draft: draft))
            // The previous round may have ended in the hover state, while this time the mouse is still on the
            // slider, not the button, when it appears.
            nativeDockApplyRow.resetInteractionState()
        }
    }

    private func applyNativeDockDelay() {
        nativeDockSliderView.commitDraft()
    }

    @objc private func openNativeDockSettings() {
        guard settingsCoordinator.openNativeDockSettings() else {
            presentError(
                title: String(localized: "Can’t Open Dock Settings"),
                message: String(localized: "Open System Settings and go to Desktop & Dock (on macOS 12, Dock & Menu Bar).")
            )
            return
        }
    }

    /// `allowsLayoutChange` = whether this refresh may add/remove menu rows. Before presentation
    /// (`prepareMenuForPresentation`) it may; when the async real value comes back it **may not**, for the
    /// reason in `refreshLaunchAtLoginState`.
    private func refreshCheckmarks(allowsLayoutChange: Bool = true) {
        refreshLaunchAtLoginState(allowsLayoutChange: allowsLayoutChange)
        refreshTaskbarPreferenceStates()
    }

    /// Checkmarks of the four NitiaDock group items. **Changes only `state`, never adds/removes rows or flips
    /// `isHidden`**, so it is safe to call while the menu is open (not bound by `allowsLayoutChange`).
    private func refreshTaskbarPreferenceStates() {
        showShelfItem.state = store.showShelf ? .on : .off
        showDrawerItem.state = store.showDrawer ? .on : .off
        showTrashItem.state = store.showTrash ? .on : .off
        hoverNameItem.state = store.hoverStyle.isExpressive ? .on : .off
        windowLiftItem.state = store.windowLiftEnabled ? .on : .off
        reserveSpaceItem.state = store.reserveScreenSpace ? .on : .off
        let current = store.dockSize.rawValue
        for item in dockSizeMenu.items {
            item.state = (item.representedObject as? String) == current ? .on : .off
        }
    }

    private func refreshLaunchAtLoginState(allowsLayoutChange: Bool) {
        let presentation = LaunchAtLoginMenuPresentation(state: settingsCoordinator.launchAtLoginState)
        launchAtLoginItem.title = presentation.title
        launchAtLoginItem.state = presentation.isChecked ? .on : .off
        launchAtLoginItem.isEnabled = presentation.isEnabled
        // While the menu is already on screen, **change only text and checkmarks, never add/remove rows**.
        // When the login item is in `.requiresApproval` (just registered, awaiting approval in System
        // Settings) this row appears, the async real value comes back late, and an extra row changes the menu
        // height:
        // the user sees "the content jumped by itself", and since the taskbar path positions by the top-left
        // corner, the bottom edge drifts too.
        // One round late is fine: the next `prepareMenuForPresentation` catches up **before** the menu shows.
        guard allowsLayoutChange else { return }
        openLoginItemsSettingsItem.isHidden = !presentation.showsSettingsItem
    }

    /// The only refresh entry for the "Install vX.Y.Z…" row. `allowsLayoutChange` = whether this refresh may
    /// change the row's visibility:
    /// before presentation (`prepareMenuForPresentation`) and while the menu is closed it may; while the menu
    /// is open it **may not**:
    /// adding/removing rows changes the menu height, the taskbar path positions by the top-left corner, and
    /// the bottom edge would drift off the taskbar's top edge.
    /// One round late is fine: the next `prepareMenuForPresentation` catches up **before** the menu shows.
    private func refreshInstallUpdateItem(allowsLayoutChange: Bool) {
        // When a version is waiting to be installed, this row spells out the version number with a red dot
        // (per the 2026-08-20 sketch):
        // "Install 0.9.2…" with a red dot is a message; the active "Check for Updates…" entry lives only in
        // the Settings window (2026-08-24).
        if let version = settingsCoordinator.pendingUpdateVersion {
            let title = String(format: String(localized: "Install %@…"), version)
            installUpdateItem.title = title
            installUpdateItem.attributedTitle = Self.pendingUpdateTitle(title)
            // VoiceOver would read that "●" as "solid circle", so a plain sentence is supplied separately.
            installUpdateItem.setAccessibilityLabel(
                String(format: String(localized: "Install %@ — update available"), version)
            )
            // Enabled state belongs to Sparkle: while downloading / installing it reports false itself, no
            // "in flight" flag is kept anymore.
            installUpdateItem.isEnabled = settingsCoordinator.canCheckForUpdates
            if allowsLayoutChange { installUpdateItem.isHidden = false }
        } else {
            // ⚠️ attributedTitle must be reset to nil. If left set, no change to `title` takes effect and
            // this row stays stuck on the previous version number forever.
            installUpdateItem.attributedTitle = nil
            installUpdateItem.setAccessibilityLabel(nil)
            if allowsLayoutChange { installUpdateItem.isHidden = true }
        }
    }

    /// Style of the two section titles. **Must go through `attributedTitle`**: a section title is a disabled
    /// item with `action: nil`, has no `textColor` to set, and the system draws disabled items in the
    /// faintest tier of the menu, which was too gray (2026-09-01).
    /// Darkened to `secondaryLabelColor`: weaker than clickable items but legible. **Do not make it enabled
    /// to get it darker**: it would then highlight as a blue bar under the mouse, and section titles not
    /// highlighting is correct (2026-08-04).
    ///
    /// ⚠️ The font must be given explicitly: without it `attributedTitle` drops to the system default size
    /// (same as `pendingUpdateTitle`).
    /// ⚠️ Once `attributedTitle` is set, **assigning `title` has no effect**, so `refreshEdgeSectionTitle()`
    /// has to go through here too; do not change only one of the two call sites.
    private static func sectionTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
    }

    /// "Install X.Y.Z…" + a red dot at the top right.
    ///
    /// ⚠️ **The title part must be given color and font explicitly**: without them `attributedTitle` is pure
    /// black + system default size, simply invisible in a dark menu. The red dot can be real red here: the
    /// menu background is not the menu bar, so the template inversion constraint of the menu bar icon does
    /// not apply (for that see `statusItemImage(badged:)`).
    private static func pendingUpdateTitle(_ title: String) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.labelColor
            ]
        )
        text.append(NSAttributedString(
            string: "●",
            attributes: [
                .font: NSFont.systemFont(ofSize: 7),
                .foregroundColor: NSColor.systemRed,
                // Raised to the top right of the text, right against the last character, the position in the
                // sketch.
                .baselineOffset: 5
            ]
        ))
        return text
    }

    /// Menu bar icon: shows a small dot when an update is pending.
    ///
    /// **Must be refreshed separately from the menu item**: the menu item syncs only when the menu is about
    /// to open, while the whole point of this dot is "visible while the menu is closed". So it hangs off the
    /// `settingsCoordinator` change subscription.
    private func refreshStatusItemBadge() {
        statusItem.button?.image = Self.statusItemImage(
            badged: settingsCoordinator.pendingUpdateVersion != nil
        )
    }

    /// Status bar icon. When `badged`, draws a small dot at the top right.
    ///
    /// ⚠️ **The whole image is still a template** (monochrome, inverted automatically by the system for
    /// light/dark and highlight). The dot cannot be red:
    /// a red dot requires `isTemplate = false`, which also loses the system's automatic inversion, and the
    /// icon would smear on a dark menu bar and on the highlight background while the menu is open. So it is
    /// drawn as "punch out a ring first, then fill a solid dot" to separate it from the glyph itself, visible
    /// by shape rather than color.
    private static func statusItemImage(badged: Bool) -> NSImage? {
        let base = NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "rectangle.3.offgrid.fill", accessibilityDescription: ForkBranding.appName)   // fork
        guard let base else { return nil }
        base.isTemplate = true
        guard badged else {
            base.accessibilityDescription = ForkBranding.appName   // fork
            return base
        }

        let size = base.size
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)

            let diameter = max(3.5, size.width * 0.24)
            let dot = NSRect(
                x: rect.maxX - diameter,
                y: rect.maxY - diameter,
                width: diameter,
                height: diameter
            )
            // Punch out a ring around the dot first, then fill it solid; otherwise a monochrome dot on an
            // equally monochrome glyph merges into one blob.
            let moat = dot.insetBy(dx: -1.2, dy: -1.2)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: moat).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = String(localized: "NitiaDock — update available")
        return image
    }

    @objc private func toggleLaunchAtLogin() {
        guard let enable = LaunchAtLoginMenuModel.requestedEnabledValue(afterSelecting: settingsCoordinator.launchAtLoginState) else { return }
        if case .failure(let error) = settingsCoordinator.setLaunchAtLogin(enable) {
            presentError(title: String(localized: "Couldn’t Change Open at Login"), message: error.localizedDescription)
        }
        refreshCheckmarks()
    }

    @objc private func selectTaskbarScreen(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String,
              let selection = TaskbarScreenMenuPresentation.Selection(token: token) else { return }
        switch selection {
        case .followMouse:
            store.setTaskbarScreenPlacement(.followMouse)
        case .allScreens:
            store.setTaskbarScreenPlacement(.allScreens)
        case .allScreensPerDisplay:
            store.setTaskbarScreenPlacement(.allScreensPerDisplay)
        case .screen(let uuid):
            // name is only a display snapshot: connected screens use the deduplicated display name;
            // re-selecting the disconnected screen keeps the old snapshot.
            let name = connectedScreensCache.first(where: { $0.uuid == uuid })?.title
                ?? store.taskbarScreenPlacement.pinnedSelection?.name
                ?? ""
            store.setTaskbarScreenPlacement(.pinned(PinnedScreenSelection(uuid: uuid, name: name)))
        }
    }

    @objc private func selectDockSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let size = DockSize(rawValue: raw) else { return }
        store.setDockSize(size)
        refreshCheckmarks()
    }

    @objc private func toggleShowShelf() {
        store.setShowShelf(!store.showShelf)
        refreshCheckmarks()
    }

    @objc private func toggleReserveSpace() {
        store.setReserveScreenSpace(!store.reserveScreenSpace)
        refreshCheckmarks()
    }

    @objc private func toggleShowDrawer() {
        store.setShowDrawer(!store.showDrawer)
        refreshCheckmarks()
    }

    @objc private func toggleShowTrash() {
        store.setShowTrash(!store.showTrash)
        refreshCheckmarks()
    }

    /// Show app names on hover = the two values of `hoverStyle` (`.standard` shows / `.quiet` does not), not
    /// a separate boolean field. The Settings window version reads and writes it the same way; do not open
    /// another mirror here.
    @objc private func toggleHoverName() {
        store.setHoverStyle(store.hoverStyle.isExpressive ? .quiet : .standard)
        refreshCheckmarks()
    }

    @objc private func toggleWindowLift() {
        store.setWindowLiftEnabled(!store.windowLiftEnabled)
        refreshCheckmarks()
    }

    @objc private func openLoginItemsSettings() {
        settingsCoordinator.openLoginItemsSettings()
    }

    /// Sparkle ships its own full set of result UI, and it guarantees to come to the front for user-initiated
    /// checks, so neither `NSAlert` nor `runModalInForeground` is used here.
    /// Triggered only from "Install vX.Y.Z…": for an update that is ready, `checkForUpdates()` is "continue
    /// installing"; the entry for active checks is in the Settings window (menu dedup, 2026-08-24).
    @objc private func installPendingUpdate() {
        menu.cancelTrackingWithoutAnimation()
        settingsCoordinator.checkForUpdates()
    }

    @objc private func openAccessibilitySettings() {
        guard let url = AccessibilitySettingsLink.url else { return }
        NSWorkspace.shared.open(url)
    }


    /// The only write path for the system Dock. Close the menu first: the write ends with `killall Dock`, and
    /// the menu should not be open while the system Dock restarts; run on the next pass.
    private func scheduleNativeDockWrite(target: Double) {
        menu.cancelTrackingWithoutAnimation()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.settingsCoordinator.applyNativeDock(target: target)
            self.nativeDockSliderView.sync(delay: outcome.resolvedDelay)
            self.nativeDockApplyItem.isHidden = true
            if let error = outcome.error {
                self.presentError(title: String(localized: "Couldn’t Change Dock Settings"), message: error.localizedDescription)
            }
        }
    }

    private func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        Self.runModalInForeground(alert)
    }

    /// NitiaDock is an `.accessory` app (no Dock icon). Such an app calling `runModal()` directly does
    /// **not** bring itself to the front, and the alert lands behind the current frontmost app's windows: the
    /// user clicks a menu item and sees no reaction at all, indistinguishable from "the feature is broken"
    /// (real users reported exactly this as "check for updates does not work").
    /// Any window in front triggers it, which is almost always.
    ///
    /// `AppDelegate` calls `NSApp.activate` before every `runModal()` / panel presentation; only these four
    /// places in the status menu missed it. All alerts go through here, no more individual `runModal()`
    /// calls.
    @discardableResult
    private static func runModalInForeground(_ alert: NSAlert) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    @objc private func showDebugConsole() { onShowDebugConsole() }
    @objc private func exportDebugSnapshot() { onExportDebugSnapshot() }
    @objc private func showSettings() {
        menu.cancelTrackingWithoutAnimation()
        DispatchQueue.main.async { [onShowSettings] in onShowSettings() }
    }
    @objc private func quit() { onQuit() }
}
