import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

/// Shared duration for drawer-related animations, used by both AppKit (panel frame / alpha) and SwiftUI
/// (content scale / grid reflow), so "panel size sliding" and "content-internal animation" have the same
/// duration and stay in step (v1: panel leads + content uses the same parameters).
enum DrawerAnimation {
    static let duration: TimeInterval = 0.22
}

/// Popup/drawer "panel open/close + content entrance" motion (fast out, slow stop, close to the native Stacks
/// feel, 2026-07-06).
/// Taskbar width / panel frame layout animations still use DrawerAnimation.duration=0.22; the two durations
/// must not be merged (project rule).
enum PopoverAnimation {
    static let openDuration: TimeInterval = 0.18
    static let closeDuration: TimeInterval = 0.13
    /// Strong ease-out: fast start, gentle finish, the native pop-up feel.
    static func curve() -> CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
    }
}

@MainActor
final class PanelCoordinator: NSObject {
    /// Panel geometry varies with the dock size, so these **can no longer be static**: on a size change they
    /// follow the store.
    /// `shadowPadding` is the exception: fixed at 20, still referenced statically on the view side (drawer,
    /// both popups).
    var layoutMetrics: PanelLayoutMetrics {
        settingsStore.dockSize.metrics.withBottomMargin(settingsStore.appearance.bottomMargin)   // fork
    }
    var panelHeight: CGFloat { layoutMetrics.panelHeight }
    var windowHeight: CGFloat { layoutMetrics.windowHeight }
    var capsuleWidth: CGFloat { layoutMetrics.capsuleWidth }
    /// Corner radius of the glass background window. Must be the same value as the taskbar backplate on the
    /// SwiftUI side, otherwise the window blur shows square corners outside the glass's rounded corners. The
    /// common source for both is `DockShape.panelCornerRadius`.
    /// Whether the five floating panels use native Liquid Glass: **single source**.
    ///
    /// The criterion is "did the taskbar's glass compositing get built": the background window is built in
    /// `setupDockPanel`, and the drawer / both popups are built lazily on demand, by which time this value is
    /// long settled. All five panels share one check, so there is never "the bar is glass while the capsule
    /// right next to it is still frosted".
    var usesLiquidGlass: Bool { dockGlassBackgroundPanel != nil }

    /// Builds a floating panel. **With glass on, `DockLiquidGlassPanel` is mandatory, for all five panels
    /// without exception.**
    ///
    /// Liquid Glass's "active" appearance is decided by the **window's** key / main / active state, and all
    /// our panels are `.nonactivatingPanel` and never become key. With a plain `NonConstrainingPanel` the
    /// glass drops to the "inactive" tier and renders as a nearly opaque milky slab. `DockLiquidGlassPanel`
    /// overrides those five private appearance checks and always reports the window as active.
    ///
    /// Before 2026-08-17 **only the taskbar** used this subclass, so the drawer / capsule / both popups /
    /// tooltip were not the same material (seen as "the drawer area does not look like liquid glass either").
    /// Measured light transmission against black / white target windows:
    ///
    /// | | Taskbar | Capsule | Drawer |
    /// |---|---|---|---|
    /// | Before fix | 145 | **172** | **170** |
    /// | After fix | 145 | 149 | 148 |
    ///
    /// A gap of 25–27 levels -> converged to within 4. **Do not use "looks about the same on the same
    /// background" as verification**:
    /// on a black-and-white striped target both read mid-gray, which is exactly how "capsule matches the
    /// taskbar" was once misjudged.
    /// The criterion must be **light transmission** (the difference between one panel's readings on pure
    /// black and pure white backgrounds).
    ///
    /// The two SwiftUI-side lines `.materialActiveAppearance(.active)` / `.environment(\.appearsActive,)`
    /// **cannot replace this layer**: they govern the view environment; window state has to be solved on the
    /// window.
    /// Experiment switch: `DOCK_PANEL_LEVEL=<raw>` overrides the window level of the three taskbar panels
    /// (default .floating=3).
    /// Purpose: verify "whether windows at a high enough level (system Dock=20, menu bar higher) escape being
    /// baked by WindowServer into the desktop-swipe transition snapshot". The 2026-08-30 burst capture
    /// confirmed gray veil = the bar baked into both side snapshots, then overlaid during the swipe.
    static let panelLevelOverride: NSWindow.Level? = DebugSwitch.panelLevel.value().flatMap(Int.init).map { NSWindow.Level(rawValue: $0) }

    var taskbarPlateCornerRadius: CGFloat {
        DockShape.panelCornerRadius * settingsStore.dockSize.scale
    }
    static let shadowPadding: CGFloat = PanelLayoutMetrics.shadowPadding

