import AppKit
import CoreServices
import SwiftUI

/// A chip that represents an app by bundle identifier rather than a concrete window.
/// Renders the three launcher states (not running / running-no-window / running-hidden)
/// and handles tap-to-launch, tap-to-reopen, and the launch bounce animation.
///
/// Shared by the drawer (collected apps, scale 0.7) and the main strip (messaging
/// and kept apps, scale 1.0). Call-site differences are injected via
/// `membershipItems` (Keep in Dock / Pin to messaging zone).

struct LauncherChip: View {
    let bundleID: String
    let isRunning: Bool   // supplied by the displayed zone's runtime/process projection
    let isHidden: Bool    // supplied by the displayed zone's runtime/process projection
    /// Whether Finder has a real window right now (not the app-level fallback). **Only the Finder branch of
    /// the default left-click behavior reads it**: Finder cannot be hidden and must open the home folder when
    /// it has no window. Hence finder in the name; do not use it as a generic "has a window". **Deliberately
    /// no default**: a drawer call that omits it would "open a new home folder window on every Finder click",
    /// and that must be a compile error.
    let finderHasRealWindow: Bool
    /// Runtime-owned launch session state. The chip only renders this state; it does
    /// not infer readiness from process state or own a second launch timeout.
    let isLaunching: Bool
    /// Size tier factor (the bar passes `DockSize.scale`, the drawer a constant 0.7). **Deliberately no
    /// default**: omitting it must be a compile error, see the project rule "Taskbar Size Tiers".
    let scale: CGFloat
    /// Hover effect style. **Also deliberately no default**: omitting it must be a compile error, same reason
    /// as `scale`. The drawer call site hardcodes `.quiet` on purpose (the drawer is unaffected by this
    /// setting, 2026-08-02 / 2026-08-17).
    let hoverStyle: HoverStyle
    /// Where hover comes from. The taskbar passes `.resolved(…)` (computed by the single bar-wide tracking
    /// area), the drawer passes `.selfTracked` (that panel has no tracking area). **Deliberately no
    /// default**, same reason as `scale` / `hoverStyle`.
    let hoverInput: ChipHoverInput
    /// Data source for the Dock-style window list (evaluated only when the context menu is built; reads the
    /// snapshot, no AX). **Deliberately no default**: an app-level icon that omits it = the whole window list
    /// silently disappears, and that must be a compile error.
    let windowEntriesProvider: () -> [WindowMenuEntry]
    /// Click a window row -> activate (restores a minimized one). **Deliberately no default**, same reason as
    /// above.
    let onActivateWindow: (String) -> Void
    /// Membership / management menu items (end of the context menu), such as "Keep in Dock" and "Pin to
    /// messaging zone". Empty array = no membership items.
    var membershipItems: [LauncherMembershipItem] = []
    /// fork: no running dot under this icon. Set for the single icon an app collapses to on a dock whose
    /// display its windows are not on (`ForkForeignWindowCollapse`): the dot belongs on the dock where the
    /// app's windows are.
    var forkSuppressRunningDot = false
    /// Unread badge text (a messaging app's card: the icon in the messaging zone, or the kept placeholder in
    /// the regular zone), `nil` = not drawn. Drawn inside the chip rather than stacked in a ZStack by the
    /// caller, so it follows hover scale-up, press shrink and size-tier scaling. See `ChipBadgeView`.
    var badgeText: String? = nil
    /// Whether this icon's cell is empty right now because it is **being carried**
    /// (`DragController.hiddenSlotPayload`). The press scale is cleared as soon as it turns true: a reorder
    /// moves it and SwiftUI cancels the press gesture, so `isTapPressed` can only be reset by the 1s watchdog
    /// and may still be 0.93 when it reappears on landing, a visible gap from the carrier that settled at
    /// 1.0. Same reason as `ChipView.slotHidden`.
    var slotHidden: Bool = false
    /// Hover feedback hold (only the `.selfTracked` drawer needs it): the cell that just landed while the
    /// pointer has not moved (`DragController.hoverHoldPayload`) and the cell being carried. `.onHover` is
    /// still true while the cell is transparent, so without the hold it would be at 1.10 the moment it
    /// reappears on landing: the drawer's form of the quiet style's "landing jitter". The taskbar uses
    /// `.resolved(…)`, where hover is suppressed at the source by the bar-wide tracking area, and passes the
    /// default false here.
    var hoverSuppressed: Bool = false
    /// When set, replaces the default tap behavior (drawer show/hide toggle). Used by
    /// app-level strip entries that must reopen a missing main window.
    var onTap: (() -> Void)? = nil
    /// Starts the runtime-owned launch session and returns whether launch dispatch
    /// succeeded. A false result keeps the drawer open and never starts local bounce.
    var onLaunch: () -> Bool = { false }
    /// Fired when the tap dispatches an "open" action: unhide+activate (running but not active) or launch (not running).
    /// Hide taps (app is active → minimize) do NOT fire this: the drawer stays open for those.
    /// Only set by DrawerView; strip messaging chips leave it nil.
    var onPrimaryAction: (() -> Void)? = nil

