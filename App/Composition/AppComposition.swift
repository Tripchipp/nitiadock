import AppKit
import Combine
import CoreGraphics
import Foundation
import os

@MainActor
final class DebugRuntimeState: ObservableObject {
    @Published private(set) var feedbackEntriesByWindowID: [String: IntentFeedbackState.Entry] = [:]
    @Published private(set) var observationStatusText: String = "Starting"

    func setFeedbackEntries(_ entries: [String: IntentFeedbackState.Entry]) {
        guard entries != feedbackEntriesByWindowID else { return }
        feedbackEntriesByWindowID = entries
    }

    func setObservationStatusText(_ text: String) {
        guard text != observationStatusText else { return }
        observationStatusText = text
    }
}

@MainActor
final class AppRuntime: ObservableObject {
    @Published private(set) var snapshot: DockSnapshot = .empty
    @Published private(set) var hasRequiredPermissions: Bool = false
    let debugState: DebugRuntimeState
    /// Optimistic state overlay (see the OptimisticWindowState comment). UI rendering and toggle planning
    /// read this first; cleared once the snapshot confirms the prediction or it times out (silent revert).
    @Published private(set) var optimisticStatesByWindowID: [String: OptimisticWindowState] = [:]
    /// Explicit home of a "running but windowless" icon (multi-display ④: bundleID -> display UUID, session
    /// only, not persisted). Written by cross-display drags. **Not stored in the window inventory**: the
    /// inventory may have no entry for this app at all (a kept app with zero seats is shown as a
    /// placeholder), so the write would be lost and the card would snap back to the main display. Cleared as
    /// soon as the app gets a real window; after that the inventory's "display the window was last on" takes
    /// over. Projection order: explicit home > last display in the inventory > main display.
    @Published private(set) var noWindowHomeByBundle: [String: String] = [:]
    private static let displayTraceEnabled = DebugSwitch.displayTrace.isEnabled(in: ProcessInfo.processInfo.environment)
    private let displayTraceLogger = Logger(subsystem: "no.thilip.nitiadock", category: "display-trace")
    /// "Window appearance gate" (2026-06-18): an app the user launched by clicking in the drawer is recorded
    /// here until it gets a real window. The drawer uses this to **keep it bouncing in the launch zone**
    /// instead of stopping the bounce or moving it to the running zone as soon as the process appears (GUI
    /// app process ready ≠ UI ready). .regular apps wait for a real window; .accessory menu bar apps
    /// (Tailscale and the like) are released once the process has finished launching and its policy is
    /// stable, so they don't get stuck. Cleared only when a real window appears, the app is confirmed
    /// windowless, the launch fails, or the 20s timeout fires.
    @Published private(set) var launchingBundleIDs: Set<String> = []

    private struct LaunchProcessIdentity: Equatable {
        let pid: pid_t
        let startTimeSec: Int64
        let startTimeUsec: Int64
    }

    private struct LaunchWindowIdentity: Hashable {
        let chipID: String
        let pid: pid_t
        let startTimeSec: Int64
        let startTimeUsec: Int64
    }

    private struct LaunchSession {
        let bundleID: String
        let token: UInt64
        let startedAt: TimeInterval
        let baselineRealWindows: Set<LaunchWindowIdentity>
        let bundleDeclaresNoWindow: Bool
        var app: NSRunningApplication?
        var processIdentity: LaunchProcessIdentity?
        var openFailed = false
        var policyRecheckTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
        var lastTraceClassification: String?
    }

    private var launchSessions = LaunchSessionTokenRegistry<LaunchSession>()
    /// `activateWhenAppears`' one pending request; the generation retires its timeout.
    private var pendingAppearanceFind: (@MainActor (DockSnapshot) -> String?)?
    private var appearanceGeneration: UInt64 = 0

    private let tracker: AppTracker
    private let displayTableProvider: @MainActor () -> WindowDisplayAttribution.Table
    private let intentPipeline = IntentPipeline(actionPlanning: LifecycleActionPlanner())
    private let actionExecutor = PlatformActionExecutor()
    private let isAccessibilityTrusted: () -> Bool
    private var snapshotSubscription: AnyCancellable?
    private var feedbackTimer: Timer?
    private var startedAt: Date?
    var onToggleDrawer: (() -> Void)?

    private let debugSnapshotLogger = Logger(subsystem: "no.thilip.nitiadock", category: "debug-snapshot")
    private let chipProbeLogger = Logger(subsystem: "no.thilip.nitiadock", category: "ChipProbe")
    private let launchLogger = Logger(subsystem: "no.thilip.nitiadock", category: "Launch")
    private static let launchTraceEnabled = DebugSwitch.launchTrace.isEnabled(in: ProcessInfo.processInfo.environment)
    private static let chipProbeEnabled = DebugSwitch.chipProbe.isEnabled(in: ProcessInfo.processInfo.environment)
    /// Kill switch for the minimize settle gate (default on). When off, no minimize anchor is recorded and
    /// nothing is held; the dispatch path is bit-for-bit the old behavior.
    private static let settleGateEnabled = DebugSwitch.minimizeSettleGate.isEnabled(in: ProcessInfo.processInfo.environment)
    /// Kill switch for the transition grace (default on). When off, sibling takeover clearing reverts to the
    /// original 2026-08-22 semantics (no transition exemption).
    private static let handoffActiveGraceEnabled = DebugSwitch.handoffActiveGrace.isEnabled(in: ProcessInfo.processInfo.environment)
    /// Kill switch for handoff prediction (default on). When off, a collapse handoff no longer writes an
    /// optimistic .active prediction for the window taking over.
    private static let handoffActivePredictionEnabled = DebugSwitch.handoffActivePrediction.isEnabled(in: ProcessInfo.processInfo.environment)
    private static let launchPolicyRecheckDeadlines: [TimeInterval] = [1.5, 3.0, 5.0]

    init(
        inventoryLog: WindowInventoryAnomalyLog = WindowInventoryAnomalyLog(),
        debugState: DebugRuntimeState? = nil,
        displayTableProvider: @escaping @MainActor () -> WindowDisplayAttribution.Table = {
            DisplayIdentity.attributionTable()
        },
        isAccessibilityTrusted: @escaping () -> Bool = { PermissionService().hasRequiredPermissions() }
    ) {
        tracker = AppTracker(inventoryLog: inventoryLog, displayTableProvider: displayTableProvider)
        self.displayTableProvider = displayTableProvider
        self.debugState = debugState ?? DebugRuntimeState()
        self.isAccessibilityTrusted = isAccessibilityTrusted
    }

    func start() {
        guard snapshotSubscription == nil else { return }
        startedAt = Date()
        hasRequiredPermissions = isAccessibilityTrusted()
        tracker.start()

        snapshotSubscription = tracker.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newSnapshot in
                self?.handleSnapshotUpdate(newSnapshot)
            }

