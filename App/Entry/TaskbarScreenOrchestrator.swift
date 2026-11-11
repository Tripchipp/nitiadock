import AppKit
import Combine
import Foundation
import os

/// Multi-display taskbar orchestration layer (multi-display routes ③④, 2026-09-02).
///
/// **One `PanelCoordinator` = one complete taskbar on one display** (bar / backplate / capsule / drawer /
/// popup / bubble, visibility state machine, edge auto-hide, fullscreen hold). Under ①② there is exactly
/// one unit and it follows the setting; under ③④ each connected display gets one `.fixed` unit, whose
/// behavior is the already accepted "pinned to a display" mode. This layer only holds what **breaks if
/// duplicated**: the single fullscreen-intent tap, the single set of mouse-move monitors, the single drag
/// controller, the merged badge gating, and the lifecycle that builds / tears down units per display set.
///
/// Caches no screen coordinates (a panel that moves while its cache stays behind is the generic
/// shape of multi-display bugs); they are always derived from the unit's panel coordinates on demand.
@MainActor
final class TaskbarScreenOrchestrator: NSObject, WindowLiftAvoidanceHost {
    struct Unit {
        /// nil = the single unit that follows the setting (①②); otherwise the display UUID this unit is
        /// pinned to (③④).
        let key: String?
        let coordinator: PanelCoordinator
    }

    private(set) var units: [Unit] = []
    let dragController: DragController
    /// Private Space host for the resident panels: one per process (two displays can share one Space;
    /// measured: each panel only shows on its own display).
    let overlaySpaceHost = OverlaySpaceHost.make()

    private let runtime: AppRuntime
    private let drawerStore: DrawerStore
    private let messagingStore: MessagingAppStore
    private let badgeStore: BadgeStore
    private let stripOrderStore: StripOrderStore
    private let drawerOrderStore: DrawerOrderStore
    private let settingsStore: AppSettingsStore
    private let pinnedFolderStore: PinnedFolderStore
    private let folderCoverStore: PinnedFolderCoverStore
    private let shelfStore: ShelfStore
    private let keptAppStore: KeptAppStore
    private let runningApplicationStore: RunningApplicationStore
    private let appMembershipController: AppMembershipController
    private let displayTopologyStore: DisplayTopologyStore
    private let topologySnapshotProvider: @MainActor () -> ScreenTopologySnapshot
    private let seedRetryScheduler: TaskbarPerDisplaySeedController.ScheduleAfter
    private let logger = Logger(subsystem: "no.thilip.nitiadock", category: "taskbar-screens")

    var onAddFolder: () -> Void = {} {
        didSet { units.forEach { $0.coordinator.onAddFolder = onAddFolder } }
    }
    /// fork: any unit's bar was shown or hidden (auto-hide, full screen, permission).
    var onForkUnitVisibilityChanged: (() -> Void)?
    var onRequestTaskbarMenu: ((NSEvent, NSView) -> Void)? {
        didSet { units.forEach { $0.coordinator.onRequestTaskbarMenu = onRequestTaskbarMenu } }
    }

    private var started = false
    private var isSuspended = false
    private var placementSubscription: AnyCancellable?
    private var fullscreenIntentEnabledSubscription: AnyCancellable?
    private var fullscreenIntentMonitor: FullscreenIntentMonitor?
    private var perDisplaySeedController: TaskbarPerDisplaySeedController?

    // MARK: Mouse-move monitors (lifted up from PanelCoordinator, semantics kept verbatim)
    private var hoverLocalMouseMonitor: Any?
    private var hoverGlobalMouseMonitor: Any?
    private var hoverPollThrottle = HoverPollThrottle(minInterval: 1.0 / 30.0)
    /// Menu tracking depth (submenus nest), 0 = no menu is being tracked.
    private var menuTrackingDepth = 0
    /// Bottom-edge probing while a menu is open (2026-09-02: after adjusting a slider in the status bar menu
    /// without closing it, the mouse at the bottom edge could not wake the bar).
    /// The monitors are removed so menus don't feel sticky: any global event monitor slows delivery in
    /// event-tracking mode, whereas a `.common`-mode Timer doesn't intercept events and fires normally
    /// during menu tracking, so it runs `pollMousePosition` in place of the monitors.
    private var menuTrackingPollTimer: Timer?
    private static let menuHoverSuspensionEnabled = DebugSwitch.menuHoverSuspend.isEnabled(in: ProcessInfo.processInfo.environment)
    /// On-demand monitors + throttling (DOCK_HOVER_MONITOR_LEAN=0 falls back to always-on + full per-event
    /// work).
    private static let hoverMonitorLeanEnabled = DebugSwitch.hoverMonitorLean.isEnabled(in: ProcessInfo.processInfo.environment)