    private let theme = DockThemeTokens.standard
    /// See `EnvironmentValues.isDragCarrierSnapshot`: no dot and no baked shadow when capturing the copy.
    @Environment(\.isDragCarrierSnapshot) private var isDragCarrierSnapshot

    /// Used only with `.selfTracked` (drawer). The taskbar uses `.resolved(…)` and this state stays
    /// untouched.
    @State private var selfHovering = false
    @State private var bounceUp = false
    @State private var bounceTimer: Timer?
    /// Press confirmation pulse. Before 2026-08-11 this component had **no press feedback at all**: the
    /// messaging zone (main window closed / not running), kept icons and drawer icons did not react to a
    /// press, while window cards and the drawer capsule did. A pure view-layer signal that never feeds the
    /// planner / frontmost axis (project rule).
    @State private var isTapPressed = false
    private static let launchTraceEnabled =
        DebugSwitch.launchTrace.isEnabled(in: ProcessInfo.processInfo.environment)

    private var isHovering: Bool {
        guard !hoverSuppressed else { return false }
        switch hoverInput {
        case let .resolved(value): return value
        case .selfTracked: return selfHovering
        }
    }

    /// Master gate for hover visuals: always false in the "quiet" style, so the icon does not scale, the name
    /// does not appear and no animation transaction is created.
    private var showsHover: Bool { hoverStyle.showsExpressiveHover(isHovering: isHovering) }
    /// Hover feedback for the quiet style (always false in the standard style). See
    /// `HoverStyle.showsQuietHoverFeedback`.
    private var quietHoverFeedback: Bool {
        hoverStyle.showsQuietHoverFeedback(isHovering: isHovering)
    }