    let runtime: AppRuntime
    let drawerStore: DrawerStore
    let messagingStore: MessagingAppStore
    let badgeStore: BadgeStore
    let stripOrderStore: StripOrderStore
    let drawerOrderStore: DrawerOrderStore
    let settingsStore: AppSettingsStore
    let pinnedFolderStore: PinnedFolderStore
    let folderCoverStore: PinnedFolderCoverStore
    let shelfStore: ShelfStore
    let keptAppStore: KeptAppStore
    let runningApplicationStore: RunningApplicationStore
    let appMembershipController: AppMembershipController
    /// The only execution queue for moving external files into a pinned folder: eligibility checks and disk
    /// operations both run serially per drop batch.
    let fileDropQueue = DispatchQueue(label: "no.thilip.nitiadock.folder-drop", qos: .userInitiated)
    /// Entry point for the folder chip / shelf context menu item "Add Folder…" (injected by AppDelegate,
    /// which owns NSOpenPanel).
    var onAddFolder: () -> Void = {}
    /// Shows the NitiaDock menu on right-click of the taskbar / capsule. The menu is owned by
    /// `StatusMenuController`; this only forwards the event.
    /// In normal operation the app is `.accessory` (no menu bar, hence no ⌘,), so once the status bar icon is
    /// crowded out or hidden by the notch, this is the only remaining way to open Settings.
    var onRequestTaskbarMenu: ((NSEvent, NSView) -> Void)?
    var dockPanel: NSPanel?
    var dockGlassBackgroundPanel: NonConstrainingPanel?
    var dockGlassBackgroundView: DockTaskbarLiquidGlassBackgroundView?
    /// SwiftUI host of the main taskbar. The window frame belongs to PanelCoordinator; content size is read
    /// only from here.
    var dockContentHost: ManualPanelHost?
    var drawerPanel: NSPanel?
    var capsulePanel: NSPanel?
    /// SwiftUI host of the capsule. The capsule has a fixed size (`capsuleWidth`) and nobody reads its
    /// `fittingSize` currently, but it is still **held strongly** rather than discarded with `_ =`:
    /// discarded, the container is only kept alive indirectly by the view hierarchy, and if `ManualPanelHost`
    /// ever gets `deinit` cleanup, the capsule silently stops working.
    var capsuleContentHost: ManualPanelHost?
    /// The hosting view that actually hosts SwiftUI for the drawer (the drawer's contentView is a plain
    /// NSView container, so fittingSize must be read from this).
    var drawerContentHost: NSView?
    /// Typed reference to the same host, for "swap only rootView on each open". **Built once** (2026-09-04):
    /// previously each open built a fresh drawer view tree + measured synchronously + rendered the first
    /// frame, a 55-135ms main-thread stall right at the start of the 0.18s fade-in, the main cause of dropped
    /// frames when the drawer opens. While closed it stays alive like the drawer of a closed screen under ③④;
    /// drag callbacks all ask `isDrawerOpen()` first, so this is not a new state.
    var drawerHosting: NSHostingView<DrawerRootView>?
    /// The available height used by the rootView currently in the host; if unchanged, rootView is not even
    /// swapped and opening does no SwiftUI graph update at all.
    var drawerHostedMaxContentHeight: CGFloat?
    /// Sole authority for cross-panel drags (drag card into drawer, route C): carrier panel + mouse monitors
    /// + landing wrap-up all live in it.
    /// Must be built before setupDockPanel/setupCapsulePanel, because it is injected into both panels'
    /// hosting.
    /// Cross-panel drag authority. **Exactly one per process**, created by the orchestration layer and
    /// injected into every unit (under ③④ shared by N taskbars: the drop zones are the union across units,
    /// and carrier panels are one set per screen anyway).
    let dragController: DragController
    /// Suspended state after permission loss. Deliberately does **not** reuse `visibilityState.hideReasons`:
    /// those are for fullscreen and edge auto-hide, and mixing this in would let the bottom-edge wake pull
    /// the panels back on screen.
    var isSuspendedForPermissionLoss = false
    var drawerLocalMonitor: Any?
    var drawerGlobalMonitor: Any?
    // MARK: Folder/shelf popup state (single-panel reuse = inherently "only one popup at a time")
    /// Content currently loaded in the shared popup: pinned folder grid or shelf grid.
    enum PopupContent: Equatable {
        case folder(path: String)
        case shelf
        case trash
    }
    var folderPopupPanel: NSPanel?
    /// The hosting view that actually hosts SwiftUI for the popup (contentView is a plain NSView container,
    /// fittingSize is read from this).
    var folderPopupContentHost: NSView?
    var popupLocalMonitor: Any?
    var popupGlobalMonitor: Any?
    var lastPopupTargetFrame: NSRect = .zero
    /// Popup anchor (chip visible rect, screen coordinates). The click-away check must exclude it: the
    /// monitor closes on mouseDown and the chip's onTapGesture reopens on mouseUp, so without excluding the
    /// anchor a click on the same chip could never dismiss.
    var popupAnchorVisibleRect: CGRect = .zero
    /// Current popup content (nil = not open).
    var openPopupContent: PopupContent?
    /// Convenience view: gives the path only when the popup holds a folder (for folder-specific logic such as
    /// sort subscription / close on removal).
    var openPopupPath: String? {
        if case let .folder(path) = openPopupContent { return path }
        return nil
    }
    /// **Logical** open state of the popup (during the fade-out the panel is still visible but logically
    /// closed, same as drawerWantsOpen).
    var folderPopupWantsOpen = false
    var lastPopupSize = CGSize(width: 424, height: 240)
    /// Open time: repositioning within the entrance window (250ms) is always instant, so it does not stack
    /// with the entrance fade-in and wobble.
    var popupOpenedAt: Date = .distantPast
    /// Hand-rolled per-frame interpolation timer for popup switch/reposition (interpolates
    /// centerX/bottomY/width/height, replacing the raw x/y/width/height linear interpolation of
    /// NSWindow.animator().setFrame, which has no notion of an anchor: once the relative position of two
    /// folder frames changes, growth drifts toward a random corner instead of a stable "bottom-anchored,
    /// horizontally centered").
    var folderPopupFrameTimer: Timer?
    /// Incremented for every new tween. The tick callback checks this token before changing the frame:
    /// Timer.invalidate() cannot stop the one callback that "already fired but whose Task is still queued on
    /// the main actor", so invalidate alone is not enough; the token makes stale queued tasks turn into
    /// no-ops.
    var folderPopupTweenToken: Int = 0
    /// Target frame of the tween in flight (nil = none). The double-defer fallback correction often comes
    /// back in with the **same** target; restarting blindly would interrupt the animation right after it
    /// starts and reset the clock (speed jump + longer total duration), so an identical target is let through
    /// to finish.
    var folderPopupTweenTarget: NSRect?
    // MARK: Window title tooltip (dedicated panel, does not reuse folderPopupPanel)
    var windowTitleTooltipPanel: NSPanel?
    var windowTitleTooltipRequest: WindowTitleTooltipRequest?
    var windowTitleTooltipSuppressedChipID: String?
    var windowTitleTooltipLingerTimer: Timer?
    /// Watchdog that runs only while the tooltip is on screen, see `startWindowTitleTooltipWatchdog`.
    var windowTitleTooltipWatchdog: Timer?
    var windowTitleTooltipLocalMonitor: Any?
    var windowTitleTooltipGlobalMonitor: Any?
    /// Reuses one hosting view: creating a new `NSHostingView` per hover flashes when switching chips and
    /// pays a build cost for nothing.
    var windowTitleTooltipHosting: NSHostingView<WindowTitleTooltipView>?
    var windowTitleTooltipHost: ManualPanelHost?
    var pinnedFolderStoreSubscription: AnyCancellable?
    var pinnedFolderSortSubscription: AnyCancellable?
    var snapshotWidthSubscription: AnyCancellable?
    var drawerStoreWidthSubscription: AnyCancellable?
    var messagingStoreWidthSubscription: AnyCancellable?
    var keptAppStoreSubscription: AnyCancellable?
    var runningApplicationStoreSubscription: AnyCancellable?
    var dragSpringSubscription: AnyCancellable?
    var dragInhibitorSubscription: AnyCancellable?
    var edgeDelaySubscription: AnyCancellable?
    var taskbarScreenPlacementSubscription: AnyCancellable?
    var displayTopologySubscription: AnyCancellable?
    var showShelfSubscription: AnyCancellable?
    var showDrawerSubscription: AnyCancellable?
    var forkAppearanceSubscription: AnyCancellable?
    var showTrashSubscription: AnyCancellable?
    var dockSizeSubscription: AnyCancellable?
    /// Size-change transaction generation: swallows animated layouts queued by other paths during a size
    /// change (see beginDockSizeChange).
    var dockSizeChangeGeneration: UInt64 = 0
    /// Drawer dragged back to the taskbar, "grows only on release": the taskbar width is frozen while
    /// promotion is in progress and relayout runs when the promoted state ends (landing on release / restore
    /// on drag-out).
    var stripSlotCollapseSubscription: AnyCancellable?
    var springOpenTimer: Timer?
    /// Timer for the **delayed retract** after leaving the drawer + capsule (2026-06-22: delay it, do not
    /// close on the first brush against the taskbar).
    var springCloseTimer: Timer?
    /// Whether this drag **started on the taskbar**. A taskbar card entering the drawer body gets "promoted"
    /// to a `.drawer` source (see DragController), but the spring (open / delayed retract / reopen) should
    /// apply for the whole drag, so this is used, not the live source (2026-06-22).
    var dragOriginatedFromStrip = false
    /// **Logical** open state of the drawer (not isVisible: during the fade-out the panel is still visible
    /// but logically closed). toggle / spring / interruptible close all go by it.
    var drawerWantsOpen = false
    /// Incremented on every openDrawer(). closeDrawerAfterAction() captures the current value and discards on
    /// mismatch when it fires, so a delayed close from an old click cannot kill a new drawer after a reopen.
    var drawerActionCloseToken = 0
    /// Whether this drawer was opened by the **spring** (drag hover). If so and the card did not enter the
    /// drawer on release (dragged back to the taskbar) -> retract automatically.
    var drawerSpringOpened = false
    /// bundleID of the strip card being dragged; used on release to tell whether it was stowed in the drawer.
    var springDragBundleID: String?
    var lastDesiredWidth: CGFloat = 0
    /// "Follow window" for labels growing or shrinking: label boxes in the bar really change width per frame
    /// following `LabelWidthAnimation` (`LabelBoxWidthDriver`), report the live width each frame
    /// (`labelBoxWidthDidTick`), and the panel sets its frame without animation in the same pass, committed
    /// together with that frame's content. Total content width = width measured at start + Σ(live box width −
    /// starting box width). **It cannot be measured after the fact** (that measures the previous frame and
    /// displays one frame later, so the backplate lags a steady two frames), **nor predicted from the curve**
    /// (the two clocks do not line up, ±1 frame jitter); both were measured with screen burst captures on
    /// 2026-09-13. After the deadline the final value is measured once more as a fallback.
    var labelFollowTimer: Timer?
    var labelFollowRestWidth: CGFloat = 0
    var labelBoxStart: [String: CGFloat] = [:]
    var labelBoxLive: [String: CGFloat] = [:]
    var labelFollowDeadline: CFTimeInterval = 0
    /// Window id set of the previous snapshot: if the set changed (cards added/removed) the 0.22s window
    /// animation runs even with the follow window open; a snapshot with an unchanged set while the follow
    /// window is open does not measure the width (it would measure an in-between value and drag the panel
    /// back).
    var lastSnapshotWindowIDs: Set<WindowID>?
    /// Expected end time of the most recent **animated** `setFrames`: the follow window's per-frame setFrame
    /// does not compete before it (otherwise it would collapse the 0.22s window animation for card add/remove
    /// into a single step).
    var animatedFramesUntil: CFTimeInterval = 0
    var lastDrawerSize: CGSize = CGSize(width: 210, height: 60)
    /// Target-frame-driven layout: every layoutPanels computes all three targets and stores them here. Drop
    /// zone hit tests and drawer positioning read the **target**, not the live frame: mid-animation the live
    /// frame is an in-between value and briefly disagrees with visuals/logic.
    /// The target frame sequence `setFrames` last actually committed. Used to block "restarting the animation
    /// although the target did not change":
    /// measured 8 such idle runs in the 7 seconds after launch, 6 of them packed into 1.1ms, which restarts
    /// the same group of window-size animations six times in a row, and every frame of it redraws the glass
    /// backplate and stroke.
    var lastCommittedFrames: [NSRect] = []
    var lastDockTargetFrame: NSRect = .zero
    var lastCapsuleTargetFrame: NSRect = .zero
    var lastDrawerTargetFrame: NSRect = .zero
    /// First-frame layout is forced instant (the panel was just built, do not slide in from the
    /// initial/origin position).
    var didInitialLayout = false
    let logger = Logger(subsystem: "no.thilip.nitiadock", category: "dock-panel")
    let fullscreenIntentLogger = Logger(
        subsystem: "no.thilip.nitiadock",
        category: "FullscreenIntent"
    )
    var fullscreenReconcileTimer: Timer?
    var workspaceObserverTokens: [NSObjectProtocol] = []
    /// The orchestration layer owns the only `FullscreenIntentMonitor` (session event tap) and routes
    /// requests in; this flag = "routing connected", replacing the former `fullscreenIntentMonitor != nil`
    /// guard.
    var fullscreenIntentRoutingEnabled = false
    var fullscreenIntentTimeoutTimer: Timer?
    var fullscreenIntentGeneration: UInt64 = 0
    var fullscreenIntentTransaction: FullscreenIntentTransaction?
    var fullscreenProbeGeneration: UInt64 = 0
    var fullscreenSpaceHoldGeneration: UInt64 = 0
    var fullscreenSpaceHold: FullscreenSpaceHold?
    var fullscreenSpaceHoldTimer: Timer?
    /// Control+Left/Right predictive hide. **On by default**, turn off with `DOCK_SPACE_INTENT=0` (decided by
    /// `spaceSwitchEnabled` in `FullscreenIntentMonitor`). Shares the `.fullscreenTransitionPending` slot of
    /// `visibilityState` with the window-level intent transaction, so the two are mutually exclusive, only
    /// one at a time.
    var fullscreenSpaceIntentGeneration: UInt64?
    var fullscreenSpaceIntentTimer: Timer?
    var fullscreenSpaceIntentVerdictTimer: Timer?
    /// Whether the last hide was because of fullscreen. Yes -> the next reveal uses the 0.18s fade-in
    /// (entrance animation on return from fullscreen); no -> the edge auto-hide reveal stays instant. Written
    /// only in applyPanelVisibility / the predictive hide.
    var lastHideWasForFullscreen = false
    /// "Present on all desktops" membership repair (issue #19). See the mechanism notes in
    /// `AllSpacesMembership`.
    /// Turn off with `DOCK_SPACE_MEMBERSHIP_REPAIR=0`.
    static let spaceMembershipRepairEnabled =
        DebugSwitch.spaceMembershipRepair.isEnabled(in: ProcessInfo.processInfo.environment)
    var spaceMembershipRepairInFlight = false
    var lastActiveApplicationPID: pid_t?
    var visibilityState = PanelVisibilityState()
    var panelsAreVisible = true
    var edgeIdleHideTimer: Timer?
    var edgeWakeTimer: Timer?
    var edgeWakeTargetScreen: NSScreen?
    var edgeWakeRequiresHotZone = true
    /// The mouse monitor owned by the orchestration layer needs re-evaluation (edge-hide toggle / display
    /// placement / screen set changed).
    var onHoverMonitorsNeedReconcile: (() -> Void)?
    /// This unit's panels changed screens (or first layout). The orchestration layer uses this to feed all
    /// units' screen set to the fullscreen intent tap.
    var onPanelScreenChanged: (() -> Void)?
    /// This unit's logical visibility changed (including the predictive hide fast path). The orchestration
    /// layer does the "any visible" merge for badge gating.
    var onLogicalVisibilityChanged: ((Bool) -> Void)?
    /// This unit is about to open an auxiliary panel. The orchestration layer uses this to close the same
    /// kind of panel in other units (only one drawer / popup / tooltip open at a time).
    var onAccessoryWillOpen: ((PanelCoordinator, AccessoryKind) -> Void)?