    init(runtime: AppRuntime,
         drawerStore: DrawerStore,
         messagingStore: MessagingAppStore,
         badgeStore: BadgeStore,
         stripOrderStore: StripOrderStore,
         drawerOrderStore: DrawerOrderStore,
         settingsStore: AppSettingsStore,
         pinnedFolderStore: PinnedFolderStore,
         folderCoverStore: PinnedFolderCoverStore,
         shelfStore: ShelfStore,
         keptAppStore: KeptAppStore,
         runningApplicationStore: RunningApplicationStore,
         appMembershipController: AppMembershipController,
         displayTopologyStore: DisplayTopologyStore,
         topologySnapshotProvider: @escaping @MainActor () -> ScreenTopologySnapshot = {
             DisplayIdentity.topologySnapshot()
         },
         seedRetryScheduler: @escaping TaskbarPerDisplaySeedController.ScheduleAfter = { delay, action in
             let item = DispatchWorkItem(block: action)
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
             return item
         }) {
        self.runtime = runtime
        self.drawerStore = drawerStore
        self.messagingStore = messagingStore
        self.badgeStore = badgeStore
        self.stripOrderStore = stripOrderStore
        self.drawerOrderStore = drawerOrderStore
        self.settingsStore = settingsStore
        self.pinnedFolderStore = pinnedFolderStore
        self.folderCoverStore = folderCoverStore
        self.shelfStore = shelfStore
        self.keptAppStore = keptAppStore
        self.runningApplicationStore = runningApplicationStore
        self.appMembershipController = appMembershipController
        self.displayTopologyStore = displayTopologyStore
        self.topologySnapshotProvider = topologySnapshotProvider
        self.seedRetryScheduler = seedRetryScheduler
        self.dragController = DragController(
            drawerStore: drawerStore,
            messagingStore: messagingStore,
            membershipController: appMembershipController,
            dropZonesProvider: { [weak dragHost] source in dragHost?.dragDropZones(for: source) ?? [] },
            // One set of carrier panels per display (`DragController.CarrierSurface`), switched by the
            // display under the pointer: with "Displays have separate Spaces" a window belongs to one
            // display only, so covering the union would fail to draw on the other display.
            screensProvider: { NSScreen.screens },
            // When released on the capsule to stash, the icon is sucked in here (the capsule's visible frame
            // in the unit on the mouse's display).
            stashTargetProvider: { [weak dragHost] in dragHost?.stashTargetFrame }
        )
        super.init()
        dragHost.owner = self
        wireDragController()
    }

