import AppKit
import Combine
import QuartzCore
import SwiftUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Must be the **first** stored property: every other store writes defaults inside its own
    /// init, so a snapshot taken one step later can no longer tell a prior install apart.
    private let installLineage = ForkBundleMigration.migrateThenCaptureLineage()   // fork: was InstallLineage.capture()
    private let inventoryLog = WindowInventoryAnomalyLog()
    /// Single source of the present-screens table: the window inventory (ownership key)
    /// and the taskbar projection (multi-screen ④ filters by screen) both read it.
    let displayTopologyStore = DisplayTopologyStore(initialSnapshot: DisplayIdentity.topologySnapshot())
    private(set) lazy var runtime = AppRuntime(
        inventoryLog: inventoryLog,
        displayTableProvider: { [displayTopologyStore] in displayTopologyStore.table },
        isAccessibilityTrusted: { [weak self] in self?.cachedAccessibilityTrusted ?? false }
    )
    let drawerStore = DrawerStore()
    let messagingStore = MessagingAppStore()
    let badgeStore = BadgeStore()
    let keptAppStore = KeptAppStore()
    lazy var stripOrderStore = StripOrderStore(
        keptIDsProvider: { [keptAppStore] in Set(keptAppStore.bundleIDs) },
        stableKeptOrderProvider: { [keptAppStore, messagingStore] in
            keptAppStore.bundleIDs.filter { !messagingStore.contains($0) }
        },
        inventoryLog: inventoryLog
    )
    let drawerOrderStore = DrawerOrderStore()
    let settingsStore = AppSettingsStore()
    let pinnedFolderStore = PinnedFolderStore()
    let shelfStore = ShelfStore()
    let runningApplicationStore = RunningApplicationStore()
    private(set) lazy var appMembershipController = AppMembershipController(
        keptAppStore: keptAppStore,
        drawerStore: drawerStore,
        messagingStore: messagingStore
    )
    /// lazy: sortOrderProvider references pinnedFolderStore (the cover
    /// follows the first file in that folder's current sort order).
    private(set) lazy var folderCoverStore = PinnedFolderCoverStore(
        sortOrderProvider: { [pinnedFolderStore] path in pinnedFolderStore.sortOrder(for: path) }
    )
    private var panelCoordinator: TaskbarScreenOrchestrator?
    /// fork: subscriptions owned by `startForkBindings()` (AppDelegate+Fork.swift).
    var forkSubscriptions: Set<AnyCancellable> = []
    var forkReservedSpaceController: ForkReservedSpaceController?
    private var windowLiftAvoidanceController: WindowLiftAvoidanceController?
    private lazy var launchAtLoginService = LaunchAtLoginService()
    private lazy var nativeDockPreferencesService = NativeDockPreferencesService()
    private let updateService = SparkleUpdateService()
    private lazy var settingsCoordinator = SettingsCoordinator(
        store: settingsStore,
        launchAtLoginService: launchAtLoginService,
        nativeDockPreferencesService: nativeDockPreferencesService,
        updateService: updateService,
        // The real registration entry point for rebinding. A temporary copy has no monitor
        // (and cannot reach the settings window), so the fallback reports failure.
        hotKeyRegistrar: { [weak self] shortcut in
            self?.edgeToggleHotKey?.update(shortcut: shortcut) ?? .monitorUnavailable
        }
    )
    private lazy var settingsWindowController = SettingsWindowController(
        store: settingsStore,
        coordinator: settingsCoordinator,
        // Goes straight to showWelcomeWindow(), not through presentWelcomeGuideIfNeeded(): for
        // existing users with hasSeenWelcome set that path always skips silently, and existing
        // users are this entry point's entire audience. The entry point moved from the status bar
        // menu to the settings "General" page on 2026-09-01; going straight through is unchanged.
        onShowWelcomeGuide: { [weak self] in self?.showWelcomeWindow() }
    )
    /// Global shortcut for the always-shown toggle. The callback only flips the setting (via
    /// settingsStore), not through panelCoordinator: the latter is nil until the permission
    /// guide completes, while settingsStore exists from AppDelegate's construction.
    private var edgeToggleHotKey: GlobalHotKeyMonitor?
    private var terminationTask: Task<Void, Never>?
    private var debugWindow: NSWindow?
    /// Exists only when `DOCK_HOVER_TRACE=1`, see `startMainLoopStallProbeIfTracing`.
    private var mainLoopStallProbe: Timer?
    private var permissionWindow: NSWindow?
    private var permissionHostingView: NSHostingView<PermissionOnboardingWindowContent>?
    private var welcomeWindow: NSWindow?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var messagingAutoRegisterSubscription: AnyCancellable?
    private var badgeContextSubscription: AnyCancellable?
    private var windowLiftSettingSubscription: AnyCancellable?
    private var trashSettingSubscription: AnyCancellable?
    /// Global mouse wheel inversion. An active tap needs Accessibility permission,
    /// so it is tied to the taskbar runtime (created in startTaskbarRuntime, torn
    /// down on suspend/terminate), the same lifecycle as the fullscreen tap.
    private let permissionService = PermissionService()
    private var installLocation: AppInstallLocation = .other
    private var permissionCoordinator: PermissionRecoveryCoordinator?
    private var permissionWatchdogTimer: Timer?
    private var permissionWatchdogGate = PermissionWatchdogGate()
    private let permissionProbeQueue = DispatchQueue(label: "no.thilip.nitiadock.permission-probe", qos: .utility)
    private var cachedAccessibilityTrusted = false
    private var hasStartedApp = false
    private let permissionLogger = Logger(subsystem: "no.thilip.nitiadock", category: "permissions")
    private lazy var statusMenuController = StatusMenuController(
        store: settingsStore,
        settingsCoordinator: settingsCoordinator,
        isAccessibilityTrusted: { [weak self] in self?.cachedAccessibilityTrusted ?? false },
        onShowDebugConsole: { [weak self] in self?.showDebugConsole() },
        onExportDebugSnapshot: { [weak self] in self?.exportDebugSnapshot() },
        onShowSettings: { [weak self] in self?.openSettings(nil) },
        onMenuVisibilityChanged: { [weak self] isOpen in
            self?.panelCoordinator?.setTaskbarMenuOpen(isOpen)
        },
        onQuit: { NSApp.terminate(nil) },
        hotKeyGlyphs: { [weak self] in
            self?.edgeToggleHotKey?.shortcut.displayGlyphs
                ?? GlobalHotKeyShortcut.edgeAutoHideMode.displayGlyphs
        },
        isToggleHotKeyRegistered: { [weak self] in self?.edgeToggleHotKey?.isRegistered ?? false },
        connectedScreens: { DisplayIdentity.connectedScreenOptions() }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Line-buffer stdout: when launched from a command line/background, print() output to
        // a file is block-buffered by default, and logs reach disk only when the buffer fills.
        // With line buffering every print is written at once, so logs can be read live.
        setvbuf(stdout, nil, _IOLBF, 0)

        startMainLoopStallProbeIfTracing()

        // First-install timestamp: **deliberately before all branch decisions**; the move guide,
        // permission guide and normal launch must all record it. Users on all three branches have
        // really run NitiaDock, and none should be missed when existing users are identified for a
        // future move to paid. Written once and never overwritten; see `InstallationRecord` for why.
        //
        // Install lineage was captured before any store was constructed; the first-launch stamp
        // still lands ahead of every runtime branch.
        let isFreshInstall = installLineage == .pristine
        InstallationRecord.recordFirstLaunchIfNeeded()
        // A fresh install seeds maximize lift avoidance on; existing users stay off
        // (it rewrites other apps' window sizes and must not be turned on silently by
        // an upgrade). See `AppSettingsStore.seedWindowLiftEnabledForFreshInstall`.
        if isFreshInstall {
            settingsStore.seedWindowLiftEnabledForFreshInstall(lineage: installLineage)
            settingsStore.armTaskbarPerDisplaySeedForFreshInstall(lineage: installLineage)
        }
        // fork: before any panel or projection reads the stores.
        startForkBindings()

        // **Pin light appearance unconditionally; this line cannot be dropped.** The product is
        // light-only (dark mode was removed on 2026-08-16), and `NSVisualEffectView` and Liquid
        // Glass follow **the window's effectiveAppearance**, not the SwiftUI environment.
        // Without the pin, materials render dark when the system is dark, while
        // `DockThemeTokens` has only light values: light-mode text on a dark backing, a visible
        // mismatch (measured on the same screen and wallpaper: backing luminance 37.7 vs 143.2).
        //
        // Pinning on `NSApp` alone is enough: no panel or window overrides its own `appearance`, so they
        // all fall back to this one, **including those created later on demand**: the drawer, both popups,
        // the tooltip, the drag carrier, and the status bar and context menus. The status bar icon is a
        // template image, still tinted by the menu bar per system appearance, and is unaffected.
        //
        // Placed first: the first window of all three branches (move guide,
        // permission guide, normal launch) must have the right appearance.
        NSApp.appearance = NSAppearance(named: .aqua)

        // Location classification must come **before** taking over other instances and registering the
        // hotkey. When run by double-clicking in a mounted disk image, a temporary copy that executed
        // terminateOtherInstances() would kill the /Applications instance the user is running and then
        // show only a move guide; grabbing the global hotkey would also break the normal instance's ⌥⇧⌘D.
        let location = AppInstallLocation(
            bundleURL: Bundle.main.bundleURL,
            isReadOnlyVolume: { [permissionService] in permissionService.isReadOnlyVolume($0) }
        )
        installLocation = location
        let trusted = permissionService.hasRequiredPermissions()
        cachedAccessibilityTrusted = trusted
        logPermissionLaunch(installLocation: location, isTrusted: trusted)

        if !location.isTransient {
            terminateOtherInstances()

            // Register the hotkey before building the status menu: menu construction reads
            // the registration status to decide whether to show the shortcut hint. Carbon
            // hotkeys do not depend on Accessibility permission, so no need to wait for the
            // permission guide branch. Use the stored combination if the user customized
            // it; bad data already fell back to nil (= default ⌥⇧⌘D) when the store loaded.
            let shortcut = settingsStore.edgeToggleShortcut.map(GlobalHotKeyShortcut.init(stored:))
                ?? .edgeAutoHideMode
            let hotKey = GlobalHotKeyMonitor(shortcut: shortcut) { [weak self] in
                self?.settingsStore.toggleEdgeAutoHideMode()
            }
            edgeToggleHotKey = hotKey
            let hotKeyStatus = hotKey.start()
            if hotKeyStatus != .registered {
                Logger(subsystem: "no.thilip.nitiadock", category: "hotkey")
                    .warning("Failed to register the always-shown toggle global shortcut: \(String(describing: hotKeyStatus), privacy: .public), not retrying this launch")
            }

            _ = statusMenuController

            // Auto-update runs only on a normally installed copy. A temporary copy mounted
            // in a DMG has no reason to update itself (it is gone on unmount), the same
            // reason it gets no global hotkey and requests no system permissions above.
            if ForkDefaults.updatesEnabled { updateService.start() }
        }

        let coordinator = PermissionRecoveryCoordinator(
            handler: self,
            permissionService: permissionService,
            installLocation: location
        )
        permissionCoordinator = coordinator
        coordinator.launched(trusted: trusted)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Recheck immediately when the user switches back from
        // System Settings, without waiting for the next poll.
        permissionCoordinator?.applicationDidBecomeActive()
        if !installLocation.isTransient {
            Task { @MainActor [weak self] in
                _ = await self?.settingsCoordinator.refreshLaunchAtLoginState()
            }
        }
    }

    private func logPermissionLaunch(installLocation: AppInstallLocation, isTrusted: Bool) {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        permissionLogger.info("""
            permission launch version=\(version, privacy: .public) \
            build=\(build, privacy: .public) \
            location=\(installLocation.rawValue, privacy: .public) \
            trusted=\(isTrusted, privacy: .public) \
            bundlePath=\(Bundle.main.bundleURL.path, privacy: .private(mask: .hash))
            """)
    }

    /// Another package with the same bundle id (the release build in `/Applications` vs the
    /// dev build in the build directory) can run at the same time, putting two identical
    /// taskbars on screen with no way to tell which version is under test. On 2026-07-21 this
    /// got a fix that was never actually verified judged "not working" and fully reverted.
    ///
    /// Policy: "the later launch takes over", the new instance kicks out the old one.
    /// The reverse (the new one quits) would block verification builds during
    /// development and contradict `Scripts/build_and_run.sh`, which already does pkill
    /// before launch. Uses a polite `terminate()` rather than a hard kill so the old
    /// instance's `stopAndRestore` puts lifted windows back; it is force-terminated only
    /// if it does not quit in time, so the original "two taskbars" symptom cannot recur.
    private func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != myPID && !$0.isTerminated }
        guard !others.isEmpty else { return }

        let logger = Logger(subsystem: "no.thilip.nitiadock", category: "instance")
        for app in others {
            logger.warning("""
                Found another NitiaDock instance, terminating it: pid=\(app.processIdentifier, privacy: .public) \
                path=\(app.bundleURL?.path ?? "(unknown)", privacy: .private)
                """)
            app.terminate()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            for app in others where !app.isTerminated {
                logger.error("Old instance pid=\(app.processIdentifier, privacy: .public) did not quit within 3 seconds, force terminating")
                app.forceTerminate()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // The event loop keeps running during the shutdown wait (stopAndRestore): cut
        // hotkey input first so the setting cannot keep toggling, and have the coordinator
        // cancel in-flight recovery tasks. Setting the phase alone does not stop a Task
        // already inside an await, which would launch a new instance after quitting.
        edgeToggleHotKey?.stop()
        permissionCoordinator?.terminationRequested()

        guard let controller = windowLiftAvoidanceController else { return .terminateNow }
        // Without permission AX cannot move windows, so waiting for stopAndRestore would be pointless.
        guard permissionService.hasRequiredPermissions() else { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }

        terminationTask = Task { @MainActor [weak self] in
            await controller.stopAndRestore()
            self?.terminationTask = nil
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        trashSettingSubscription = nil
        TrashStateStore.shared.stop()
        edgeToggleHotKey?.stop()
        DocumentUsageStore.shared.stop()
        permissionCoordinator?.terminationRequested()
        windowLiftAvoidanceController?.stop()
        // WindowServer reclaims the private Space once the process
        // dies; this only avoids leaving a junk Space behind.
        panelCoordinator?.overlaySpaceHost?.tearDown()
        runtime.stop()
    }

    // MARK: - First-run welcome guide

    /// One-off first-run guide: suggests hiding the system Dock.
    ///
    /// Called once, at the end of `startTaskbarRuntime()`, i.e. the moment "permission granted,
    /// panels built, taskbar actually running". A temporary copy (the one run by double-clicking in
    /// a DMG) never gets here: in `PermissionRecoveryMachine` it only has the `showGuide` effect.
    /// That is correct: the copy is gone on unmount and should not be configuring the system.
    private func presentWelcomeGuideIfNeeded() {
        // Gate on the two conditions that need no I/O first,
        // which saves the async read on almost every launch.
        guard !settingsStore.hasSeenWelcome else { return }

        let canWrite = nativeDockPreferencesService.isAvailable
        guard canWrite else {
            _ = WelcomeGuideDecision.evaluate(
                hasSeenWelcome: false,
                canWriteDockPreferences: false,
                dockAutohideEnabled: nil
            )
            settingsStore.setHasSeenWelcome(true)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let state = await self.nativeDockPreferencesService.currentAutohideState()
            // The user may have seen/changed it elsewhere during this await, so re-read the flag.
            switch WelcomeGuideDecision.evaluate(
                hasSeenWelcome: self.settingsStore.hasSeenWelcome,
                canWriteDockPreferences: true,
                dockAutohideEnabled: state?.enabled
            ) {
            case .present:
                self.showWelcomeWindow()
            case .skipAndMarkSeen:
                self.settingsStore.setHasSeenWelcome(true)
            case .skipWithoutMarking:
                break
            }
        }
    }

    private func showWelcomeWindow() {
        if let welcomeWindow {
            welcomeWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let content = WelcomeGuideWindowContent(
            onApply: { [weak self] selection in self?.applyWelcomeSelection(selection) },
            onDismiss: { [weak self] in self?.dismissWelcomeGuide() }
        )
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: WelcomeGuideView.contentWidth, height: 320),
            // Unlike the permission guide, this window is **closable**: without permission the app
            // is unusable, so closing that window is pointless; this one is only a suggestion, and
            // the user may close it directly (closing equals "Not Now", see windowWillClose).
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = ForkBranding.appName   // fork: was a raw upstream literal
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.delegate = self
        welcomeWindow = window

        // Height is measured as in the permission guide: the root view is wrapped in a
        // ScrollView, so a one-off probe measures the natural height without scrolling.
        let probe = NSHostingView(rootView: WelcomeGuideView(onApply: { _ in }, onDismiss: {}))
        probe.setFrameSize(NSSize(width: WelcomeGuideView.contentWidth, height: 0))
        probe.layoutSubtreeIfNeeded()
        let available = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        window.setContentSize(NSSize(
            width: WelcomeGuideView.contentWidth,
            height: max(200, min(probe.fittingSize.height, available - 80))
        ))

        window.center()
        window.makeKeyAndOrderFront(nil)
        // NitiaDock is an accessory app at this point; without an explicit activate the window
        // would sit behind the frontmost app, the same trap as the 2026-07-29 "update check
        // appears to do nothing" case. Do **not** switch to .regular while at it: that would
        // put a NitiaDock icon in the Dock, contradicting exactly what this window is about.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// "Apply recommended settings": writes system Dock preferences for the items the user checked.
    /// The hide option is auto-hide + never wake (the recommended setting, decided 2026-08-20).
    ///
    /// Goes through `applyNativeDock(recommendations:)`, the only write entry point, so the
    /// four-quadrant read-back and mirror sync come for free; do not start a separate defaults
    /// write here. The three items are merged into one `killall Dock`, so the screen flashes once.
    private func applyWelcomeSelection(_ selection: WelcomeGuideSelection) {
        settingsStore.setHasSeenWelcome(true)
        closeWelcomeWindow()

        let recommendations = selection.recommendations(hideDelay: AppSettingsStore.neverWakeDelay)
        // The button is disabled when nothing is checked; this is a fallback: write
        // nothing, and so do not restart the Dock and flash the screen for nothing.
        guard !recommendations.isEmpty else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.settingsCoordinator.applyNativeDock(
                recommendations: recommendations
            )
            guard let error = outcome.error else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Couldn’t Change Dock Settings")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: String(localized: "OK"))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    /// "Not Now", and closing the window directly. **Still recorded as seen**, no more nagging;
    /// anyone who wants to change it uses the system Dock slider in the status bar menu.
    private func dismissWelcomeGuide() {
        settingsStore.setHasSeenWelcome(true)
        closeWelcomeWindow()
    }

    private func closeWelcomeWindow() {
        guard let window = welcomeWindow else { return }
        welcomeWindow = nil
        window.delegate = nil
        window.orderOut(nil)
        window.close()
    }

    /// Guide window. Copy length varies a lot with state (nearly double with
    /// the troubleshooting section expanded), so the width is fixed, the height
    /// follows the content, capped at the current screen's visible height.
    private func showPermissionWindow() {
        guard let coordinator = permissionCoordinator else { return }
        if let permissionWindow {
            resizePermissionWindowToFit()
            permissionWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingView(rootView: PermissionOnboardingWindowContent(coordinator: coordinator))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: PermissionOnboardingView.contentWidth, height: 260),
            styleMask: [.titled, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = ForkBranding.appName   // fork: was a raw upstream literal
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        permissionWindow = window
        permissionHostingView = hosting
        resizePermissionWindowToFit()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func resizePermissionWindowToFit() {
        guard let window = permissionWindow, let coordinator = permissionCoordinator else { return }

        // Measure the "natural height without scrolling" with a one-off probe: the real root view
        // is wrapped in a ScrollView, whose own fittingSize cannot tell how tall the content is.
        let probe = NSHostingView(rootView: PermissionOnboardingView(coordinator: coordinator))
        probe.setFrameSize(NSSize(width: PermissionOnboardingView.contentWidth, height: 0))
        probe.layoutSubtreeIfNeeded()
        let natural = probe.fittingSize.height

        let available = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let height = max(200, min(natural, available - 80))
        let size = NSSize(width: PermissionOnboardingView.contentWidth, height: height)
        guard window.contentView?.frame.size != size else { return }

        let before = window.frame
        window.setContentSize(size)
        // Keep the visual center fixed so the window does not jump down when the copy grows.
        let after = window.frame
        window.setFrameOrigin(NSPoint(
            x: before.midX - after.width / 2,
            y: before.midY - after.height / 2
        ))
    }

    private func closePermissionWindow() {
        permissionWindow?.orderOut(nil)
        permissionWindow?.close()
        permissionWindow = nil
        permissionHostingView = nil
    }

    private func startTaskbarRuntime() {
        appMembershipController.reconcileInvalidMemberships()
        runningApplicationStore.start()
        runtime.start()

        // Auto tier of the messaging list: register an app only when it both matches the
        // whitelist / social-networking category **and** currently has an identifiable main
        // window, then seed kept on first registration (default-keep). Kept no longer excludes
        // messaging, so there is no kept filter.
        //
        // The window snapshot is combined in because the capability gate needs titles: the
        // process store alone cannot tell whether the zone can represent the app. Registration
        // is once-and-for-all (see `MessagingAppStore.autoRegister`), so the "identifiable right
        // now" reading is only ever consumed for apps not yet in the list; existing members are
        // never re-tested and therefore never flap out of the zone.
        messagingAutoRegisterSubscription = runningApplicationStore.$runningBundleIDs
            .combineLatest(runtime.$snapshot)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running, snapshot in
                guard let self else { return }
                let identifiable = MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
                    windows: StripItem.items(from: snapshot).map {
                        .init(bundleID: $0.bundleIdentifier ?? "",
                              title: $0.title,
                              isAppLevelFallback: $0.isAppLevelFallback)
                    },
                    titleMatchesAppName: { title, bundleID in
                        AppDisplayNameResolver.titleMatchesAppName(title, bundleID: bundleID)
                    }
                )
                self.appMembershipController.autoRegisterMessaging(
                    runningBundleIDs: running,
                    mainWindowIdentifiableBundleIDs: identifiable
                )
            }

        // Badge read set = messaging-app **identity** ∩ running − drawer (since 2026-08-23 zone
        // membership is no longer required: for single-window apps like Messages / Slack that cannot
        // enter the zone, the red dot is drawn on their card in the regular zone). Any change to the
        // list or the running set is pushed to BadgeStore: with an empty readable set it does zero AX
        // traffic per tick; a set change triggers a re-walk of the Dock tree, which is how "a messaging
        // app just launched and its new tile gets a badge" is caught within ~1s. The subscription
        // precedes badgeStore.start(), so the context is in place before the first read (@Published
        // emits the current value on subscribe). `isMessagingApp` reads the store back: receive(on:)
        // dispatches asynchronously here, publishing is long done, and the new value is read.
        badgeContextSubscription = Publishers.CombineLatest3(
            messagingStore.$bundleIDs,
            drawerStore.$bundleIDs,
            runningApplicationStore.$runningBundleIDs
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _, drawer, running in
            guard let self else { return }
            self.badgeStore.updateMessagingContext(
                visibleMessagingIDs: AppMembershipProjection.badgeEligibleIDs(
                    isMessagingApp: { self.messagingStore.isMessagingApp($0) },
                    drawerIDs: drawer,
                    runningIDs: running
                ),
                runningBundleIDs: running
            )
        }

        let coordinator = TaskbarScreenOrchestrator(
            runtime: runtime,
            drawerStore: drawerStore,
            messagingStore: messagingStore,
            badgeStore: badgeStore,
            stripOrderStore: stripOrderStore,
            drawerOrderStore: drawerOrderStore,
            settingsStore: settingsStore,
            pinnedFolderStore: pinnedFolderStore,
            folderCoverStore: folderCoverStore,
            shelfStore: shelfStore,
            keptAppStore: keptAppStore,
            runningApplicationStore: runningApplicationStore,
            appMembershipController: appMembershipController,
            displayTopologyStore: displayTopologyStore
        )
        panelCoordinator = coordinator
        runtime.onToggleDrawer = { [weak coordinator] in coordinator?.toggleDrawer() }
        coordinator.onAddFolder = { [weak self] in self?.presentAddPinnedFolderPanel() }
        // Right-clicking the taskbar / capsule opens the NitiaDock menu. Reaching here means
        // permission is granted and this is not a temporary copy, so the status bar menu has
        // already been built (the non-temporary branch of `applicationDidFinishLaunching`),
        // and there is no "status bar icon conjured out of nowhere" problem.
        coordinator.onRequestTaskbarMenu = { [weak self] event, view in
            self?.statusMenuController.popUpFromTaskbar(with: event, in: view)
        }
        coordinator.start()
        let windowLiftAvoidanceController = WindowLiftAvoidanceController(host: coordinator, journalDefaults: .standard)
        self.windowLiftAvoidanceController = windowLiftAvoidanceController
        // Windows a crashed or force-quit run left shrunk go back to their own size first.
        windowLiftAvoidanceController.restoreWindowsLeftByPreviousRun()
        // Lift avoidance is off by default, so seed the persisted switch state first; start()
        // honors the flag itself and returns as a no-op when unchecked, so neither timer (the
        // global scan at 1 Hz idle / 5 Hz in session, and the 20 Hz tracked probe) starts.
        windowLiftAvoidanceController.setEnabledBySetting(settingsStore.windowLiftEnabled)
        windowLiftAvoidanceController.start()
        startForkReservedSpace(host: coordinator)   // fork
        // The sink uses the new value from the closure argument: @Published publishes before
        // the assignment completes, so reading the store back now gives the old value.
        // Uses self?.windowLiftAvoidanceController rather than capturing the
        // controller strongly: the permission recovery path sets it to nil.
        windowLiftSettingSubscription = settingsStore.$windowLiftEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.windowLiftAvoidanceController?.setEnabledBySetting(enabled)
            }
        // Count ledger for most-used files: directory watching +
        // resampling on activation are both tied to the taskbar runtime.
        DocumentUsageStore.shared.start()
        TrashStateStore.shared.setEnabled(settingsStore.showTrash)
        TrashStateStore.shared.start(revealOpenedWindow: TrashStateStore.revealTrashWindow(runtime: runtime))
        trashSettingSubscription = settingsStore.$showTrash
            .removeDuplicates()
            .sink { enabled in TrashStateStore.shared.setEnabled(enabled) }
        badgeStore.start()
        // Suggesting "how to configure it" only makes sense once the taskbar is actually up.
        // It is here rather than at launch because the user must first see what the taskbar
        // looks like for "both sit at the bottom edge and cover each other" to mean anything.
        presentWelcomeGuideIfNeeded()
        // Probe result (2026-07-06, phase 0 probe 3): a Finder window's AX attribute list includes AXDocument
        // but it never has a value (kAXErrorNoValue), and AXProxy/AXTitleUIElement give only the folder name,
        // no path. So "drag a taskbar Finder window icon to pin the folder" is not feasible and was cut as
        // planned; dropping into the pinned zone accepts real file URLs only (system drag and drop).
    }

    /// Entry point for "Add Pinned Folder…" on the folder chip / shelf context menu.
    /// An accessory app must activate first, or NSOpenPanel does not come to the front.
    func presentAddPinnedFolderPanel() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Pin")
        panel.message = String(localized: "Choose a folder to pin to the taskbar")
        if panel.runModal() == .OK {
            for url in panel.urls { pinnedFolderStore.add(url.path) }
        }
    }

    /// The settings window presupposes "the taskbar is running normally".
    ///
    /// For a temporary copy, before permission is granted, and in the recovery state after
    /// permission loss, the only thing the user should do is deal with the guide window.
    /// Opening a full settings surface then would only cover the guide window, with every
    /// switch acting on a taskbar that never started (exactly the contradictory screen a
    /// user reported on 2026-08-03). So always bring the guide window to the front instead.
    @objc func openSettings(_ sender: Any?) {
        guard !installLocation.isTransient,
              hasStartedApp,
              permissionService.hasRequiredPermissions() else {
            showPermissionWindow()
            return
        }
        settingsWindowController.present()
    }

    func exportDebugSnapshot() {
        runtime.exportDebugSnapshot()
    }

    func showDebugConsole() {
        if let existing = debugWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Taskbar Debug Console"
        window.contentView = NSHostingView(
            rootView: DebugConsoleView()
                .environmentObject(runtime)
                .environmentObject(runtime.debugState)
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        debugWindow = window
    }

    /// Main-thread stall probe: installed only when `DOCK_HOVER_TRACE=1` (`HoverTrace.isEnabled`
    /// is a constant; when off the timer is never created, so it costs nothing in normal use).
    ///
    /// Every 8ms, in `.common`. **It must be `.common`**, or it would stop during menus/drags,
    /// which is exactly the period most worth measuring.
    private func startMainLoopStallProbeIfTracing() {
        guard HoverTrace.isEnabled else { return }
        // The timer callback is a Sendable closure and cannot mutate a
        // captured var directly; put it in a box used on the main thread only.
        let clock = StallProbeClock(expected: CACurrentMediaTime() + 0.008)
        let timer = Timer(timeInterval: 0.008, repeats: true) { _ in
            let now = CACurrentMediaTime()
            HoverTrace.mainLoopStall(lateMs: (now - clock.expected) * 1000)
            clock.expected = now + 0.008
        }
        RunLoop.main.add(timer, forMode: .common)
        mainLoopStallProbe = timer
    }

}

// MARK: - Permission state machine side effects

extension AppDelegate: PermissionEffectHandler {
    func startApp() {
        guard !hasStartedApp else { return }
        hasStartedApp = true
        startTaskbarRuntime()
    }

    func setActivationPolicy(_ policy: PermissionActivationPolicy) {
        switch policy {
        case .accessory:
            NSApp.setActivationPolicy(.accessory)
        case .regular:
            // Without permission the taskbar creates no panels, and staying accessory
            // would leave the user with only a possibly unnoticed status bar icon; use
            // the regular app policy first to bring the guide window to the front.
            NSApp.setActivationPolicy(.regular)
        }
    }

    func showGuideWindow() { showPermissionWindow() }
    func updateGuideWindow() { resizePermissionWindowToFit() }
    func closeGuideWindow() { closePermissionWindow() }

    func openAccessibilitySettings() {
        guard let url = AccessibilitySettingsLink.url else { return }
        NSWorkspace.shared.open(url)
    }

    func openApplicationsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
    }

    func releaseHotKey() { edgeToggleHotKey?.stop() }

    func registerHotKey() { _ = edgeToggleHotKey?.start() }

    func terminateSelf() { NSApp.terminate(nil) }

    // MARK: Runtime recovery

    /// One sample every 5 seconds. Debounce is decided in the
    /// pure `PermissionLossDetector`; this only feeds it data.
    /// This is **not** what protects window snapshots: `WindowLiftAvoidanceController`
    /// self-checks in its own polling, still at 0.2s with sessions/pending restores,
    /// dropping to 1s only when idle with no snapshots.
    func startWatchdog() {
        stopWatchdog()
        permissionWatchdogGate.start()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.schedulePermissionProbe()
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        permissionWatchdogTimer = timer
    }

    func stopWatchdog() {
        permissionWatchdogTimer?.invalidate()
        permissionWatchdogTimer = nil
        permissionWatchdogGate.stop()
    }

    private func schedulePermissionProbe() {
        guard let generation = permissionWatchdogGate.beginProbe() else { return }
        let permissionService = permissionService
        permissionProbeQueue.async { [weak self] in
            let trusted = permissionService.hasRequiredPermissions()
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.permissionWatchdogGate.completeProbe(generation: generation) else { return }
                self.cachedAccessibilityTrusted = trusted
                self.permissionCoordinator?.sampleTrust(trusted)
            }
        }
    }

    func freezeLiftSnapshots() {
        windowLiftAvoidanceController?.beginPermissionUncertainty()
    }

    func unfreezeLiftSnapshots() {
        windowLiftAvoidanceController?.endPermissionUncertainty()
    }

    func suspendPanelsAndStores() {
        trashSettingSubscription = nil
        TrashStateStore.shared.stop()
        // Close the settings window too: once permission is lost the whole
        // taskbar is torn down, and a window for changing the taskbar's look is
        // pointless and would cover the recovery guide that appears right after.
        settingsWindowController.close()
        // Same for the welcome guide, and more glaring: the taskbar is gone,
        // yet a window teaching how to configure it is still on screen.
        closeWelcomeWindow()
        messagingAutoRegisterSubscription?.cancel()
        messagingAutoRegisterSubscription = nil
        badgeContextSubscription?.cancel()
        badgeContextSubscription = nil
        runtime.onToggleDrawer = nil
        DocumentUsageStore.shared.stop()
        panelCoordinator?.suspendAndRelease()
        panelCoordinator = nil
        badgeStore.stop()
        runtime.stop()
        runningApplicationStore.stop()
    }

    /// Permission just returned, so AX can move windows again; the whole
    /// recovery chain defers the restore to this moment for that reason.
    func restoreLiftedWindows(episode: UInt64) async {
        await windowLiftAvoidanceController?.restoreAndStopForPermissionRecovery()
        windowLiftAvoidanceController = nil
    }

    func launchNewInstance(episode: UInt64) async -> Result<Void, Error> {
        let configuration = NSWorkspace.OpenConfiguration()
        // Creating a second instance here is **deliberate**: the new
        // instance's terminateOtherInstances() will close this one.
        // Not the same as the "no open -n in build_and_run.sh" guardrail: that one
        // forbids the build script from launching another copy without waiting for
        // the old process to exit, which produces two identical taskbars.
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        let url = Bundle.main.bundleURL

        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                // This completion is called on a concurrent queue. Only resume here;
                // later work on the state machine / hotkey / UI happens in the coordinator's @MainActor Task.
                if let error {
                    continuation.resume(returning: .failure(error))
                } else {
                    continuation.resume(returning: .success(()))
                }
            }
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    /// The user closing the welcome guide directly equals "Not Now". **It must still be recorded as seen**,
    /// or it would pop up again on the next launch after each close.
    ///
    /// The programmatic close path (`closeWelcomeWindow()`) never gets here: it first sets `welcomeWindow`
    /// to nil and removes the delegate, and only then calls `close()`. So this callback only means "the
    /// user closed it" and never double-marks with `applyWelcomeSelection(_:)` / `dismissWelcomeGuide()`.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === welcomeWindow else { return }
        welcomeWindow = nil
        window.delegate = nil
        settingsStore.setHasSeenWelcome(true)
    }
}

/// Clock for the main-loop stall probe (read and written only in the main-thread
/// timer callback; `@unchecked` because the Timer closure requires Sendable).
private final class StallProbeClock: @unchecked Sendable {
    var expected: CFTimeInterval
    init(expected: CFTimeInterval) { self.expected = expected }
}