    var body: some View {
        let visual = LauncherChipVisualPlan.visual(isRunning: isRunning)
        // **Hover changes no pixels, so no animation driver is attached**, word for word the same as
        // `ChipView.bareIconChip` (2026-08-17: removed there first and missed here, running an empty 0.18s
        // animation for nothing). See the comment on `bareIconChip`: when the main thread is busy macOS
        // coalesces mouse-move events and a sweep skips cells.
        //
        // **Here especially the transaction must not reach the ancestor chain**: the launch bounce
        // (`bounceUp`) lives in the icon below, and an ancestor's hover transaction would hijack it. The
        // quiet style's highlight therefore uses a `.background` sibling layer.
        let hover = ChipHoverVisual.resolve(progress: 0, scale: scale)
        let _ = ChipAnimationTrace.record(
            chipID: bundleID,
            kind: "launcher",
            visual: hover,
            isTapPressed: isTapPressed,
            showsHover: showsHover
        )
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            Image(nsImage: AppIconResolver.icon(for: bundleID))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: hover.bareIconSize, height: hover.bareIconSize)
                .clipShape(RoundedRectangle(cornerRadius: hover.bareIconSize / 4, style: .continuous))
                .offset(y: bounceUp ? -6 : 0)
                .animation(.easeInOut(duration: 0.25), value: bounceUp)
            // Slot height = the **resting** icon size. A slot smaller than the icon overflows downward as a
            // whole (.top alignment), which gives "icons of open apps sit at a different height than those of
            // closed ones", and this view draws exactly the closed kind. Must be word for word the same as
            // `ChipView`'s iconOnly branch.
            .frame(width: ChipPillMetrics.cardWidth * scale,
                   height: ChipPillMetrics.bareIconSlot * scale,
                   alignment: .top)
            Spacer(minLength: 0)
        }
        .frame(width: ChipPillMetrics.cardWidth * scale,
               height: ChipPillMetrics.chipHeight * scale)
        // Same as `ChipView`: the dragged copy draws no dot (as in the native Dock).
        .overlay(alignment: .bottom) {
            if visual.showsRunningDot && !isDragCarrierSnapshot && !forkSuppressRunningDot {
                ForkRunningDot(theme: theme)
            }
        }
        // Unread badge: **must be attached before the two scales** (2026-08-17). See `ChipBadgeView`.
        .overlay(alignment: .topTrailing) {
            if let badgeText {
                ChipBadgeView(text: badgeText, scale: scale)
            }
        }
        // The running dot used to be attached **after** the scale-up (the dot did not scale), inconsistent
        // with `ChipView.bareIconChip`; aligned in the same change: both places scale "icon + dot + badge" as
        // a whole.
        .chipQuietHoverScale(quietHoverFeedback,
                             cardWidth: ChipPillMetrics.cardWidth * scale,
                             scale: scale)
        .chipPressScale(isTapPressed)
        .contentShape(Rectangle())
        // On the taskbar hover is computed by the bar-wide tracking area and passed in; only the drawer
        // (`.selfTracked`) attaches its own `.onHover`, because that panel has no tracking area. See
        // `StripHoverResolution` for the cause.
        .modifier(SelfTrackedHover(enabled: hoverInput == .selfTracked, isHovering: $selfHovering))
        .onChange(of: isHovering) { hovering in
            trace("isHovering=\(hovering)")
            ChipAnimationTrace.event(
                chipID: bundleID,
                kind: "launcher",
                event: ChipAnimationTraceEvent.hover(hovering),
                isTapPressed: isTapPressed,
                showsHover: hoverStyle.isExpressive && hovering
            )
        }
        .onTapGesture { handlePrimaryTap() }
        // During a launch session a click is a no-op anyway (project rule), so press feedback would be
        // misleading; it also avoids stacking an animation transaction on the same icon as the finite bounce
        // (bounceUp offset).
        .chipPressGesture(
            isPressed: $isTapPressed,
            isEnabled: !isLaunching,
            onEvent: { pressed in
                ChipAnimationTrace.event(
                    chipID: bundleID,
                    kind: "launcher",
                    event: ChipAnimationTraceEvent.tap(pressed),
                    isTapPressed: pressed,
                    showsHover: showsHover
                )
            }
        )
        .nativeContextMenu { buildLauncherMenu() }
        .help(displayName)
        // Clear the press as soon as the cell empties (see `slotHidden`). The icon is transparent now, so
        // nobody sees this spring-back.
        .onChange(of: slotHidden) { hidden in
            if hidden, isTapPressed { isTapPressed = false }
        }
        .onAppear {
            trace("appear isLaunching=\(isLaunching)")
            if isLaunching { startBounce() }
        }
        .onDisappear {
            trace("disappear cleanup")
            cleanupBounce()
        }
        .onChange(of: isLaunching) { newValue in
            trace("isLaunching=\(newValue)")
            if newValue { startBounce() } else { stopBounce() }
        }
        .onChange(of: bounceUp) { trace("bounceUp=\($0)") }
    }

    private func buildLauncherMenu() -> NSMenu {
        let menu = NSMenu()
        // Evaluated once, at the moment of the right-click; not fetched at all in the not-running display
        // state (the list criterion follows the display zone).
        let windowEntries = isRunning ? windowEntriesProvider() : []
        // The menu's running state follows "the display state of the zone the icon is in" (isRunning prop)
        // and no longer asks NSWorkspace separately. Otherwise an icon in the launch zone whose process is
        // still alive (does not quit on window close / resident) would wrongly offer "Hide / Quit",
        // contradicting its dimmed "quit" look.
        let kinds = LauncherMenuPlan.itemKinds(isRunning: isRunning,
                                               isHidden: isHidden,
                                               hasWindows: !windowEntries.isEmpty,
                                               hasMembership: !membershipItems.isEmpty)
        // The app object is fetched only when Show/Hide/Quit will actually run; if it cannot be fetched the
        // item is skipped (fallback for a briefly stale snapshot).
        let runningApps = Self.regularRunningApplications(bundleID: bundleID)
        for kind in kinds {
            switch kind {
            case .windowList:
                AppMenuBuilder.appendWindowList(to: menu, entries: windowEntries, activate: onActivateWindow)
            case .open:
                // Context menu "Open": reuses the runtime launch path but does not trigger onPrimaryAction,
                // otherwise opening a drawer icon from the context menu would also close the drawer.
                menu.addItem(ClosureMenuItem(String(localized: "Open")) { launch(firePrimaryAction: false) })
            case .recentDocuments:
                // Finder's "Recents" are recently used folders (FXRecentFolders), the same criterion as the
                // Finder card on the bar.
                if FinderTaskbarPolicy.isFinder(bundleID) {
                    AppMenuBuilder.appendFinderRecentFolders(to: menu)
                } else {
                    AppMenuBuilder.appendRecentDocuments(to: menu, bundleID: bundleID)
                }
            case .show:
                if !runningApps.isEmpty {
                    menu.addItem(ClosureMenuItem(String(localized: "Show")) {
                        for app in runningApps { _ = app.unhide() }
                        runningApps.first?.activate(options: .activateIgnoringOtherApps)
                    })
                }
            case .hide:
                if !runningApps.isEmpty {
                    menu.addItem(ClosureMenuItem(String(localized: "Hide")) {
                        for app in runningApps { _ = app.hide() }
                    })
                }
            case .quit:
                if !runningApps.isEmpty {
                    // Quit is always the last item, so this branch adds its own leading separator (the
                    // membership section is already placed before it); same guard as .membership: none is
                    // added when the menu is empty or already ends with a separator, avoiding a double line.
                    if !menu.items.isEmpty, menu.items.last?.isSeparatorItem == false {
                        menu.addItem(.separator())
                    }
                    AppMenuBuilder.appendQuitItems(
                        to: menu,
                        bundleID: bundleID,
                        onForceQuit: { for app in runningApps { _ = app.forceTerminate() } }
                    ) {
                        for app in runningApps { _ = app.terminate() }
                    }
                }
            case .membership:
                // A separator is added before the membership section only when "the menu is non-empty and
                // does not end with a separator": this separates Open / recent files from the membership
                // items and avoids a double line when the recent files section already has a trailing
                // separator (it also covers running-state actions skipped by a race).
                if !menu.items.isEmpty, menu.items.last?.isSeparatorItem == false {
                    menu.addItem(.separator())
                }
                for item in membershipItems {
                    menu.addItem(AppMenuBuilder.membershipItem(item))
                }
                AppMenuBuilder.appendForkSettingsItem(to: menu, separated: false)   // fork
            }
        }
        AppMenuBuilder.appendForkSettingsItem(to: menu)   // fork
        return menu
    }

    /// The single left-click gate covers both injected app-level behavior and the
    /// default drawer behavior. Runtime still performs the authoritative duplicate
    /// check for clicks that arrive before SwiftUI publishes the new launch state.
    private func handlePrimaryTap() {
        guard !isLaunching else {
            trace("tap ignored while launching")
            return
        }
        if let onTap { onTap() } else { handleTap() }
    }

    private func handleTap() {
        Self.performDefaultTap(bundleID: bundleID, isRunning: isRunning,
                               finderHasRealWindow: finderHasRealWindow,
                               launch: { launch() }, onOpen: onPrimaryAction)
    }

    /// Default left-click behavior when no `onTap` is injected (what drawer icons use). The only reason it is
    /// static and reusable by `DrawerView`: clicking the carrier during the return flight
    /// (`DragController.carrierClicks`) must run **the same** logic, rather than copying "hide if frontmost,
    /// otherwise show" somewhere else.
    ///
    /// Finder is the only exception (a path that appeared only after the drawer was opened to it on
    /// 2026-08-20): it **cannot be hidden** (`hide()` simply fails), and with no window `openApplication`
    /// only activates without opening one, so a click looks like nothing happened. Finder is therefore never
    /// hidden, and opens the home folder when it has no real window, the same criterion as the resident card
    /// on the bar (`LifecycleActionPlanner` + `AccessibilitySource`).
    /// - Parameters:
    ///   - finderHasRealWindow: whether Finder has a real window right now. Only the Finder branch uses it,
    ///     but it has no default: omitting it would silently take the wrong branch.
    ///   - launch: how to launch when not running (the caller decides whether to also run `onOpen`).
    ///   - onOpen: side action on show (unhide + open); the drawer passes "close the drawer".
    static func performDefaultTap(bundleID: String, isRunning: Bool, finderHasRealWindow: Bool,
                                  launch: () -> Void, onOpen: (() -> Void)?) {
        if isRunning {
            let runningApps = regularRunningApplications(bundleID: bundleID)
            if FinderTaskbarPolicy.isFinder(bundleID) {
                for app in runningApps { _ = app.unhide() }
                if finderHasRealWindow {
                    runningApps.first?.activate(options: .activateIgnoringOtherApps)
                } else {
                    NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser)
                }
                onOpen?()
                return
            }
            if runningApps.contains(where: \.isActive) {
                // Frontmost -> hide (minimize): the drawer stays open
                for app in runningApps { _ = app.hide() }
            } else {
                // Not active / hidden / window closed -> show: close the drawer
                guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
                for app in runningApps { _ = app.unhide() }
                NSWorkspace.shared.openApplication(at: appURL, configuration: .init(), completionHandler: nil)
                onOpen?()
            }
        } else {
            launch()
        }
    }

    private var displayName: String {
        AppDisplayNameResolver.displayName(for: bundleID)
    }

    private static func regularRunningApplications(bundleID: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter {
            $0.activationPolicy == .regular
                && ProcessLiveness.isAlive(pid: $0.processIdentifier)
        }
    }

    /// Every leg is a finite animation. The common-mode timer only schedules the next
    /// leg, so hover/layout transactions cannot turn the bounce into a repeatForever
    /// animation that survives launch completion.
    private func startBounce() {
        guard bounceTimer == nil else { return }
        bounceUp = true

        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            bounceUp.toggle()
        }
        timer.tolerance = 0.02
        bounceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        trace("bounce timer started")
    }

    private func stopBounce() {
        bounceTimer?.invalidate()
        bounceTimer = nil
        bounceUp = false
        trace("bounce timer stopped")
    }

    /// View teardown is local cleanup only. It must not cancel the runtime session;
    /// a newly-created drawer chip resumes from the external `isLaunching` value.
    private func cleanupBounce() {
        bounceTimer?.invalidate()
        bounceTimer = nil
        bounceUp = false
    }

    /// - Parameter firePrimaryAction: a left click passes true (keeps the original behavior: a drawer icon
    ///   closes the drawer after launching); the context menu "Open" passes false, launching only without
    ///   closing the drawer. runtime owns URL resolution,
    ///   launch dispatch, readiness, timeout, and duplicate-session rejection.
    private func launch(firePrimaryAction: Bool = true) {
        guard !isLaunching else {
            trace("launch ignored while launching")
            return
        }
        guard onLaunch() else {
            trace("runtime rejected launch")
            return
        }
        trace("runtime accepted launch")
        if firePrimaryAction { onPrimaryAction?() }
    }

    private func trace(_ message: String) {
        guard Self.launchTraceEnabled else { return }
        let timestamp = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        print("[launch] BOUNCE bid=\(bundleID) t=\(timestamp) \(message)")
    }
}

