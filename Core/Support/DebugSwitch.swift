import Foundation

/// The single registry of all `DOCK_*` environment variable switches (since 2026-09-05). Switches are always
/// read through here, and no `"DOCK_…"` literal appears in source any more: `Scripts/check_debug_switches.py`
/// (run by CI and release preflight) blocks it. Three polarities:
/// - `.killSwitch`: **on** by default, `=0` turns it off. Leaves a field rollback path for mechanisms that
///   have graduated.
/// - `.trace`: **off** by default, `=1` turns it on. Diagnostic prints / trace files / still-experimental
///   behavior.
/// - `.value`: the raw string, parsed by the call site (milliseconds, material name, level value, ...).
///
/// How to pass one to a dev build: `launchctl setenv K V` -> `open` -> `launchctl unsetenv K`.
enum DebugSwitch: String, CaseIterable, Sendable {
    enum Kind: Sendable { case killSwitch, trace, value }

    // MARK: Mechanism switches, on by default (=0 off)
    /// AX event reads use time-limited background batch reads; =0 falls back to unlimited synchronous reads
    /// on the main thread
    case eventAxAsync = "DOCK_EVENT_AX_ASYNC"
    /// Per-pid skip gate of the 5s periodic reconcile (PeriodicReconcileSkipDecision)
    case reconcileSkip = "DOCK_RECONCILE_SKIP"
    /// Scan probe gate for unmanaged apps (ScanProbeGateDecision)
    case scanGate = "DOCK_SCAN_GATE"
    /// Frontmost pid comes from an event-maintained cache instead of querying NSWorkspace
    case frontmostCache = "DOCK_FRONTMOST_CACHE"
    /// Reuse gate for the full CG table in event reads (CGSnapshotReuseDecision)
    case cgSnapshotReuse = "DOCK_CG_SNAPSHOT_REUSE"
    /// AX element cache (AXElementCache)
    case axElementCache = "DOCK_AX_ELEMENT_CACHE"
    /// Bring to front through the private SkyLight interface
    case skylightFocus = "DOCK_SKYLIGHT_FOCUS"
    /// AX window handle fast path
    case fastWindowHandle = "DOCK_FAST_WINDOW_HANDLE"
    /// Badges read only the messaging apps' Dock elements instead of walking the whole tree
    case badgeTargeted = "DOCK_BADGE_TARGETED"
    /// Stop badge polling when the taskbar is hidden / there is no readable app
    case badgePause = "DOCK_BADGE_PAUSE"
    /// Optimistic state settle gate after minimize
    case minimizeSettleGate = "DOCK_MINIMIZE_SETTLE_GATE"
    /// Frontmost grace during minimize handoff
    case handoffActiveGrace = "DOCK_HANDOFF_ACTIVE_GRACE"
    /// Frontmost prediction after minimize handoff
    case handoffActivePrediction = "DOCK_HANDOFF_ACTIVE_PREDICTION"
    /// "Frontmost judgment is stale" guard in action planning
    case staleActiveGuard = "DOCK_STALE_ACTIVE_GUARD"
    /// Drag landing animation (DragLandingPlan)
    case dragLanding = "DOCK_DRAG_LANDING"
    /// macOS 26 Liquid Glass backing; =0 falls back to frosted glass
    case liquidGlass = "DOCK_LIQUID_GLASS"
    /// Desktop / fullscreen Space switch intent monitor (session event tap)
    case spaceIntent = "DOCK_SPACE_INTENT"
    /// Predictive yielding before native fullscreen entry
    case fullscreenIntent = "DOCK_FULLSCREEN_INTENT"
    /// Fullscreen detection asks SkyLight for the Space type
    case fullscreenSlsVerdict = "DOCK_FULLSCREEN_SLS_VERDICT"
    /// Membership repair for staying on all desktops (issue #19)
    case spaceMembershipRepair = "DOCK_SPACE_MEMBERSHIP_REPAIR"
    /// Pin the persistent panel into a private Space (no graying when swiping between desktops)
    case overlaySpace = "DOCK_OVERLAY_SPACE"
    /// Maximized-window avoidance
    case windowLift = "DOCK_WINDOW_LIFT"
    /// Avoidance writes the frame with animation
    case windowLiftAnim = "DOCK_WINDOW_LIFT_ANIM"
    /// Pause the hover monitor while a menu is open
    case menuHoverSuspend = "DOCK_MENU_HOVER_SUSPEND"
    /// Hover monitor lean mode
    case hoverMonitorLean = "DOCK_HOVER_MONITOR_LEAN"
    /// Pointer polling over the whole taskbar as one area
    case stripHoverPoll = "DOCK_STRIP_HOVER_POLL"
    /// Immediate press feedback on a pressed chip
    case chipPressDown = "DOCK_CHIP_PRESS_DOWN"