        // The timer is not started here: at launch both the feedback state and the optimistic state are
        // empty, so there is nothing to reconcile. Its lifetime is decided solely by updateFeedbackTimer()
        // (see that method's comment).
        updateFeedbackTimer()
    }

    /// Whether the runtime is running. The timer's restart gate reads this; no parallel bool flag is added,
    /// so two states can't disagree (`stop()` sets subscription to nil).
    private var isRunning: Bool { snapshotSubscription != nil }

    func stop() {
        tracker.stop()
        snapshotSubscription?.cancel()
        snapshotSubscription = nil
        feedbackTimer?.invalidate()
        feedbackTimer = nil
        for held in heldActionsByWindowID.values { held.workItem.cancel() }
        heldActionsByWindowID.removeAll()
        recentMinimizeDispatchAtByWindowID.removeAll()
        pendingAppearanceFind = nil
        appearanceGeneration &+= 1
        stopLaunchSessions()
    }

    deinit {
        feedbackTimer?.invalidate()
        snapshotSubscription?.cancel()
        for held in heldActionsByWindowID.values { held.workItem.cancel() }
        for entry in launchSessions.currentEntries {
            entry.value.policyRecheckTask?.cancel()
            entry.value.timeoutTask?.cancel()
        }
    }

    func exportDebugSnapshot() {
        do {
            let url = try TaskbarDebugSnapshotExporter.export(snapshot: snapshot)
            debugSnapshotLogger.info("exported debug snapshot path=\(url.path, privacy: .public)")
        } catch {
            debugSnapshotLogger.error("export failed error=\(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Actions

    func toggle(windowID: String) { trigger(.toggle(WindowID(rawValue: windowID))) }
    func activate(windowID: String) { trigger(.activate(WindowID(rawValue: windowID))) }
    func minimize(windowID: String) { trigger(.minimize(WindowID(rawValue: windowID))) }
    func hide(windowID: String) { trigger(.hide(WindowID(rawValue: windowID))) }
    func close(windowID: String) { trigger(.close(WindowID(rawValue: windowID))) }
    func quit(windowID: String) { trigger(.quit(WindowID(rawValue: windowID))) }
    func newWindow(windowID: String) { trigger(.newWindow(WindowID(rawValue: windowID))) }

    /// Activates the window `find` picks as soon as the inventory shows it, for a window another app
    /// opens on request without activating itself, since activating that app would also raise its
    /// last-used window. If none shows up within `timeout` the request is simply dropped, never an
    /// app-level activation: the window is on screen either way, and a loaded Finder can take
    /// seconds to reach the inventory. A newer request replaces an older one.
    func activateWhenAppears(timeout: TimeInterval, find: @escaping @MainActor (DockSnapshot) -> String?) {
        appearanceGeneration &+= 1
        pendingAppearanceFind = nil
        if let windowID = find(snapshot) {
            if Self.chipProbeEnabled { chipProbeLogger.info("appear-activate immediate windowID=\(windowID, privacy: .public)") }
            activate(windowID: windowID)
            return
        }
        let generation = appearanceGeneration
        pendingAppearanceFind = find
        pendingAppearanceStartedAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.appearanceGeneration == generation, self.pendingAppearanceFind != nil else { return }
                self.pendingAppearanceFind = nil
                if Self.chipProbeEnabled { self.chipProbeLogger.info("appear-activate dropped after \(Int(timeout * 1000), privacy: .public)ms") }
            }
        }
    }

    private var pendingAppearanceStartedAt = Date()

    private func resolvePendingAppearance() {
        guard let find = pendingAppearanceFind, let windowID = find(snapshot) else { return }
        pendingAppearanceFind = nil
        if Self.chipProbeEnabled { chipProbeLogger.info("appear-activate found windowID=\(windowID, privacy: .public) afterMs=\(Int(Date().timeIntervalSince(self.pendingAppearanceStartedAt) * 1000), privacy: .public)") }
        activate(windowID: windowID)
    }

    /// Cross-display drop dispatch: real window card -> move the window; `app-*` fallback card / kept
    /// placeholder (no window to move) -> change this app's session memory of "which display the windowless
    /// icon lives on" (`AppTracker.noteNoWindowHome`), and under ④ the card then switches bars.
    func handleCrossStripDrop(payload: DragPayload, toDisplayUUID uuid: String) {
        if let item = payload.item, !item.isAppLevelFallback {
            if Self.displayTraceEnabled {
                displayTraceLogger.info("drop window id=\(item.id, privacy: .public) pid=\(item.pid) cg=\(item.cgWindowID ?? 0) from=\(item.displayUUID ?? "nil", privacy: .public) to=\(uuid, privacy: .public)")
            }
            moveWindow(item: item, toDisplayUUID: uuid)
        } else {
            if Self.displayTraceEnabled {
                displayTraceLogger.info("drop no-window bundle=\(payload.bundleID, privacy: .public) id=\(payload.id, privacy: .public) to=\(uuid, privacy: .public)")
            }
            guard !payload.bundleID.isEmpty else { return }
            noWindowHomeByBundle[payload.bundleID] = uuid
            tracker.noteNoWindowHome(bundleID: payload.bundleID, displayUUID: uuid)
        }
    }

    /// Cross-display window drag (multi-display ③④, 2026-09-02): a window icon dropped on another display's
    /// taskbar moves the window to that display, **moved, not raised**. First optimistically change the
    /// ownership key in the inventory (the card jumps to the target bar at once), then write the AX frame on
    /// the action queue (`AXWindowReader.setFrame`, the only geometry write entry point in the project); if
    /// the write fails, change the key back (the card flies back to the source bar). For a tab group only the
    /// representative window moves; a fullscreen / unwritable window counts as "write failed".
    func moveWindow(item: StripItem, toDisplayUUID uuid: String) {
        guard !item.isAppLevelFallback else { return }
        // `item` was captured when the drag started; the seat's current tab may have changed during the drag
        // (tab switch / takeover), so look up the current cgWindowID by seat token (`StripItem.id`) in the
        // snapshot **as of now**, and use the drag-start one only if that fails. Otherwise `noteWindowMoved`
        // finds no seat and nothing moves, and the card bounces back to the source bar after landing.
        let liveRecord = snapshot.windows.values.first { $0.groupID == item.id && ($0.cgWindowID ?? 0) != 0 }
        guard let cgWindowID = liveRecord?.cgWindowID ?? item.cgWindowID, cgWindowID != 0 else { return }
        let table = displayTableProvider()
        guard let target = table.displays.first(where: { $0.uuid == uuid }) else { return }
        let source = table.displays.first { $0.uuid == item.displayUUID }
        let pid = pid_t(item.pid)
        let previous = liveRecord?.displayUUID ?? item.displayUUID
        let noted = tracker.noteWindowMoved(pid: pid, cgWindowID: cgWindowID, displayUUID: uuid)
        if Self.displayTraceEnabled {
            displayTraceLogger.info("moveWindow optimistic noted=\(noted) pid=\(pid) cg=\(cgWindowID) to=\(uuid, privacy: .public)")
        }
        guard noted else { return }
        let trace = Self.displayTraceEnabled ? displayTraceLogger : nil
        // fork: our own window (the Settings card) is moved with AppKit on the main thread, never
        // through AX from the action queue (`ForkOwnWindowPolicy`).
        if pid == ProcessInfo.processInfo.processIdentifier {
            if ForkOwnWindowActions.move(cgWindowID: cgWindowID, from: source, to: target) {
                tracker.noteWindowMoved(pid: pid, cgWindowID: cgWindowID, displayUUID: uuid, hold: .brief)
            } else {
                _ = tracker.resolveFailedWindowMove(pid: pid, cgWindowID: cgWindowID, target: uuid, previous: previous)
            }
            return
        }
        Self.actionQueue.async { [weak self] in
            let reader = AXWindowReader()
            // The window is not in AX at all (an offscreen / phantom window lingering in CG after its windows
            // were closed; the card looks like "dot but no window"): there is nothing to move, so the drag
            // means "change home". Pin the key to the target display until the window is next actually
            // visible in AX.
            guard let handle = reader.captureHandle(forPID: pid, cgWindowID: cgWindowID, messagingTimeout: 0.1),
                  let current = reader.frame(of: handle.element, messagingTimeout: 0.1) else {
                trace?.info("moveWindow no AX handle pid=\(pid) cg=\(cgWindowID) → pin untilVisible")
                Task { @MainActor [weak self] in
                    self?.tracker.noteWindowMoved(pid: pid, cgWindowID: cgWindowID, displayUUID: uuid, hold: .untilVisible)
                }
                return
            }
            let frame = WindowDisplayMove.targetFrame(window: current, from: source, to: target)
            // Success is judged by **the display the read-back frame belongs to**
            // (`WindowDisplayMove.landedOnTarget`), not by ±2pt: across displays AppKit often corrects by a
            // few pt itself, and a pixel-based failure would move an already moved window back. So
            // `restoreOnFailureTo` is not passed; the original frame is written back here when the window did
            // not reach the target display.
            let result = reader.setFrame(frame, for: handle.element,
                                         messagingTimeout: 0.1,
                                         verificationTolerance: 8)
            let landedFrame: CGRect? = {
                if case let .success(actual) = result { return actual }
                return reader.frame(of: handle.element, messagingTimeout: 0.1)
            }()
            if let landedFrame, WindowDisplayMove.landedOnTarget(actual: landedFrame, target: uuid, table: table) {
                trace?.info("moveWindow landed pid=\(pid) cg=\(cgWindowID) frame=\(String(describing: landedFrame), privacy: .public)")
                // The freeze restarts from the moment the write actually finishes: most of the 1.5s counted
                // from the optimistic write is spent on two AX round trips plus the frame write, and the rest
                // is not enough to block the stale position read that lands afterwards.
                Task { @MainActor [weak self] in
                    self?.tracker.noteWindowMoved(pid: pid, cgWindowID: cgWindowID, displayUUID: uuid, hold: .brief)
                }
                return
            }
            trace?.info("moveWindow setFrame failed pid=\(pid) cg=\(cgWindowID) result=\(String(describing: result), privacy: .public) landed=\(String(describing: landedFrame), privacy: .public)")
            _ = reader.setFrame(current, for: handle.element, messagingTimeout: 0.1, verificationTolerance: 8)
            // Write failed: window is on screen (a real window the user can see, fullscreen / unwritable) ->
            // roll back, the card flies back to the source bar; not on screen (offscreen / phantom) -> treat
            // as "change home" and pin to the target display. The inventory decides by the on-screen set.
            Task { @MainActor [weak self] in
                guard let self else { return }
                let verdict = self.tracker.resolveFailedWindowMove(pid: pid, cgWindowID: cgWindowID, target: uuid, previous: previous)
                trace?.info("moveWindow failed → \(String(describing: verdict), privacy: .public)")
            }
        }
    }

    // MARK: - Private

    private func trigger(_ intent: UserIntent) {
        // Start of the time window for feel diagnostics (off by default, `DOCK_HOVER_TRACE=1`). Without it
        // the log is full of main-thread stalls with nothing to attribute them to. The report was "actions
        // stall after a click / minimize", so "after" has to be delimited first.
        HoverTrace.action("\(intent.action)", phase: "begin")
        defer { HoverTrace.action("\(intent.action)", phase: "dispatched") }
        // If the same window has an action held by the settle gate, any new intent cancels it first (latest
        // intent wins).
        cancelHeldAction(for: intent)
        // Interruptible (2026-06-13): show/hide actions no longer lock pending. Execution itself is a
        // one-shot AX call of a few tens of ms, with no concurrency to cancel; consistency comes from the
        // optimistic overlay driving planning plus final reconciliation against the real snapshot. Only close
        // / quit (the window disappears) stay locked until confirmed.
        switch intent.action {
        case .close, .quit:
            guard intentPipeline.canBegin(intent: intent) else { return }
        default:
            break
        }
        let request = intentPipeline.plan(
            intent: intent,
            snapshot: snapshot,
            optimisticStates: optimisticStatesByWindowID
        )

                // ChipProbe: log the planner's actual decision inputs at tap time (main thread, no AX).
        // freshActive = read on the spot from a new instance (the value planning uses); the lagging
        // frontmostApplication is not logged, it would mislead diagnostics.
        if Self.chipProbeEnabled,
           case .toggle(let wid) = intent,
           let record = snapshot.windows[wid] {
            let runningApp = NSRunningApplication(processIdentifier: record.pid)
            let freshActive = runningApp?.isActive == true
            let optimisticStatus = optimisticStatesByWindowID[wid.rawValue]?.status.rawValue ?? "none"
            chipProbeLogger.info("toggle-planned windowID=\(wid.rawValue, privacy: .public) app=\(runningApp?.localizedName ?? "(unknown)", privacy: .public) bundleID=\(record.bundleIdentifier ?? "(none)", privacy: .public) recordStatus=\(record.status.rawValue, privacy: .public) optimisticStatus=\(optimisticStatus, privacy: .public) freshActive=\(freshActive, privacy: .public) plannedAction=\(request.kind.rawValue, privacy: .public)")
        }

        if ClickLatencyTrace.isEnabled, let wid = request.windowID?.rawValue {
            let record = snapshot.windows[WindowID(rawValue: wid)]
            ClickLatencyTrace.begin(
                windowID: wid,
                kind: request.kind.rawValue,
                status: record?.status.rawValue ?? "unknown",
                bundleID: record?.bundleIdentifier
            )
        }

        // The restore-origin decision uses the effective state at planning time (optimistic first), the same
        // basis as the planner's status axis.
        let effectiveStatusAtPlan: WindowStatus? = request.windowID.flatMap { wid in
            optimisticStatesByWindowID[wid.rawValue]?.status ?? snapshot.windows[wid]?.status
        }
        applyOptimisticState(for: request, wasMinimizedAtPlan: effectiveStatusAtPlan == .minimized)
        intentPipeline.registerPending(intent: intent, request: request)
        publishFeedbackEntries()
        updateFeedbackTimer()

        routeThroughSettleGate(intent: intent, request: request)
    }

    /// Execution queue for user actions. Concurrent (same parallelism as the old `Task.detached`: two quick
    /// clicks do not queue behind each other), `.userInitiated` (this is the path a person is waiting on,
    /// ahead of any background inventory scan). View-layer disk reads go here too (reading Info.plist when an
    /// app is dragged onto the bar), for the same hard rule: stay off the Swift cooperative pool.
    static let actionQueue = DispatchQueue(
        label: "no.thilip.nitiadock.window-action",
        qos: .userInitiated,
        attributes: .concurrent
    )

    // MARK: - Minimize Settle Gate

    /// "Minimize settle gate" for repeated clicks on the same window (v2, 2026-08-25): right after a minimize
    /// was dispatched for a window, its activate waits here until **the snapshot confirms `.minimized`** (=
    /// proof the write landed; with a human double-click it has usually arrived already, so no perceived
    /// delay) and is then released, the unminimize landing mid-genie and reversing the animation;
    /// unconfirmed, the 1.0s fallback releases it anyway. Safety does not rely on waiting: the release
    /// carries the `dispatchPrior` prior (2.0s anchor window), so the execution layer is forced onto the
    /// restore order measured safe in 07-05 v3, skips earlyFocus and seals off the app-level fallback,
    /// blocking all three promotion paths for "brought to front while offscreen". The decision lives in
    /// `MinimizeSettleGate` (pure function, unit tested). Gates activate only, not cross-chip actions.
    private struct HeldAction {
        let intent: UserIntent
        let request: PlatformActionRequest
        /// The minimize dispatch time this hold is anchored to. The anchor does not change while the hold
        /// lives: any new intent on the same window cancels the hold first (latest intent wins), so flush
        /// reruns the decision with it directly.
        let anchor: Date
        let generation: UInt64
        var workItem: DispatchWorkItem
    }

    private var recentMinimizeDispatchAtByWindowID: [String: Date] = [:]
    private var heldActionsByWindowID: [String: HeldAction] = [:]
    private var settleGateGeneration: UInt64 = 0

    private func routeThroughSettleGate(intent: UserIntent, request: PlatformActionRequest) {
        guard Self.settleGateEnabled, let windowID = request.windowID?.rawValue else {
            dispatchToExecutor(intent: intent, request: request)
            return
        }
        if request.kind == .minimizeWindow {
            // app-* cards never produce minimizeWindow (the planner only gives them hideApp /
            // activateWindow); the prefix check is purely defensive. The anchor is pruned by time only
            // (priorWindow) and is **never cleared because the minimize result was failure**: a success
            // during the animation is routinely read back at once and recorded as a failure (stated in the
            // FeedbackTickPolicy rules), and clearing the anchor on failure would drop the guard right in the
            // middle of the animation.
            if !windowID.hasPrefix("app-") {
                recentMinimizeDispatchAtByWindowID[windowID] = Date()
            }
            dispatchToExecutor(intent: intent, request: request)
            return
        }
        let verdict = MinimizeSettleGate.verdict(
            requestKind: request.kind,
            minimizeDispatchedAt: recentMinimizeDispatchAtByWindowID[windowID],
            snapshotConfirmsMinimized: snapshot.windows[WindowID(rawValue: windowID)]?.status == .minimized,
            now: Date()
        )
        switch verdict {
        case .dispatchNow:
            dispatchToExecutor(intent: intent, request: request)
        case .hold(let until):
            ClickLatencyTrace.mark(windowID: windowID, "settleGate", detail: "hold")
            holdAction(intent: intent, request: request, windowID: windowID, until: until)
        }
    }

    private func holdAction(intent: UserIntent, request: PlatformActionRequest, windowID: String, until: Date) {
        guard let anchor = recentMinimizeDispatchAtByWindowID[windowID] else {
            // verdict only returns hold when an anchor exists; reaching here means the state was changed
            // concurrently, so dispatch directly to be safe.
            dispatchToExecutor(intent: intent, request: request)
            return
        }
        settleGateGeneration &+= 1
        let generation = settleGateGeneration
        let workItem = makeFlushWorkItem(windowID: windowID, generation: generation)
        heldActionsByWindowID[windowID] = HeldAction(
            intent: intent, request: request, anchor: anchor, generation: generation, workItem: workItem
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, until.timeIntervalSinceNow), execute: workItem)
    }

    private func makeFlushWorkItem(windowID: String, generation: UInt64) -> DispatchWorkItem {
        DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.flushHeldAction(windowID: windowID, generation: generation)
            }
        }
    }

    private func flushHeldAction(windowID: String, generation: UInt64) {
        guard isRunning,
              let held = heldActionsByWindowID[windowID],
              held.generation == generation else { return }
        let verdict = MinimizeSettleGate.verdict(
            requestKind: held.request.kind,
            minimizeDispatchedAt: held.anchor,
            snapshotConfirmsMinimized: snapshot.windows[WindowID(rawValue: windowID)]?.status == .minimized,
            now: Date()
        )
        switch verdict {
        case .dispatchNow:
            heldActionsByWindowID.removeValue(forKey: windowID)
            let confirmed = snapshot.windows[WindowID(rawValue: windowID)]?.status == .minimized
            ClickLatencyTrace.mark(windowID: windowID, "settleGateFlush", detail: confirmed ? "confirmed" : "cap")
            dispatchToExecutor(intent: held.intent, request: held.request)
        case .hold(let until):
            // Settle period is over but the snapshot has not confirmed yet -> the decision pushes deadline to
            // the hard cap, so rescheduling once is enough (deadline is monotonic and never moves back,
            // locked by MinimizeSettleGateTests).
            held.workItem.cancel()
            let workItem = makeFlushWorkItem(windowID: windowID, generation: generation)
            heldActionsByWindowID[windowID]?.workItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, until.timeIntervalSinceNow), execute: workItem)
        }
    }

    /// Re-evaluated on snapshot updates / feedback ticks: a held action whose snapshot is confirmed and whose
    /// settle period is over is released at once, without waiting for the workItem to fire; expired minimize
    /// anchors are pruned along the way.
    private func reevaluateHeldActions(now: Date = Date()) {
        if !recentMinimizeDispatchAtByWindowID.isEmpty {
            // The anchor's lifetime = the prior window (2.0s, the anchor's second job), not the hold cap. v1
            // pruned by maxHold, so the anchor expired first during Finder's 887ms animation, one of the
            // holes behind "rapid repeated clicks still leak a sibling".
            recentMinimizeDispatchAtByWindowID = recentMinimizeDispatchAtByWindowID.filter {
                now.timeIntervalSince($0.value) < MinimizeSettleGate.priorWindow
            }
        }
        guard !heldActionsByWindowID.isEmpty else { return }
        for (windowID, held) in heldActionsByWindowID {
            let verdict = MinimizeSettleGate.verdict(
                requestKind: held.request.kind,
                minimizeDispatchedAt: held.anchor,
                snapshotConfirmsMinimized: snapshot.windows[WindowID(rawValue: windowID)]?.status == .minimized,
                now: now
            )
            guard case .dispatchNow = verdict else { continue }
            held.workItem.cancel()
            heldActionsByWindowID.removeValue(forKey: windowID)
            let confirmed = snapshot.windows[WindowID(rawValue: windowID)]?.status == .minimized
            ClickLatencyTrace.mark(windowID: windowID, "settleGateFlush", detail: confirmed ? "confirmed" : "cap")
            dispatchToExecutor(intent: held.intent, request: held.request)
        }
    }

    /// Cancels the held action when a new intent arrives for the same window (latest intent wins). close /
    /// quit must honestly mark the never-executed held action as failure, otherwise the pending entry it
    /// leaves would block canBegin. For other intents, registerPending overwrites the feedback entry for the
    /// same windowID directly, so nothing more is needed.
    private func cancelHeldAction(for intent: UserIntent) {
        guard let held = heldActionsByWindowID.removeValue(forKey: intent.windowID.rawValue) else { return }
        held.workItem.cancel()
        switch intent.action {
        case .close, .quit:
            intentPipeline.registerExecutionResult(intent: held.intent, request: held.request, success: false)
        default:
            break
        }
    }

    /// Hands the action to the execution queue. **The snapshot is taken at call time**: on immediate dispatch
    /// it is from the same turn as the trigger (fresh to the µs); an action held by the settle gate gets the
    /// new, flipped snapshot here on flush, so the execution layer can take the `knownMinimized` positive
    /// fast path instead of entering the app-level fallback with a stale snapshot.
    private func dispatchToExecutor(intent: UserIntent, request: PlatformActionRequest) {
        let executor = actionExecutor
        let capturedSnapshot = snapshot
        // Settle gate prior (v2): the main thread reads the anchor table, computes it and sends it along with
        // the closure. A single choke point, so all four dispatch sites stay consistent. activate with an
        // anchor inside the prior window (2.0s) -> the execution layer is forced onto the restore branch,
        // skips earlyFocus and seals off the app fallback. With the switch off the anchor table is always
        // empty, so the prior is always false.
        let forcedMinimizedPrior = request.kind == .activateWindow
            && MinimizeSettleGate.dispatchPrior(
                minimizeDispatchedAt: request.windowID.flatMap { recentMinimizeDispatchAtByWindowID[$0.rawValue] },
                now: Date()
            )
        // **No `Task.detached`** (2026-08-11): it would put user clicks on the Swift cooperative thread pool,
        // and `AppTracker`'s two background AX reads use the same pool: the event read fires once per pid,
        // and the 5-second sweep is even a **serial for loop** (holding one pool thread for up to N × 100ms).
        // AX calls are blocking and should never occupy a cooperative thread; a click queued behind inventory
        // reads just waits for nothing. Uses its own `.userInitiated` concurrent queue instead.
        // Successor prediction for the collapse handoff (2026-08-26): the execution layer reports the handoff
        // target the moment it is computed (before the minimize lands), and the main thread writes an
        // optimistic .active with transition grace for the successor window. Only then is a click on its card
        // before the snapshot confirms planned correctly as a collapse ("after collapsing window 1, a quick
        // click on window 2 won't collapse it"). Never overwrites an existing optimistic entry (user actions
        // take priority over system predictions). A wrong prediction self-heals through takeover clearing
        // (the real successor, once confirmed by the snapshot, replaces this prediction).
        let onHandoffActivePrediction: ((WindowID) -> Void)? =
            ((request.kind == .minimizeWindow || request.kind == .closeWindow) && Self.handoffActivePredictionEnabled)
            ? { [weak self] windowID in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.optimisticStatesByWindowID[windowID.rawValue] == nil else { return }
                    // Recheck against the current snapshot when writing: the handoff decision used the
                    // dispatch-time snapshot, which may be stale in a storm. If the snapshot says the
                    // successor is minimized/hidden, don't write (it would be disproved and cleared anyway).
                    guard let current = self.snapshot.windows[windowID],
                          current.status != .minimized, current.status != .hidden else { return }
                    self.optimisticStatesByWindowID[windowID.rawValue] = OptimisticWindowState(
                        status: .active, createdAt: Date(), focusHandoffGrace: true, systemPredicted: true
                    )
                }
            }
            : nil
        // The callback is called only once, in the execution closure below; it captures only weak self and
        // starts a Task back to the main actor, so passing it across queues is safe. Marked
        // nonisolated(unsafe) rather than adding @Sendable to the closure type: the latter makes the `Task {
        // @MainActor in }` inside the closure an ambiguous overload on Xcode 26.
        nonisolated(unsafe) let handoffPrediction = onHandoffActivePrediction
        Self.actionQueue.async { [weak self] in
            // The first milestone measures "dispatch to actually starting to run": when the thread pool is
            // saturated by background AX reads, user clicks stall right here, and that delay is invisible
            // from the end state.
            ClickLatencyTrace.mark(windowID: request.windowID?.rawValue, "execStart")
            let success = executor.execute(
                request,
                snapshot: capturedSnapshot,
                forcedMinimizedPrior: forcedMinimizedPrior,
                onHandoffActivePrediction: handoffPrediction
            )
            ClickLatencyTrace.end(windowID: request.windowID?.rawValue, success: success)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.intentPipeline.registerExecutionResult(intent: intent, request: request, success: success)
                self.publishFeedbackEntries()
                // This callback may return to the main thread after stop(); the isRunning gate in
                // updateFeedbackTimer keeps it from reviving a timer that has already been stopped.
                self.updateFeedbackTimer()
            }
        }
    }

    /// Registers and starts a user launch. Returns false if a session for the same bundle already exists or
    /// the app URL cannot be resolved.
    @discardableResult
    func beginLaunch(_ bundleID: String) -> Bool {
        guard !bundleID.isEmpty,
              let launchTarget = Self.resolveLaunchTarget(bundleID: bundleID) else {
            launchLogger.warning("launch rejected: app URL missing bundleID=\(bundleID, privacy: .public)")
            traceLaunch("REJECT bid=\(bundleID) reason=no-app-url")
            return false
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let baseline = realWindowIdentities(in: snapshot, bundleID: bundleID)
        let declaresNoWindow = launchTarget.declaresNoWindow
        guard let token = launchSessions.begin(bundleID: bundleID, makeValue: { token in
            LaunchSession(
                bundleID: bundleID,
                token: token,
                startedAt: startedAt,
                baselineRealWindows: baseline,
                bundleDeclaresNoWindow: declaresNoWindow
            )
        }) else {
            traceLaunch("REJECT bid=\(bundleID) reason=session-active")
            return false
        }

        let appURL = launchTarget.url
        let targetPath = AppLaunchTargetDecision.canonicalPath(appURL)
        let configuration = AppLaunchOpenConfiguration.make()
        let createsNewApplicationInstance = configuration.createsNewApplicationInstance
        let allowsRunningApplicationSubstitution = configuration.allowsRunningApplicationSubstitution
        publishLaunching()
        traceLaunch(
            "START bid=\(bundleID) token=\(token) t=\(Self.timeText(startedAt)) baseline=\(baseline.count) "
                + "target=\(Self.traceValue(targetPath)) "
                + "createsNewApplicationInstance=\(createsNewApplicationInstance ? 1 : 0) "
                + "allowsRunningApplicationSubstitution=\(allowsRunningApplicationSubstitution ? 1 : 0)"
        )

        let recheckTask = Task { @MainActor [weak self] in
            for deadline in Self.launchPolicyRecheckDeadlines {
                let wait = max(
                    0,
                    startedAt + deadline - ProcessInfo.processInfo.systemUptime
                )
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }
                self?.evaluateLaunch(bundleID: bundleID, token: token)
            }
        }
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.evaluateLaunch(bundleID: bundleID, token: token)
        }
        let tasksAttached = launchSessions.update(bundleID: bundleID, token: token) { session in
            session.policyRecheckTask = recheckTask
            session.timeoutTask = timeoutTask
        }
        guard tasksAttached else {
            recheckTask.cancel()
            timeoutTask.cancel()
            return false
        }

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { [weak self] app, error in
            Task { @MainActor [weak self] in
                self?.handleLaunchCompletion(
                    bundleID: bundleID,
                    token: token,
                    targetPath: targetPath,
                    createsNewApplicationInstance: createsNewApplicationInstance,
                    allowsRunningApplicationSubstitution: allowsRunningApplicationSubstitution,
                    app: app,
                    error: error
                )
            }
        }
        return true
    }

    private func handleLaunchCompletion(
        bundleID: String,
        token: UInt64,
        targetPath: String,
        createsNewApplicationInstance: Bool,
        allowsRunningApplicationSubstitution: Bool,
        app: NSRunningApplication?,
        error: Error?
    ) {
        let identity = app.flatMap { Self.processIdentity(pid: $0.processIdentifier) }
        guard launchSessions.update(bundleID: bundleID, token: token, { session in
            session.app = app
            session.processIdentity = identity
            session.openFailed = error != nil
        }) else {
            traceLaunch(
                Self.launchCompletionTrace(
                    prefix: "SUPERSEDED",
                    bundleID: bundleID,
                    token: token,
                    targetPath: targetPath,
                    createsNewApplicationInstance: createsNewApplicationInstance,
                    allowsRunningApplicationSubstitution: allowsRunningApplicationSubstitution,
                    app: app,
                    error: error
                )
            )
            return
        }

        let policy = app.map { Self.activationPolicyText($0.activationPolicy) } ?? "unknown"
        if let error {
            launchLogger.error(
                "openApplication failed bundleID=\(bundleID, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
        traceLaunch(
            Self.launchCompletionTrace(
                prefix: "OPENED",
                bundleID: bundleID,
                token: token,
                targetPath: targetPath,
                createsNewApplicationInstance: createsNewApplicationInstance,
                allowsRunningApplicationSubstitution: allowsRunningApplicationSubstitution,
                app: app,
                error: error,
                policy: policy
            )
        )
        evaluateLaunch(bundleID: bundleID, token: token)
    }

    private func reconcileLaunchingStates(with newSnapshot: DockSnapshot) {
        guard !launchSessions.bundleIDs.isEmpty else { return }
        for entry in launchSessions.currentEntries {
            evaluateLaunch(bundleID: entry.bundleID, token: entry.token, snapshot: newSnapshot)
        }
    }

    private func evaluateLaunch(
        bundleID: String,
        token: UInt64,
        snapshot suppliedSnapshot: DockSnapshot? = nil
    ) {
        guard let entry = launchSessions.entry(for: bundleID), entry.token == token else {
            traceLaunch("SUPERSEDED bid=\(bundleID) token=\(token)")
            return
        }
        let session = entry.value
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - session.startedAt)
        let currentWindows = realWindowIdentities(
            in: suppliedSnapshot ?? snapshot,
            bundleID: bundleID
        )
        let hasNewRealWindow = LaunchWindowBaselineDecision.hasNewWindow(
            baseline: session.baselineRealWindows,
            current: currentWindows
        )

        let targetPID = session.app?.processIdentifier
        let processObservation: LaunchGateDecision.ProcessObservation? = session.app.map { app in
            let currentIdentity = Self.processIdentity(pid: app.processIdentifier)
            return LaunchGateDecision.ProcessObservation(
                isAlive: ProcessLiveness.isAlive(pid: app.processIdentifier),
                generationMatches: session.processIdentity != nil && currentIdentity == session.processIdentity,
                activationPolicy: Self.launchActivationPolicy(app.activationPolicy),
                isFinishedLaunching: app.isFinishedLaunching,
                bundleDeclaresNoWindow: session.bundleDeclaresNoWindow
            )
        }
        let hasOtherRegularProcess = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .contains { app in
                app.processIdentifier != targetPID
                    && app.activationPolicy == .regular
                    && ProcessLiveness.isAlive(pid: app.processIdentifier)
            }
        let observation = LaunchGateDecision.Observation(
            openFailed: session.openFailed,
            hasNewRealWindow: hasNewRealWindow,
            launchedProcess: processObservation,
            hasOtherRegularProcess: hasOtherRegularProcess,
            elapsed: elapsed
        )
        let verdict = LaunchGateDecision.evaluate(observation)
        traceLaunchEvaluation(
            bundleID: bundleID,
            token: token,
            observation: observation,
            verdict: verdict
        )

        if case .release(let reason) = verdict {
            releaseLaunch(bundleID: bundleID, token: token, reason: reason, elapsed: elapsed)
        }
    }

    private func releaseLaunch(
        bundleID: String,
        token: UInt64,
        reason: LaunchGateDecision.ReleaseReason,
        elapsed: TimeInterval
    ) {
        guard let session = launchSessions.remove(bundleID: bundleID, token: token) else {
            traceLaunch("SUPERSEDED bid=\(bundleID) token=\(token)")
            return
        }
        session.policyRecheckTask?.cancel()
        session.timeoutTask?.cancel()
        publishLaunching()
        traceLaunch(
            "RELEASE bid=\(bundleID) token=\(token) el=\(Self.timeText(elapsed)) "
                + "reason=\(String(describing: reason))"
        )
    }

    private func stopLaunchSessions() {
        let sessions = launchSessions.removeAll()
        for session in sessions {
            session.policyRecheckTask?.cancel()
            session.timeoutTask?.cancel()
        }
        publishLaunching()
    }

    private func publishLaunching() {
        let next = launchSessions.bundleIDs
        if next != launchingBundleIDs {
            launchingBundleIDs = next
        }
    }

    private func realWindowIdentities(
        in snapshot: DockSnapshot,
        bundleID: String
    ) -> Set<LaunchWindowIdentity> {
        Set(StripItem.items(from: snapshot).compactMap { item in
            guard item.bundleIdentifier == bundleID,
                  !item.isAppLevelFallback,
                  ProcessLiveness.isAlive(pid: item.pid),
                  let startTime = ProcessLiveness.startTime(pid: item.pid) else {
                return nil
            }
            return LaunchWindowIdentity(
                chipID: item.id,
                pid: item.pid,
                startTimeSec: Int64(startTime.tv_sec),
                startTimeUsec: Int64(startTime.tv_usec)
            )
        })
    }

    private static func processIdentity(pid: pid_t) -> LaunchProcessIdentity? {
        guard ProcessLiveness.isAlive(pid: pid),
              let startTime = ProcessLiveness.startTime(pid: pid) else {
            return nil
        }
        return LaunchProcessIdentity(
            pid: pid,
            startTimeSec: Int64(startTime.tv_sec),
            startTimeUsec: Int64(startTime.tv_usec)
        )
    }

    private static func launchActivationPolicy(
        _ policy: NSApplication.ActivationPolicy
    ) -> LaunchGateDecision.ActivationPolicy {
        switch policy {
        case .regular: return .regular
        case .accessory: return .accessory
        case .prohibited: return .prohibited
        @unknown default: return .unknown
        }
    }

    private static func activationPolicyText(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular: return "regular"
        case .accessory: return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "unknown"
        }
    }

    private static func bundleDeclaresNoWindow(at appURL: URL) -> Bool {
        guard let info = Bundle(url: appURL)?.infoDictionary else { return false }
        func boolValue(_ key: String) -> Bool {
            if let value = info[key] as? Bool { return value }
            if let value = info[key] as? NSNumber { return value.boolValue }
            if let value = info[key] as? String {
                return ["1", "true", "yes"].contains(value.lowercased())
            }
            return false
        }
        return boolValue("LSUIElement") || boolValue("LSBackgroundOnly")
    }

    private static func resolveLaunchTarget(bundleID: String) -> AppLaunchTargetDecision.Candidate? {
        let workspace = NSWorkspace.shared
        let preferred = workspace.urlForApplication(withBundleIdentifier: bundleID).map {
            AppLaunchTargetDecision.Candidate(
                url: $0,
                declaresNoWindow: bundleDeclaresNoWindow(at: $0)
            )
        }
        let candidates = workspace.urlsForApplications(withBundleIdentifier: bundleID).map {
            AppLaunchTargetDecision.Candidate(
                url: $0,
                declaresNoWindow: bundleDeclaresNoWindow(at: $0)
            )
        }
        return AppLaunchTargetDecision.select(
            launchServicesCandidates: candidates,
            preferred: preferred
        )
    }

    private static func launchCompletionTrace(
        prefix: String,
        bundleID: String,
        token: UInt64,
        targetPath: String,
        createsNewApplicationInstance: Bool,
        allowsRunningApplicationSubstitution: Bool,
        app: NSRunningApplication?,
        error: Error?,
        policy suppliedPolicy: String? = nil
    ) -> String {
        let policy = suppliedPolicy ?? app.map { activationPolicyText($0.activationPolicy) } ?? "unknown"
        let returnedPath = app?.bundleURL.map { canonicalPath in
            AppLaunchTargetDecision.canonicalPath(canonicalPath)
        }
        return "\(prefix) bid=\(bundleID) token=\(token) target=\(traceValue(targetPath)) "
            + "createsNewApplicationInstance=\(createsNewApplicationInstance ? 1 : 0) "
            + "allowsRunningApplicationSubstitution=\(allowsRunningApplicationSubstitution ? 1 : 0) "
            + "pid=\(app.map { String($0.processIdentifier) } ?? "nil") policy=\(policy) "
            + "returned=\(returnedPath.map(traceValue) ?? "nil") "
            + "error=\(error.map { traceValue($0.localizedDescription) } ?? "nil")"
    }

    private static func traceValue(_ value: String) -> String {
        String(reflecting: value)
    }

    private func traceLaunchEvaluation(
        bundleID: String,
        token: UInt64,
        observation: LaunchGateDecision.Observation,
        verdict: LaunchGateDecision.Verdict
    ) {
        guard Self.launchTraceEnabled else { return }
        let process = observation.launchedProcess
        let classification = [
            "fail=\(observation.openFailed ? 1 : 0)",
            "win=\(observation.hasNewRealWindow ? 1 : 0)",
            "alive=\(process.map { $0.isAlive ? 1 : 0 } ?? -1)",
            "gen=\(process.map { $0.generationMatches ? 1 : 0 } ?? -1)",
            "policy=\(process.map { String(describing: $0.activationPolicy) } ?? "unknown")",
            "fin=\(process.map { $0.isFinishedLaunching ? 1 : 0 } ?? -1)",
            "decl=\(process.map { $0.bundleDeclaresNoWindow ? 1 : 0 } ?? -1)",
            "other=\(observation.hasOtherRegularProcess ? 1 : 0)",
            "verdict=\(String(describing: verdict))"
        ].joined(separator: " ")
        guard launchSessions.entry(for: bundleID)?.value.lastTraceClassification != classification else {
            return
        }
        _ = launchSessions.update(bundleID: bundleID, token: token) { session in
            session.lastTraceClassification = classification
        }
        traceLaunch(
            "EVAL bid=\(bundleID) token=\(token) el=\(Self.timeText(observation.elapsed)) \(classification)"
        )
    }

    private func traceLaunch(_ message: String) {
        guard Self.launchTraceEnabled else { return }
        print("[launch] \(message)")
    }

    private static func timeText(_ value: TimeInterval) -> String {
        String(format: "%.3f", value)
    }

    private func handleSnapshotUpdate(_ newSnapshot: DockSnapshot) {
        if snapshot != newSnapshot { snapshot = newSnapshot }
        // The explicit home only covers the windowless period: it is cleared as soon as the app gets a real
        // window, after which the inventory's "display the window was last on" takes over.
        if !noWindowHomeByBundle.isEmpty {
            for record in newSnapshot.windows.values where record.cgWindowID != nil {
                if let bid = record.bundleIdentifier, noWindowHomeByBundle[bid] != nil {
                    noWindowHomeByBundle.removeValue(forKey: bid)
                }
            }
        }
        reconcileLaunchingStates(with: newSnapshot)
        let trusted = isAccessibilityTrusted()
        if hasRequiredPermissions != trusted { hasRequiredPermissions = trusted }
        intentPipeline.reconcile(with: newSnapshot)
        publishFeedbackEntries()
        reconcileOptimisticStates()
        reevaluateHeldActions()
        updateFeedbackTimer()
        resolvePendingAppearance()
        if let startedAt {
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            debugState.setObservationStatusText(hasRequiredPermissions ? "Live \(ms)ms" : "Window list only")
            self.startedAt = nil
        }
    }

    private func tickFeedback() {
        intentPipeline.reconcile(with: snapshot)
        publishFeedbackEntries()
        reconcileOptimisticStates()
        reevaluateHeldActions()
        updateFeedbackTimer()
    }

    /// Projects the pipeline's feedback state into the separate debug state. **Compare before writing.**
    ///
    /// `@Published` does no equality check; `willSet` always notifies. Debug consumers now observe only
    /// `DebugRuntimeState`, so feedback changes no longer invalidate the taskbar and drawer.
    /// `reconcileOptimisticStates` in this file and `BadgeStore.readOnce` have long been compare-then-write;
    /// only this one was missed.
    private func publishFeedbackEntries() {
        let next = intentPipeline.feedbackState.entriesByWindowID
        debugState.setFeedbackEntries(next)
    }

    /// The feedback timer runs on demand: periodic reconciliation is needed only while the feedback state or
    /// the optimistic state is non-empty (pending times out to failure, result display expires and clears,
    /// optimistic state times out and silently reverts). Both empty = nothing changes over time, so not a
    /// single idle tick should happen.
    ///
    /// Timing semantics are unchanged: still a 0.5s period + 0.05s tolerance, and the 4s pending / 1.5s
    /// result display retention is untouched. The only change is "don't tick when there is nothing to do".
    private func updateFeedbackTimer() {
        let shouldTick = FeedbackTickPolicy.shouldTick(
            isRunning: isRunning,
            hasFeedbackEntries: !intentPipeline.feedbackState.entriesByWindowID.isEmpty,
            hasOptimisticStates: !optimisticStatesByWindowID.isEmpty
        )
        guard shouldTick else {
            feedbackTimer?.invalidate()
            feedbackTimer = nil
            return
        }
        guard feedbackTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickFeedback() }
        }
        timer.tolerance = 0.05
        feedbackTimer = timer
    }

    // MARK: - Optimistic Overlay

    /// Timeout cap aligned with the pending retention (IntentFeedbackState.FeedbackPhase.pending).
    private static let optimisticTimeout: TimeInterval = 4.0

    /// Writes predicted state for the planned action. hideApp only covers the clicked chip; the app's other
    /// windows wait for the snapshot (accepted in v1). close / quit / newWindow write nothing (the window
    /// disappears / it is a different window).
    private func applyOptimisticState(for request: PlatformActionRequest, wasMinimizedAtPlan: Bool) {
        let state: OptimisticWindowState?
        switch request.kind {
        case .activateWindow:
            state = OptimisticWindowState(status: .active, createdAt: Date(), focusHandoffGrace: wasMinimizedAtPlan)
        case .minimizeWindow:
            state = OptimisticWindowState(status: .minimized, createdAt: Date())
        case .hideApp:
            state = OptimisticWindowState(status: .hidden, createdAt: Date())
        case .closeWindow, .quitApp, .newWindow:
            state = nil
        }
        guard let state, let windowID = request.windowID else { return }
        optimisticStatesByWindowID[windowID.rawValue] = state
    }

    /// Confirm / roll back: the real snapshot reaches the predicted state (or the window disappears) ->
    /// clear; timed out unconfirmed -> silently revert to the real state (no extra hint; AX action failures
    /// are rare in themselves).
    private func reconcileOptimisticStates(now: Date = Date()) {
        guard !optimisticStatesByWindowID.isEmpty else { return }
        let next = optimisticStatesByWindowID.filter { windowID, state in
            let cleared: String?
            if now.timeIntervalSince(state.createdAt) > Self.optimisticTimeout {
                cleared = "timeout"
            } else if snapshot.windows[WindowID(rawValue: windowID)] == nil {
                cleared = "window-gone"
            } else if let record = snapshot.windows[WindowID(rawValue: windowID)],
                      Self.optimisticConfirmed(predicted: state.status, actual: record.status) {
                cleared = "confirmed"
            } else if let record = snapshot.windows[WindowID(rawValue: windowID)],
                      OptimisticWindowState.systemPredictionFalsified(state: state, actual: record.status) {
                cleared = "prediction-falsified"
            } else if OptimisticWindowState.supersededByActiveSibling(
                windowID: windowID, state: state, now: now,
                optimisticStates: optimisticStatesByWindowID,
                snapshot: snapshot, handoffGraceEnabled: Self.handoffActiveGraceEnabled
            ) {
                cleared = "superseded-by-active-sibling"
            } else {
                cleared = nil
            }
            if Self.chipProbeEnabled, let cleared {
                chipProbeLogger.info("optimistic-cleared windowID=\(windowID, privacy: .public) predicted=\(state.status.rawValue, privacy: .public) ageMs=\(Int(now.timeIntervalSince(state.createdAt) * 1000), privacy: .public) reason=\(cleared, privacy: .public)")
            }
            return cleared == nil
        }
        if next != optimisticStatesByWindowID {
            optimisticStatesByWindowID = next
        }
    }

    /// Same basis as feedback reconcile: minimize / hide may briefly show up as disappeared (lesson from the
    /// Finder minimize feedback bug), which also counts as confirmed.
    private static func optimisticConfirmed(predicted: WindowStatus, actual: WindowStatus) -> Bool {
        if predicted == actual { return true }
        if (predicted == .minimized || predicted == .hidden) && actual == .disappeared { return true }
        return false
    }
}