    deinit {
        MainActor.assumeIsolated {
            perDisplaySeedController?.cancel()
            removeHoverMouseMonitorsOnly()
        }
        menuTrackingPollTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    /// `DragController` is created before `super.init()`, so closures can't capture self: forward via a small
    /// proxy.
    @MainActor
    private final class DragHost {
        weak var owner: TaskbarScreenOrchestrator?
        func dragDropZones(for source: DragSource) -> [CGRect] {
            owner?.units.flatMap { $0.coordinator.dragDropZones(for: source) } ?? []
        }
        var stashTargetFrame: CGRect? {
            guard let owner else { return nil }
            return (owner.unitContainingMouse() ?? owner.units.first)?.coordinator.capsuleVisibleFrame
        }
    }
    private let dragHost = DragHost()

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        let seedController = makePerDisplaySeedController()
        perDisplaySeedController = seedController
        let snapshot = seedController.prepareForTopologyChange()
        rebuildUnits(reason: "start", connectedKeys: snapshot.identifiedDisplayUUIDs)
        // Build the carrier panels ahead of time so the user's first drag doesn't pay the 20ms plus one
        // 39ms main-thread hitch (rationale and measurements in `DragController.prewarmCarrier`). **Deferred
        // to the next run loop turn**: launch is one first-frame transaction and must not take extra SwiftUI
        // layout.
        DispatchQueue.main.async { [weak dragController] in
            dragController?.prewarmCarrier()
        }
        observeMenuTracking()
        reconcileHoverMouseMonitors()
        reconcileFullscreenIntentMonitor()
        placementSubscription = settingsStore.$taskbarScreenPlacement
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.rebuildUnits(
                    reason: "placement",
                    connectedKeys: self.displayTopologyStore.latestSnapshot.identifiedDisplayUUIDs
                )
                self.reconcileHoverMouseMonitors()
            }
        fullscreenIntentEnabledSubscription = settingsStore.$fullscreenIntentEnabled
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcileFullscreenIntentMonitor() }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    /// Permission lost: tear down all units and shared parts. No symmetric resume (the whole process restarts
    /// once permission is restored).
    func suspendAndRelease() {
        guard !isSuspended else { return }
        isSuspended = true
        // Roll back the uncommitted cross-panel drag transaction first, then remove the monitors; the
        // resident carrier panels must be closed explicitly too.
        dragController.cancelDrag()
        dragController.closeCarrierSurfaces()
        removeHoverMouseMonitors()
        stopMenuTrackingPoll()
        fullscreenIntentMonitor?.stop()
        fullscreenIntentMonitor = nil
        for unit in units {
            unit.coordinator.setFullscreenIntentRouting(enabled: false)
            unit.coordinator.tearDown()
        }
        units = []
        perDisplaySeedController?.cancel()
        perDisplaySeedController = nil
        placementSubscription = nil
        fullscreenIntentEnabledSubscription = nil
        NotificationCenter.default.removeObserver(self)
    }

    func toggleDrawer() {
        (unitContainingMouse() ?? units.first)?.coordinator.toggleDrawer()
    }

    func setTaskbarMenuOpen(_ open: Bool) {
        units.forEach { $0.coordinator.setTaskbarMenuOpen(open) }
    }

    // MARK: - Unit set

    /// Builds / tears down units for the current setting and display set. No-op if the target key list is
    /// unchanged (idempotent, callable from any notification).
    private func rebuildUnits(reason: String, connectedKeys: [String]) {
        guard started, !isSuspended else { return }
        let desired = TaskbarDisplaySet.desiredUnitKeys(
            placement: settingsStore.taskbarScreenPlacement,
            connectedKeys: connectedKeys
        )
        let current = units.map(\.key)
        guard desired != current else { return }
        let desiredSet = Set(desired.map { $0 ?? "" })
        var survivors: [String?: Unit] = [:]
        for unit in units {
            if desiredSet.contains(unit.key ?? "") {
                survivors[unit.key] = unit
            } else {
                unit.coordinator.setFullscreenIntentRouting(enabled: false)
                unit.coordinator.tearDown()
            }
        }
        units = desired.map { key in survivors[key] ?? makeUnit(key: key) }
        logger.info("units rebuilt reason=\(reason, privacy: .public) count=\(self.units.count, privacy: .public)")
        pushPanelScreensToIntentMonitor()
        reconcileBadgeGate()
    }

    private func makeUnit(key: String?) -> Unit {
        let placement: TaskbarUnitPlacement = key.map { .fixed(displayUUID: $0) } ?? .followSettings
        let coordinator = PanelCoordinator(
            placement: placement,
            dragController: dragController,
            overlaySpaceHost: overlaySpaceHost,
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
        coordinator.onAddFolder = onAddFolder
        coordinator.onRequestTaskbarMenu = onRequestTaskbarMenu
        coordinator.onHoverMonitorsNeedReconcile = { [weak self] in self?.reconcileHoverMouseMonitors() }
        coordinator.onPanelScreenChanged = { [weak self] in self?.pushPanelScreensToIntentMonitor() }
        coordinator.onLogicalVisibilityChanged = { [weak self] _ in
            self?.reconcileBadgeGate()
            self?.onForkUnitVisibilityChanged?()   // fork: reserve-screen-space re-checks when a bar shows
        }
        coordinator.onAccessoryWillOpen = { [weak self] unit, kind in
            self?.closeAccessories(exceptFor: unit, opening: kind)
        }
        coordinator.start()
        coordinator.setFullscreenIntentRouting(enabled: fullscreenIntentMonitor != nil)
        return Unit(key: key, coordinator: coordinator)
    }

    private func unitContainingMouse() -> Unit? {
        let mouse = NSEvent.mouseLocation
        return units.first { $0.coordinator.currentScreen?.frame.contains(mouse) == true }
    }

    private func unit(forDisplayUUID uuid: String) -> Unit? {
        if let unit = units.first(where: { $0.key == uuid }) { return unit }
        // Under ①② the single unit's key is nil: match by the display it is on right now.
        return units.first { unit in
            unit.coordinator.currentScreen.flatMap { DisplayIdentity.uuidString(for: $0) } == uuid
        }
    }

    @objc private func screenParametersChanged() {
        dragController.cancelDrag()   // display switch / resolution change -> cancel the in-flight cross-panel drag so the carrier isn't left at old-display coordinates
        // No display at all (every screen asleep or disconnected): there is nothing to lay out on.
        // The change that brings a screen back fires this again.
        guard !NSScreen.screens.isEmpty else { return }
        // One ordered snapshot feeds the shared display table, the seed decision and the unit set in
        // turn. Never re-read NSScreen in between.
        // With no seed controller the screen handling still runs to completion: the controller owns
        // only the one-shot first-run seed, while rebuilding units, re-homing each unit, pushing panel
        // screen frames and reconciling hover monitors are core multi-display work that must not hang
        // off its lifetime.
        let snapshot: ScreenTopologySnapshot
        if let seedController = perDisplaySeedController {
            snapshot = seedController.prepareForTopologyChange()
        } else {
            snapshot = topologySnapshotProvider()
            displayTopologyStore.apply(snapshot)
        }
        rebuildUnits(reason: "screens", connectedKeys: snapshot.identifiedDisplayUUIDs)
        units.forEach { $0.coordinator.screenParametersChanged() }
        pushPanelScreensToIntentMonitor()
        reconcileHoverMouseMonitors()  // display count changed: single <-> multi-display decides whether the monitors still need to exist
    }

    private func makePerDisplaySeedController() -> TaskbarPerDisplaySeedController {
        TaskbarPerDisplaySeedController(
            snapshotProvider: topologySnapshotProvider,
            isSeedPending: { [weak settingsStore] in
                settingsStore?.taskbarPerDisplaySeedPending ?? false
            },
            hasStoredPlacementChoice: { [weak settingsStore] in
                settingsStore?.hasStoredTaskbarScreenChoice ?? true
            },
            applySnapshot: { [weak displayTopologyStore] snapshot in
                displayTopologyStore?.apply(snapshot)
            },
            applySeed: { [weak self, weak settingsStore] in
                settingsStore?.applyTaskbarPerDisplaySeed()
                self?.logger.info("seeded allScreensPerDisplay for first multi-display topology")
            },
            consumeWithoutSeeding: { [weak settingsStore] in
                settingsStore?.consumeTaskbarPerDisplaySeedIfPresent()
            },
            onRetrySeeded: { [weak self] snapshot in
                self?.rebuildUnits(
                    reason: "seed-retry",
                    connectedKeys: snapshot.identifiedDisplayUUIDs
                )
            },
            scheduleAfter: seedRetryScheduler
        )
    }

    /// Only one drawer / popup / bubble open at a time: when a unit opens one, close the other units'.
    /// Drawer and popup are mutually exclusive (attached panels at the same level); bubbles only exclude
    /// bubbles (hover shouldn't close a drawer open on another display).
    private func closeAccessories(exceptFor unit: PanelCoordinator, opening kind: PanelCoordinator.AccessoryKind) {
        for other in units where other.coordinator !== unit {
            switch kind {
            case .drawer, .popup:
                other.coordinator.closeDrawer()
                other.coordinator.closeFolderPopup()
                other.coordinator.dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
            case .tooltip:
                other.coordinator.dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
            }
        }
    }

    /// Badge polling gate: visible if any unit is logically visible.
    private func reconcileBadgeGate() {
        badgeStore.setTaskbarVisible(units.contains { $0.coordinator.isLogicallyVisible })
    }

    // MARK: - Maximize lift-avoidance host

    /// One per resident, visible unit (under ③④ each display avoids on its own; a display whose bar is hidden
    /// doesn't lift that display's windows).
    func windowLiftAvoidanceContexts() -> [WindowLiftAvoidanceContext] {
        units.compactMap { $0.coordinator.windowLiftAvoidanceContext() }
    }

    // MARK: - Drag controller wiring (store-level side effects)

    private func wireDragController() {
        // Folder chip drag landing: DockStripView writes the geometry into DragController, and the final
        // mouseUp / polling fallback calls back here from endDrag to run the side effects.
        // Keeps .folder isolated from strip/drawer stash semantics.
        dragController.onFolderDragEnded = { [pinnedFolderStore] path, zone in
            switch zone {
            case .folderZone:
                break
            case .outsideStrip:
                pinnedFolderStore.remove(path)
            case .liveZone:
                pinnedFolderStore.remove(path)
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
        // Drawer drag back to taskbar, precise landing: on a successful release, clear the order layer's
        // external-block staging tracking (boundIDs are already normal members and stay on the taskbar).
        dragController.onDrawerToStripCommitted = { [stripOrderStore] _ in
            stripOrderStore.commitExternalBlock()
        }
        // Drawer drag back to taskbar, abnormal cancel (cancelDrag): roll back the order layer's
        // external-block staging (delete boundIDs + clear absentSince + clear staging).
        dragController.onDrawerToStripCancelled = { [stripOrderStore] in
            stripOrderStore.cancelExternalBlock()
        }
        // Drawer icon lands in the taskbar (fires on both the precise landing and the degraded path) -> close
        // the drawer (no-op for a closed unit).
        dragController.onDrawerToStripCompleted = { [weak self] _ in
            self?.units.forEach { $0.coordinator.closeDrawerAfterAction() }
        }
        // Cross-display drop (③④): card released on another display's taskbar -> move the window to that
        // display (move only, no raise) / a windowless icon now lives on that display.
        // One carrier panel per display, resident at the top level; once the taskbar is pinned into the
        // private Space, desktop-Space windows sit below it regardless of level,
        // so the carrier must be pinned into the same Space (rationale in `DragController.pinCarrierWindows`).
        dragController.pinCarrierWindows = { [weak self] numbers in
            guard let host = self?.overlaySpaceHost else { return }
            _ = host.pin(windowNumbers: numbers)
        }
        dragController.onCrossStripDrop = { [runtime] payload, displayUUID in
            runtime.handleCrossStripDrop(payload: payload, toDisplayUUID: displayUUID)
        }
    }

    // MARK: - Fullscreen-intent tap (one per process)

    private func reconcileFullscreenIntentMonitor() {
        let enabled = FullscreenIntentDecision.isEnabled(
            settingEnabled: settingsStore.fullscreenIntentEnabled,
            environment: ProcessInfo.processInfo.environment
        )
        guard enabled, !isSuspended else {
            fullscreenIntentMonitor?.stop()
            fullscreenIntentMonitor = nil
            units.forEach { $0.coordinator.setFullscreenIntentRouting(enabled: false) }
            return
        }
        guard fullscreenIntentMonitor == nil else { return }
        let monitor = FullscreenIntentMonitor(
            // Broadcast: each unit decides whether to act via its own screenCGFrame guard, so a display
            // entering fullscreen only hides that display's bar.
            onIntent: { [weak self] request in
                self?.units.forEach { $0.coordinator.beginFullscreenIntent(request) }
            },
            // Space switches happen per display: the tap has already located the display, so route to its
            // unit; if none is found, fall back to the display under the mouse.
            onSpaceSwitchIntent: { [weak self] direction, displayUUID in
                guard let self else { return }
                let target = self.unit(forDisplayUUID: displayUUID) ?? self.unitContainingMouse() ?? self.units.first
                target?.coordinator.beginFullscreenSpaceIntent(direction: direction)
            },
            onContextChange: { [weak self] change in
                self?.units.forEach { $0.coordinator.handleFullscreenIntentContextChange(change) }
            }
        )
        fullscreenIntentMonitor = monitor
        monitor.updatePanelScreens(currentPanelScreenCGFrames)
        monitor.start()
        units.forEach { $0.coordinator.setFullscreenIntentRouting(enabled: true) }
    }

    /// **Do not change back to `Set<CGRect>`**: `CGRect`'s `Hashable` conformance is macOS 15+, the compiler
    /// only warns, and on macOS 14 and earlier there is no witness table at runtime, so the first insert
    /// segfaults. 0.11.0–0.11.2 crashed at launch on those systems because of this one line
    /// (project rule). Displays are single digits, so array dedup is enough.
    private var currentPanelScreenCGFrames: [CGRect] {
        units.compactMap { $0.coordinator.currentPanelScreenCGFrame() }
            .reduce(into: [CGRect]()) { unique, frame in
                if !unique.contains(frame) { unique.append(frame) }
            }
    }

    private func pushPanelScreensToIntentMonitor() {
        fullscreenIntentMonitor?.updatePanelScreens(currentPanelScreenCGFrames)
    }

    // MARK: - Mouse-move monitors (one set per process, forwarded to every unit)

    /// The mouse-move monitors serve only two things: **multi-display hover switching** (no target on a
    /// single display, nor when pinned to a display / shown on all displays) and
    /// **edge auto-hide** (no timing target when off). When neither applies they are not installed at all, so
    /// the resident cost of "one callback per pointer move" drops to zero;
    /// re-evaluated when the display count or settings change (diagnostic switch DOCK_EDGEHOVER_TRACE=1
    /// forces always-on).
    private var hoverMonitorsNeeded: Bool {
        guard Self.hoverMonitorLeanEnabled else { return true }
        return (NSScreen.screens.count > 1 && settingsStore.taskbarScreenPlacement.allowsHoverScreenSwitching)
            || settingsStore.edgeAutoHideEnabled
            || PanelCoordinator.edgeHoverTraceEnabled
    }

    private func reconcileHoverMouseMonitors() {
        guard started, !isSuspended else { return }
        guard menuTrackingDepth == 0 else { return }   // the suspend logic takes over during menu tracking
        if hoverMonitorsNeeded {
            installHoverMouseMonitors()
            pollAllUnits()
        } else {
            removeHoverMouseMonitors()
        }
    }

    /// Handles two things in one place whenever any NitiaDock menu is open. Uses `NSMenu`'s app-level
    /// tracking notifications, covering all menus at once
    /// (icon / drawer / folder / capsule / status bar); submenus nest the notifications, so count by depth.
    ///
    /// 1. **Hold the "don't auto-hide" guard.** The menu pops up above the taskbar; as soon as the mouse
    ///    reaches up for a menu item, edge auto-hide
    ///    considers it to have left the taskbar, and the 0.2s idle timer runs and collapses the bar; the menu
    ///    is attached to the view of that icon on the bar,
    ///    so when the bar goes the menu goes with it (issue #42: after right-clicking an icon, moving the
    ///    mouse onto "New Window" made the menu vanish, unclickable).
    ///    The guard itself has existed since 2026-08-04, but was only wired to the status bar menu
    ///    (`StatusMenuController`);
    ///    icon menus were never covered.
    /// 2. **Remove the mouse-move monitors** (2026-08-04: moving back and forth between two menu items felt
    ///    sticky).
    ///    `addGlobalMonitorForEvents` is an event interceptor at the system level; when NitiaDock pops up its
    ///    own menu the main loop enters event-tracking mode,
    ///    the interceptor's handler isn't serviced in that mode, and every mouse-move event waits for a
    ///    timeout before delivery continues, so menu highlighting lags.
    ///
    /// **`DOCK_MENU_HOVER_SUSPEND=0` only turns off item 2**: it is the kill switch for that feel
    /// optimization. The notification registration itself
    /// must be unconditional, otherwise turning off the feel optimization would also turn off the #42 guard.
    private func observeMenuTracking() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuTrackingDidBegin),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuTrackingDidEnd),
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
    }

    @objc private func menuTrackingDidBegin() {
        menuTrackingDepth += 1
        guard menuTrackingDepth == 1 else { return }
        setTaskbarMenuOpen(true)
        guard Self.menuHoverSuspensionEnabled else { return }
        removeHoverMouseMonitorsOnly()
        startMenuTrackingPollIfNeeded()
    }

    @objc private func menuTrackingDidEnd() {
        menuTrackingDepth = max(0, menuTrackingDepth - 1)
        guard menuTrackingDepth == 0 else { return }
        setTaskbarMenuOpen(false)
        stopMenuTrackingPoll()
        // Reinstall (if still needed) and re-evaluate at once: while they were removed the mouse may have
        // crossed displays or left the hot zone.
        reconcileHoverMouseMonitors()
    }

    /// While a menu is open, a `.common`-mode timer replaces the monitors for bottom-edge probing (≤30Hz,
    /// same rate as the monitor throttle).
    /// Runs only when the monitors would be installed anyway; stops when the menu closes and they are
    /// reinstalled.
    private func startMenuTrackingPollIfNeeded() {
        guard menuTrackingPollTimer == nil, started, !isSuspended, hoverMonitorsNeeded else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollAllUnits() }
        }
        RunLoop.main.add(timer, forMode: .common)
        menuTrackingPollTimer = timer
    }

    private func stopMenuTrackingPoll() {
        menuTrackingPollTimer?.invalidate()
        menuTrackingPollTimer = nil
    }

    private func installHoverMouseMonitors() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        // Monitor callbacks arrive on the installing thread (main), so assumeIsolated saves one Task
        // allocation per event.
        if hoverLocalMouseMonitor == nil {
            hoverLocalMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
                MainActor.assumeIsolated { self?.hoverPollEventArrived() }
                return event
            }
        }
        if hoverGlobalMouseMonitor == nil {
            hoverGlobalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
                MainActor.assumeIsolated { self?.hoverPollEventArrived() }
            }
        }
    }

    /// Every mouse-move event comes through here (up to hundreds of Hz while moving). Throttled to ≤30Hz:
    /// hover switching needs a 350ms dwell,
    /// edge wake doesn't notice 33ms; the last position that comes to rest inside the window is re-evaluated
    /// by the trailing pass, so no hot-zone enter/exit is lost.
    private func hoverPollEventArrived() {
        guard Self.hoverMonitorLeanEnabled else {
            // Old behavior as is: each event hops through a main-thread Task, then full processing.
            Task { @MainActor [weak self] in self?.pollAllUnits() }
            return
        }
        switch hoverPollThrottle.eventArrived(now: CACurrentMediaTime()) {
        case .run:
            pollAllUnits()
        case .scheduleTrailing(let after):
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.hoverPollThrottle.trailingFired(now: CACurrentMediaTime())
                    self.pollAllUnits()
                }
            }
        case .drop:
            break
        }
    }

    private func pollAllUnits() {
        units.forEach { $0.coordinator.pollMousePosition() }
    }

    /// Removes the monitors only, **does not touch** wake / display-switch state; `removeHoverMouseMonitors`
    /// handles those on real teardown.
    /// Doing `cancelEdgeWake()` as well during the second or two a menu is open would mean that opening the
    /// status bar menu while hidden
    /// also cancels a bottom-edge wake that is arming, an extra behavior change.
    private func removeHoverMouseMonitorsOnly() {
        if let monitor = hoverLocalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            hoverLocalMouseMonitor = nil
        }
        if let monitor = hoverGlobalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            hoverGlobalMouseMonitor = nil
        }
    }

    private func removeHoverMouseMonitors() {
        removeHoverMouseMonitorsOnly()
        hoverPollThrottle.reset()
        for unit in units {
            unit.coordinator.cancelHoverSwitch()
            unit.coordinator.cancelEdgeWake()
        }
    }
}