    // MARK: Traces / experiments, off by default (=1 on)
    /// Log multi-display ownership writes (category display-trace)
    case displayTrace = "DOCK_DISPLAY_TRACE"
    /// Print the launch feedback timeline
    case launchTrace = "DOCK_LAUNCH_TRACE"
    /// Print chip click probes
    case chipProbe = "DOCK_CHIP_PROBE"
    /// Record click latency by segment (ClickLatencyTrace)
    case clickTrace = "DOCK_CLICK_TRACE"
    /// Hover / frame change trace file (HoverTrace)
    case hoverTrace = "DOCK_HOVER_TRACE"
    /// Edge hover / display switch diagnostic prints
    case edgehoverTrace = "DOCK_EDGEHOVER_TRACE"
    /// Print wheel horizontal scrolling
    case stripWheelTrace = "DOCK_STRIP_WHEEL_TRACE"
    /// chip animation / bubble trace
    case chipAnimTrace = "DOCK_CHIP_ANIM_TRACE"
    /// Enables only the per-frame probes of label width / panel width and the relayout lines (without hover
    /// trace's 8ms stall sampling and pointer polling)
    case labelProbe = "DOCK_LABEL_PROBE"
    /// Space switch intent trace
    case spaceIntentTrace = "DOCK_SPACE_INTENT_TRACE"
    /// Window avoidance trace
    case windowLiftTrace = "DOCK_WINDOW_LIFT_TRACE"
    /// Experiment: fall back to app-level hide when minimize fails
    case minimizeAppFallback = "DOCK_MINIMIZE_APP_FALLBACK"

    // MARK: Value switches (parsed by the call site)
    /// AX read timeout of the periodic reconcile in milliseconds (default 100; 0 = old synchronous path)
    case reconcileAxTimeoutMs = "DOCK_RECONCILE_AX_TIMEOUT_MS"
    /// AX timeout of the launch seed probe in milliseconds (0 = unlimited)
    case seedAxTimeoutMs = "DOCK_SEED_AX_TIMEOUT_MS"
    /// Drag landing flight duration in milliseconds
    case dragFlightMs = "DOCK_DRAG_FLIGHT_MS"
    /// Layout curve for label width changes: "ms,c1x,c1y,c2x,c2y" (shared by both sides, see
    /// `LabelWidthAnimation`)
    case labelAnim = "DOCK_LABEL_ANIM"
    /// Window inventory diagnostic log: 1 / 0 overrides UserDefaults InventoryLog
    case inventoryLog = "DOCK_INVENTORY_LOG"
    /// Experiment: raw NSWindow.Level value of the three taskbar panels
    case panelLevel = "DOCK_PANEL_LEVEL"
    /// Experiment: panel material name
    case panelMaterial = "DOCK_PANEL_MATERIAL"
    /// Experiment: panel saturation
    case panelSaturation = "DOCK_PANEL_SATURATION"
    /// Experiment: panel thickness tier (=1 on)
    case panelThickness = "DOCK_PANEL_THICKNESS"
    /// Experiment: chip pill fill
    case chipPillFill = "DOCK_CHIP_PILL_FILL"
    /// Experiment: inactive tab color
    case labelInactive = "DOCK_LABEL_INACTIVE"
    /// Shelf tile color scheme blue|graphite|light
    case shelfTile = "DOCK_SHELF_TILE"
    /// Glass tuning: clarity
    case liquidGlassClearTint = "DOCK_LIQUID_GLASS_CLEAR_TINT"
    /// Glass tuning: white overlay
    case liquidGlassWhiteOverlay = "DOCK_LIQUID_GLASS_WHITE_OVERLAY"
    /// Glass tuning: dimming
    case liquidGlassDimming = "DOCK_LIQUID_GLASS_DIMMING"
    /// Glass tuning: rim peak
    case liquidGlassBorder = "DOCK_LIQUID_GLASS_BORDER"
    /// Glass tuning: rim edge
    case liquidGlassBorderEdge = "DOCK_LIQUID_GLASS_BORDER_EDGE"
    /// Glass tuning: rim corner cut
    case liquidGlassBorderCut = "DOCK_LIQUID_GLASS_BORDER_CUT"
    /// Glass tuning: rim corner spread
    case liquidGlassBorderSpread = "DOCK_LIQUID_GLASS_BORDER_SPREAD"
    /// Glass tuning: rim line width
    case liquidGlassBorderWidth = "DOCK_LIQUID_GLASS_BORDER_WIDTH"
    /// Glass tuning: inner rim
    case liquidGlassBorderInner = "DOCK_LIQUID_GLASS_BORDER_INNER"
    /// Glass tuning: backdrop material opacity
    case liquidGlassBackgroundOpacity = "DOCK_LIQUID_GLASS_BACKGROUND_OPACITY"
    /// Glass tuning: window blur radius
    case liquidGlassWindowBlur = "DOCK_LIQUID_GLASS_WINDOW_BLUR"
    /// Glass tuning: content inset
    case liquidGlassContentInset = "DOCK_LIQUID_GLASS_CONTENT_INSET"