// MARK: - App Display Name Resolver

/// Resolves human-readable names for a bundle identifier, with caching (bundle plist
/// reads involve disk IO and these get called from SwiftUI body evaluations).
/// Also answers "does this window title look like the app's main window?", the
/// Plan B heuristic: a messaging app's main window is the one titled like the app
/// itself (WeChat under its Chinese or English name / Telegram…), verified to hold for WeChat/QQ/Telegram.
enum AppDisplayNameResolver {
    private static let displayNameCache = AppDisplayNameCache()
    /// App name matching uses the monotonic registry and **no longer queries LaunchServices every frame**
    /// (cause and cost are in the comment on `AppNameRegistry`: one transient empty lookup dropped Feishu and
    /// WeChat out of messaging zone absorption at once).
    private static let nameRegistry = AppNameRegistry(
        bundleNamesLoader: bundleDerivedNames(for:),
        runningNameLoader: { bundleID in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first?.localizedName
        }
    )
    private static let workspaceObservers: [NSObjectProtocol] = {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]
        return names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier else { return }
                invalidateDisplayName(for: bundleID)
                // The launch notification carries an `NSRunningApplication`, so the name is free: this saves
                // a lookup and gives a just-launched app an authoritative name to compare from its first
                // frame.
                if name == NSWorkspace.didLaunchApplicationNotification,
                   let localized = app.localizedName {
                    nameRegistry.observe(name: localized, for: bundleID)
                }
            }
        }
    }()

    static func displayName(for bundleID: String) -> String {
        _ = workspaceObservers
        return displayNameCache.value(for: bundleID) {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
               let name = running.localizedName, !name.isEmpty {
                nameRegistry.observe(name: name, for: bundleID)   // record it in the registry while here, free
                return name
            }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return nil
            }
            return notRunningDisplayName(at: url)
        }
    }

    /// Display name of an app that is not running. **Must come from the same source as the running
    /// `localizedName`**, otherwise the same app switches names across "not running -> launched -> quit"
    /// (v0.9.6 user feedback: on a Chinese system, System Settings showed its English name while not
    /// running).
    ///
    /// The order is by strength of evidence, each measured in a real .app on 2026-08-27 (a CLI measures
    /// wrongly, because a command-line process's preferred language is en,
    /// see item 1):
    /// 1. Spotlight's `kMDItemDisplayName` follows the **system language**, the same source as
    ///    `localizedName`; the `Bundle` chain follows **this process's** preferred language and diverges once
    ///    "Language & Region ▸ Applications" changes it for the app.
    /// 2. Falls to the bundle only when Spotlight indexing is off. Both keys must be tried here: system apps
    ///    like System Settings have no `zh-Hans.lproj`, their Chinese name exists only in
    ///    `InfoPlist.loctable`, and the loctable only has `CFBundleName`. The original implementation asked
    ///    the localized dictionary only for `CFBundleDisplayName`, and on a miss jumped straight to the
    ///    **unlocalized** `CFBundleName`, which was the direct cause of that bug.
    private static func notRunningDisplayName(at url: URL) -> String? {
        if let item = MDItemCreateWithURL(nil, url as CFURL),
           let spotlight = sanitizedDisplayName(MDItemCopyAttribute(item, kMDItemDisplayName) as? String) {
            return spotlight
        }
        let bundle = Bundle(url: url)
        for dict in [bundle?.localizedInfoDictionary, bundle?.infoDictionary] {
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let name = sanitizedDisplayName(dict?[key] as? String) { return name }
            }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// When Finder's "Show all filename extensions" is on, the sources above carry a `.app` suffix, which
    /// should not appear in the bubble.
    private static func sanitizedDisplayName(_ raw: String?) -> String? {
        guard var name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        if name.hasSuffix(".app"), name.count > 4 {
            name = String(name.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return name.isEmpty ? nil : name
    }

    static func invalidateDisplayName(for bundleID: String) {
        displayNameCache.invalidate(bundleID: bundleID)
        nameRegistry.invalidate(bundleID: bundleID)
    }

    static func titleMatchesAppName(_ title: String, bundleID: String) -> Bool {
        _ = workspaceObservers
        return nameRegistry.matches(title: title, bundleID: bundleID)
    }

    /// For diagnostics: which spellings of this app the name table knows right now
    /// (`MessagingZoneDiagnostics`).
    static func knownAppNames(for bundleID: String) -> Set<String> {
        _ = workspaceObservers
        return nameRegistry.knownNames(for: bundleID)
    }

    /// Localized + unlocalized bundle names (covers e.g. WeChat's Chinese name vs WeChat). Normalized and
    /// handed to the registry cache. Measured on this machine: Feishu/WeChat resolve only to English names
    /// here (`{feishu, lark}` / `{wechat}`), and Chinese titles match only through the `localizedName`
    /// remembered in the registry.
    private static func bundleDerivedNames(for bundleID: String) -> Set<String> {
        var names: Set<String> = []
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let bundle = Bundle(url: url)
            for dict in [bundle?.localizedInfoDictionary, bundle?.infoDictionary] {
                for key in ["CFBundleDisplayName", "CFBundleName"] {
                    if let name = dict?[key] as? String, !name.isEmpty {
                        names.insert(AppNameRegistry.normalize(name))
                    }
                }
            }
            names.insert(AppNameRegistry.normalize(url.deletingPathExtension().lastPathComponent))
        }
        return names
    }
}

/// Attaches `.onHover` only on panels without an external tracking area (the drawer).
///
/// The condition is an `if`/`else` rather than "always attach, ignore the value when unused": each extra
/// tracking area is one more event dispatch, and this round of changes was made **precisely to stop depending
/// on per-card enter/exit events** (see `StripHoverResolution`). `enabled` never flips at a given call site,
/// so the `_ConditionalContent` identity switch never actually happens.
private struct SelfTrackedHover: ViewModifier {
    let enabled: Bool
    @Binding var isHovering: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.onHover { isHovering = $0 }
        } else {
            content
        }
    }
}