    enum AccessoryKind { case drawer, popup, tooltip }

    /// Where this unit is placed (see `TaskbarUnitPlacement`). Under ③④ there is one `.fixed` unit per
    /// screen.
    let unitPlacement: TaskbarUnitPlacement
    /// Private Space host for the permanent panels (one per process, owned by the orchestration layer). nil =
    /// switch off / symbol missing, and panels keep the old `.canJoinAllSpaces` behavior. See
    /// `OverlaySpaceHost`.
    let overlaySpaceHost: OverlaySpaceHost?
    /// Surface identity of this unit's strip in the shared `DragController` (see
    /// `DragController.activeStripSurfaceID`).
    let stripSurfaceID = "strip-" + UUID().uuidString
    let displayTopologyStore: DisplayTopologyStore
    /// The fixed units of ③④ know which screen they are; for the follow units of ①② it is nil (the per-screen
    /// filter under ④ does not apply to them).
    var fixedUnitDisplayUUID: String? {
        if case .fixed(let uuid) = unitPlacement { return uuid }
        return nil
    }

    init(placement: TaskbarUnitPlacement,
         dragController: DragController,
         overlaySpaceHost: OverlaySpaceHost?,
         runtime: AppRuntime,
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
         displayTopologyStore: DisplayTopologyStore) {
        self.unitPlacement = placement
        self.dragController = dragController
        self.overlaySpaceHost = overlaySpaceHost
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
        super.init()
    }