    var kind: Kind {
        switch self {
        case .eventAxAsync, .reconcileSkip, .scanGate, .frontmostCache,
             .cgSnapshotReuse, .axElementCache, .skylightFocus, .fastWindowHandle,
             .badgeTargeted, .badgePause, .minimizeSettleGate, .handoffActiveGrace,
             .handoffActivePrediction, .staleActiveGuard, .dragLanding, .liquidGlass,
             .spaceIntent, .fullscreenIntent, .fullscreenSlsVerdict, .spaceMembershipRepair,
             .overlaySpace, .windowLift, .windowLiftAnim,
             .menuHoverSuspend, .hoverMonitorLean, .stripHoverPoll, .chipPressDown:
            return .killSwitch
        case .displayTrace, .launchTrace, .chipProbe, .clickTrace,
             .hoverTrace, .edgehoverTrace, .stripWheelTrace, .chipAnimTrace, .labelProbe,
             .spaceIntentTrace, .windowLiftTrace, .minimizeAppFallback:
            return .trace
        case .reconcileAxTimeoutMs, .seedAxTimeoutMs, .dragFlightMs, .labelAnim, .inventoryLog,
             .panelLevel, .panelMaterial, .panelSaturation, .panelThickness,
             .chipPillFill, .labelInactive, .shelfTile, .liquidGlassClearTint,
             .liquidGlassWhiteOverlay, .liquidGlassDimming, .liquidGlassBorder, .liquidGlassBorderEdge,
             .liquidGlassBorderCut, .liquidGlassBorderSpread, .liquidGlassBorderWidth, .liquidGlassBorderInner,
             .liquidGlassBackgroundOpacity, .liquidGlassWindowBlur, .liquidGlassContentInset:
            return .value
        }
    }

    /// Raw string (unset -> nil). The only way to read value switches; boolean ones can also use it to see
    /// the raw text.
    func value(in environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        environment[rawValue]
    }

    /// Boolean read; polarity comes from `kind`, exactly equivalent to the call sites' `!= "0"` / `== "1"`
    /// before the migration.
    func isEnabled(in environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        switch kind {
        case .killSwitch: return environment[rawValue] != "0"
        case .trace: return environment[rawValue] == "1"
        case .value:
            assertionFailure("\(rawValue) is a value switch; read it with value(in:)")
            return environment[rawValue] != nil
        }
    }
}