    func start() {
        setupDockPanel()
        setupCapsulePanel()
        presentInitialPanels()
        pinResidentPanelsIfNeeded()
        prewarmDrawerHost()
        subscribeSnapshotWidth()
        subscribeDrawerStoreWidth()
        subscribeMessagingStoreWidth()
        subscribeKeptAppStore()
        subscribeRunningApplicationStore()
        subscribeDragSpringLoad()
        subscribeDragInhibitor()
        subscribeStripSlotCollapse()
        subscribeSettings()
        subscribePinnedFolderStore()
        setupFullscreenMonitor()
        if Self.hoverVerboseLogging { logScreenMap() }
        // Screen parameter changes, the mouse monitor and the fullscreen intent tap are all owned and
        // forwarded by the orchestration layer (one shared copy for the multiple units of ③④).
    }

    deinit {
        fullscreenReconcileTimer?.invalidate()
        fullscreenIntentTimeoutTimer?.invalidate()
        fullscreenSpaceHoldTimer?.invalidate()
        fullscreenSpaceIntentTimer?.invalidate()
        fullscreenSpaceIntentVerdictTimer?.invalidate()
        MainActor.assumeIsolated {
            dismissWindowTitleTooltip()
            tearDownTaskbarGlassBackground()
        }
        hoverSwitchTimer?.invalidate()
        edgeIdleHideTimer?.invalidate()
        edgeWakeTimer?.invalidate()
        springOpenTimer?.invalidate()
        springCloseTimer?.invalidate()
        folderPopupFrameTimer?.invalidate()
        workspaceObserverTokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    func toggleDrawer() {
        if drawerWantsOpen { closeDrawer() } else { openDrawer() }
    }

    /// On permission loss, tears the whole panel set down and gives up ownership (the caller then just nils
    /// its reference). Idempotent.
    ///
    /// Deliberately does **not** go the "hand-maintained list of monitors to remove" way, the risk of missing
    /// an item is too high:
    /// `DockStripView` installs its own force-click / middle-button monitors in an `NSViewRepresentable`, and
    /// only actually tearing down the view tree triggers `dismantleNSView` to remove them; `deinit` already
    /// covers the hover monitors and a whole row of timers, and that list is maintained along with new
    /// resources.
    /// So: tear down the view tree -> close the panels -> let the caller release this object so `deinit`
    /// runs.
    ///
    /// No symmetric resume: after permission is restored the whole process restarts, there is no "resume
    /// running" path.
    ///
    /// Under ③④ unplugging a screen also comes through here to tear down that screen's unit (called by the
    /// orchestration layer). The shared drag controller / carrier panels are **not torn down here**: they are
    /// per-process and the orchestration layer tears them down once on a real suspend.
    func tearDown() {
        guard !isSuspendedForPermissionLoss else { return }
        isSuspendedForPermissionLoss = true
        fullscreenIntentRoutingEnabled = false
        if let transaction = fullscreenIntentTransaction {
            cancelFullscreenIntent(generation: transaction.generation, reason: "teardown")
        }
        fullscreenIntentTimeoutTimer?.invalidate()
        fullscreenIntentTimeoutTimer = nil
        fullscreenSpaceHoldTimer?.invalidate()
        fullscreenSpaceHoldTimer = nil
        fullscreenSpaceHold = nil
        clearFullscreenSpaceArrowIntent()

        closeDrawer()
        closeFolderPopup(immediately: true)
        dismissWindowTitleTooltip()
        cancelHoverSwitch()
        cancelEdgeWake()
        edgeIdleHideTimer?.invalidate()
        edgeIdleHideTimer = nil

        // Replacing contentView triggers the SwiftUI teardown; the separately strongly held host has to be
        // nilled first.
        dockContentHost = nil
        capsuleContentHost = nil
        drawerContentHost = nil
        drawerHosting = nil
        drawerHostedMaxContentHeight = nil
        folderPopupContentHost = nil
        windowTitleTooltipHosting = nil
        windowTitleTooltipHost = nil
        tearDownTaskbarGlassBackground()
        for panel in [dockPanel, capsulePanel, drawerPanel, folderPopupPanel, windowTitleTooltipPanel] {
            guard let panel else { continue }
            panel.contentView = NSView()
            panel.orderOut(nil)
            panel.close()
        }
        dockPanel = nil
        capsulePanel = nil
        drawerPanel = nil
        folderPopupPanel = nil
        windowTitleTooltipPanel = nil
        // With all panels torn down, the "last committed target" is void too: keeping it would make the first
        // layout after a rebuild be misjudged as "target unchanged" and skipped, leaving the bar on the old
        // geometry.
        lastCommittedFrames = []
    }

    /// Which screen this unit's taskbar is on right now (derived from the panel coordinates). nil before the
    /// panels are built.
    var currentScreen: NSScreen? {
        dockPanel.map { panelCurrentScreen(panel: $0) }
    }

    /// Logical visibility (for badge gating / the orchestration layer's merge).
    var isLogicallyVisible: Bool { panelsAreVisible }

    /// Maximize lift avoidance gets a context only while NitiaDock is resident and actually visible; the full
    /// geometry is returned at once to avoid torn reads during a screen switch.
    func windowLiftAvoidanceContext() -> WindowLiftAvoidanceContext? {
        guard !settingsStore.edgeAutoHideEnabled,
              visibilityState.isVisible,
              panelsAreVisible,
              let panel = dockPanel else {
            return nil
        }

        let screen = panelCurrentScreen(panel: panel)
        let primaryScreenHeight = Self.quartzPrimaryScreenHeight
        let geometry = WindowLiftAvoidance.Geometry(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            taskbarTop: screen.frame.minY
                + layoutMetrics.bottomGap
                + layoutMetrics.panelHeight
        )
        return WindowLiftAvoidanceContext(
            geometry: geometry,
            screenCGFrame: Self.toCGRect(screen),
            visibleCGFrame: WindowLiftAvoidance.quartzFrame(
                fromAppKit: screen.visibleFrame,
                primaryScreenHeight: primaryScreenHeight
            ),
            primaryScreenHeight: primaryScreenHeight
        )
    }

    // MARK: - Drag Controller (drag card into drawer, route C): the controller is created and injected by the orchestration layer, only geometry is provided here

    /// Drop candidate zones (screen coordinates), by drag source:
    /// - `.strip` / `.messaging` (taskbar card / message chip looking for a stow target) = capsule visible
    ///   content area + 8pt tolerance (the capsule frame includes the shadowPadding=20 transparent margin;
    ///   minus 20 gives the 52×52 visible area, then 8 of outward tolerance, and no wider: the capsule sits
    ///   right next to the taskbar, and too wide means "dragging nearby gets it stowed"); with the drawer
    ///   open, the drawer's visible content area is added. The taskbar itself is not a drop zone for them.
    /// - `.drawer` (drawer icon looking for a move-back target) = visible content area of the taskbar dock
    ///   panel (minus shadowPadding).
    /// Visible frame of the capsule (screen coordinates, target frame preferred). The end point of
    /// `DragController`'s "pulled into the capsule" flight.
    var capsuleVisibleFrame: CGRect? {
        guard showsDrawerCapsule else { return nil }   // fork: no capsule, nothing to fly into
        let frame = lastCapsuleTargetFrame != .zero ? lastCapsuleTargetFrame : capsulePanel?.frame
        return frame?.insetBy(dx: Self.shadowPadding, dy: Self.shadowPadding)
    }

    // MARK: - Window title tooltip

    /// Exit grace: after `.exit`, wait this long before dismissing. **This is the key to it tracking the
    /// pointer.** Crossing a section divider leaves the pointer briefly on no card, and an immediate orderOut
    /// would flash; the neighbor takes over with its `.update` and the grace period lapses by itself.
    ///
    /// **The matching "cold start delay" has been removed, do not add it back.** There used to be a 0.05s
    /// debounce, meant to avoid a flash per icon when sweeping a row, but it backfired: 0.05s is right about
    /// the dwell time on a single icon at a steady sweep (42pt center spacing, only tens of milliseconds per
    /// cell at normal swipe speed), so most cells were already left before the timer fired. The native Dock
    /// has no such delay. With the panel kept alive, switching chips does not flash anyway.
    static let windowTitleTooltipLingerDelay: TimeInterval = 0.09

    // MARK: - Target-frame-driven layout
    //
    // Root cause from the second review: positioning the next panel after an animation by "reading the live
    // frame of the previous, still animating panel" reads the old value from the animation start -> the
    // capsule is positioned from the old taskbar and the drawer from the old capsule -> misalignment after
    // the taskbar widens, drawer overlapping the taskbar. Fix: compute all three **target** frames at once
    // (pure functions, none reads a live frame), and the three panels each slide to target within **one
    // animation group**.

    static let layoutAnimationDuration: TimeInterval = DrawerAnimation.duration

    // MARK: - All-desktops membership repair (issue #19)

    /// Panels that must be present on every desktop. Drawer / folder popup / hover tooltip are transient
    /// panels: the next time they show, `orderFrontRegardless` lands them on the current desktop and the user
    /// never waits for them on another desktop, so they take no part in the repair.
    var allSpacesPanels: [NSPanel] {
        [dockGlassBackgroundPanel, dockPanel, shownCapsulePanel].compactMap { $0 }
    }

    func panelCurrentScreen(panel: NSPanel) -> NSScreen {
        // Use the center of the visible content area (inset by shadowPadding) so the 12pt shadow
        // bleed below screen.frame.minY doesn't cause first(where:intersects) to return the wrong
        // adjacent screen in multi-monitor setups (e.g. vertically stacked 3-screen layouts).
        let visualCenter = CGPoint(
            x: panel.frame.midX,
            y: panel.frame.minY + Self.shadowPadding + panelHeight / 2
        )
        return NSScreen.screens.first(where: { $0.frame.contains(visualCenter) })
            ?? NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) })
            ?? NSScreen.lastResort
    }

    // AppKit frame (bottom-left origin) → CG/Quartz frame (top-left origin of primary screen)
    static func toCGRect(_ screen: NSScreen) -> CGRect {
        let f = screen.frame
        return CGRect(
            x: f.minX,
            y: quartzPrimaryScreenHeight - f.maxY,
            width: f.width,
            height: f.height
        )
    }

    /// `NSScreen.main` follows the key window and may be a secondary display. Quartz global
    /// coordinates are anchored to the menu-bar display, which is always the first screen.
    private static var quartzPrimaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
    }

    /// `DOCK_FULLSCREEN_SLS_VERDICT=0` -> `.notOnThisScreen` is treated as `.windowed`, as before.
    static let slsVerdictEnabled = DebugSwitch.fullscreenSlsVerdict.isEnabled(in: ProcessInfo.processInfo.environment)

    // MARK: - HoverSwitch Diagnostics

    let hoverLogger = Logger(subsystem: "no.thilip.nitiadock", category: "HoverSwitch")
    static let hoverHotZone: CGFloat = 4.0
    static let hoverSwitchDwell: TimeInterval = 0.35   // switch only after the cursor dwells in the hot zone for ≥ 350ms; passing through does not count
    static let hoverVerboseLogging = false
    /// Repro diagnostics for bottom-edge wake/auto-hide (issue #2 investigation, 2026-07-16). Off by default;
    /// uses plain print() instead of Logger/os_log: the sandbox cannot read `log show`/`log stream`, and only
    /// print() output landing in a redirected file can be read back directly. AppDelegate already
    /// line-buffers stdout (`setvbuf(stdout, nil, _IOLBF, 0)`), so no extra buffering handling is needed
    /// here.
    static let edgeHoverTraceEnabled = DebugSwitch.edgehoverTrace.isEnabled(in: ProcessInfo.processInfo.environment)
    var hoverLastScreenIndex: Int? = nil
    var hoverLastInHotZone: Bool? = nil
    var hoverSwitchTimer: Timer?
    var hoverSwitchTargetScreen: NSScreen? = nil

    /// Taskbar display placement: hover screen switching (dwelling at the bottom edge moves the dock) only
    /// applies in "follow mouse" mode.
    /// Units with a screen assigned by the orchestration layer (③④) never switch screens: every screen has a
    /// bar, there is nothing to move.
    var hoverScreenSwitchingEnabled: Bool {
        switch unitPlacement {
        case .followSettings: return settingsStore.taskbarScreenPlacement.allowsHoverScreenSwitching
        case .fixed: return false
        }
    }

    /// The display UUID of the screen this unit should be on: `.fixed` uses the one given by the
    /// orchestration layer; `.followSettings` uses the fixed screen from settings; nil in follow-mouse mode.
    var fixedDisplayUUID: String? {
        switch unitPlacement {
        case .fixed(let uuid): return uuid
        case .followSettings: return settingsStore.taskbarScreenPlacement.pinnedSelection?.uuid
        }
    }

    // MARK: - Frame Helpers

    // These two do not scale with the dock size and stay static constants.
    private static let outerMargin: CGFloat = PanelLayoutMetrics.standard.outerMargin
    private static let capsuleGap: CGFloat = PanelLayoutMetrics.standard.capsuleGap

}

extension NSScreen {
    private static var lastKnown: NSScreen?

    /// The screen to fall back on when nothing better resolves. `NSScreen.screens` is briefly
    /// empty while every display is disconnected (clamshell, display sleep, a dock reconfiguring),
    /// and indexing it then traps. The last screen that was seen keeps layout code running until
    /// the next screen-parameter change puts real geometry back.
    static var lastResort: NSScreen {
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            lastKnown = screen
            return screen
        }
        return lastKnown ?? NSScreen()
    }
}
