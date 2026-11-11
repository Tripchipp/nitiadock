import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

struct AppEntry {
    let pid: pid_t
    let bundleIdentifier: String?
    let appName: String
    let activationPolicy: NSApplication.ActivationPolicy
    let executablePath: String?
    var windowsByID: [CGWindowID: WindowEntry]
    var windowOrder: [CGWindowID]
    var isHidden: Bool
    /// Shadow tab pool: window ids that at the previous reconcile were "in the full CG list (this pid, layer
    /// 0) but not in AXWindows", the signature unique to ordered-out background tabs (a real window is always
    /// in AXWindows, whether visible / minimized / hidden / on another Space). The second level of the Pass B
    /// fold decision uses it to cover the "member history wiped by a dock restart" gap; it is rebuilt from
    /// live signals every round, with no persistence. The decision uses the previous round's pool (in a
    /// minimize burst all tabs flood into AX, so a pool computed this round would be empty).
    var shadowTabCgIDs: Set<CGWindowID> = []
    /// The display (display UUID) this app's windows were last on. After all windows close, the "running but
    /// no windows" fallback card lands here (multi-display ④: an icon with a dot is on one bar only,
    /// 2026-09-02); dragging that card onto another display's bar also writes here (`noteNoWindowHome`).
    /// Session memory, not persisted; nil -> the projection layer uses the main display.
    var lastWindowDisplayUUID: String? = nil
}

/// One **physical window seat** (single-seat model). `cgWindowID` is its **current** visible tab (= the
/// action target) and changes with tab switches; `token` is the seat's stable identity and **never changes**
/// once assigned (even when activeCgID is replaced). This is why the card neither jumps nor splits on tab
/// switch / minimize. Background tabs do NOT get their own seat.
struct WindowEntry {
    var cgWindowID: CGWindowID   // cgID of the currently visible tab (action target), replaced on tab switch
    let token: String            // stable physical seat identity (tabgrp-<pid>-<seed cgID>), never changes
    var title: String
    var bounds: CGRect?
    var isMinimized: Bool
    var isFocused: Bool
    /// When the continuous AX absence began in the min / hidden retention branch. Feeds only the phantom seat
    /// self-heal decision (PhantomSeatDecision, five thresholds); reappearing in AX resets it naturally
    /// through make().
    var minAbsentSince: Date? = nil
    /// Diagnostics only: set / cleared together with `minAbsentSince`, identifies one continuous AX absence
    /// episode. Not part of the seat signature, folding or self-heal decisions.
    var absenceEpisodeID: UUID? = nil
    /// Whether this seat has ever appeared in AX with min=false (inherited when the seat continues). A real
    /// window has almost certainly been visible; a phantom seat (split off a min=true burst candidate when
    /// folding failed) is always false. This is the first threshold of the self-heal decision and also
    /// protects Safari-style real windows that "leave AX entirely once minimized" from being wrongly removed
    /// by self-heal.
    var everSeenVisible: Bool = false
    /// Tabs that were once this seat's activeCgID (recorded when replaced on tab switch; also learned when a
    /// fold succeeds with a unique owner). A tab becomes the active tab on creation ⇒ every background tab is
    /// in its seat's history. Pass B folding decides by this membership first, regardless of geometry and the
    /// min flag, which exempts two kinds of fold failure: "background tab AX geometry stale after window move
    /// / resize" and the "min lag race" (root fix for the split bug). Against wrong folds from cgID reuse:
    /// cleared globally on real destruction (tombstone) and intersected with the full CG list each reconcile;
    /// a tab evicted by tear-out is NOT recorded (it is an independent window now).
    var formerCgIDs: Set<CGWindowID> = []
    /// Which display the window is on (display UUID, coarse attribution key, `WindowDisplayAttribution`).
    /// **Updated only while the seat is visible** (AX reads min=false and the app is not hidden; the 5s
    /// tick's CG bounds pass; recomputed from stored frames on screen parameter changes), frozen on the last
    /// visible display while minimized / ⌘H (multi-display ④, "a minimized card stays on its display"). Part
    /// of `seatSignature`; **the coordinates themselves never enter the fingerprint**, or every moved pixel
    /// would rebuild the whole bar.
    var displayUUID: String? = nil
    /// **Freezes** the attribution key after the optimistic update of a cross-display drag: the AX frame
    /// write is still in flight on the action queue, and reads landing meanwhile (frontmost poll / the tick's
    /// CG pass) still see the old position; without the freeze the card would bounce to the source display
    /// and jump back. `.distantFuture` = pinned until it is next visible in AX (off-screen / phantom windows
    /// that AX has no handle for and cannot move: dragging to another bar counts as a "change of address",
    /// and the old coordinates in CG do not count).
    var displayUUIDHoldUntil: Date? = nil
}

protocol AppTrackerProcessProviding: Sendable {
    func isAlive(pid: pid_t) -> Bool
    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity
}

struct LiveAppTrackerProcessProvider: AppTrackerProcessProviding {
    func isAlive(pid: pid_t) -> Bool {
        ProcessLiveness.isAlive(pid: pid)
    }

    func identity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        let start = ProcessLiveness.startTime(pid: pid)
        return ScanAdmissionDecision.ProcessIdentity(
            pid: pid,
            startTimeSec: start.map { Int64($0.tv_sec) },
            startTimeUsec: start.map { $0.tv_usec },
            bundleID: bundleID
        )
    }
}

@MainActor
final class AppTracker: ObservableObject {
    @Published private(set) var snapshot: DockSnapshot = .empty

    private var apps: [pid_t: AppEntry] = [:]
    private var appOrder: [pid_t] = []
    private var observers: [pid_t: AppWindowObserver] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var reconcileTimer: Timer?
    private var frontmostPollTimer: Timer?
    private var isScanningCandidates = false
    /// Side cache of AX elements for the action path. Written here (the inventory read already holds the
    /// elements), read in `PlatformActionExecutor`. Deliberately kept out of `DockSnapshot`, see
    /// `AXElementCache` for why.
    private let elementCache = AXElementCache.shared
    private var destroyedCGIDs: [CGWindowID: Date] = [:]
    private static let tombstoneTTL: TimeInterval = 3.0
    /// Phantom seat self-heal threshold: how long a min-retained seat must be continuously absent from AX
    /// before it may enter the PhantomSeatDecision (it must also pass four gates: everSeenVisible / present
    /// in CG / healthy AX read / a sibling seat present in AX).
    private static let phantomReapGrace: TimeInterval = 10.0

    /// The CG on-screen set at the last snapshot rebuild. The frontmost poll uses it to detect a "tab
    /// switch": AX may report nothing at all, but the on-screen set changes at once, and a change triggers a
    /// rebuild (the tab group's visible tab updates with it at once).
    private var lastOnScreenCGIDs: Set<CGWindowID> = []

    /// Global auto-increment counter for physical seat tokens. Guarantees every new seat a unique token
    /// (never derived from a cgID, which gets reused).
    private var nextSeatSerial: Int = 0

    private struct ShadowPoolDiagnosticState {
        var initialized = false
        var updateWasSkipped = false
        var lastSuccessfulRoundID: UInt64?
    }

    private var nextInventoryRoundID: UInt64 = 0
    private var reconcileOrdinalsByPID: [pid_t: UInt64] = [:]
    private var lastReconcileAtByPID: [pid_t: Date] = [:]
    private var shadowPoolDiagnosticsByPID: [pid_t: ShadowPoolDiagnosticState] = [:]
    private var heldLogDeduplicator = InventoryPhantomHeldDeduplicator()

    private struct PendingEventRead {
        let token: UInt64
        let mutationGeneration: UInt64
        let identity: ScanAdmissionDecision.ProcessIdentity
        let source: InventoryReconcileSource
    }

    private var nextEventReadToken: UInt64 = 0
    private var pendingEventReads: [pid_t: PendingEventRead] = [:]
    private var trailingEventSources: [pid_t: InventoryReconcileSource] = [:]
    private var mutationGenerations: [pid_t: UInt64] = [:]

    private let reader: any AppTrackerWindowReading
    private let processProvider: any AppTrackerProcessProviding
    private let cgSnapshotProvider: @Sendable () -> AppTrackerCGWindowSnapshot
    private let onScreenWindowIDsProvider: @Sendable () -> Set<CGWindowID>
    private let eventAXAsyncEnabled: Bool
    /// AX read timeout for the periodic reconcile (5s tick). Default 100ms, time-limited background batch
    /// read; nil (DOCK_RECONCILE_AX_TIMEOUT_MS=0) falls back to the old path: unlimited synchronous per-pid
    /// reads on the main thread. The DOCK_EVENT_AX_ASYNC=0 synchronous compatibility path uses the old path
    /// too.
    private let periodicReconcileTimeout: TimeInterval?
    /// Skip gate for the periodic reconcile (DOCK_RECONCILE_SKIP=0 disables). Applies only to the batch read
    /// path; the old synchronous path is unaffected.
    private let reconcileSkipEnabled: Bool
    private let uptimeProvider: () -> TimeInterval
    /// Table of present displays (the `DisplayTopologyStore` one), cache refreshed on screen parameter
    /// changes; tests inject a fixed table.
    private let displayTableProvider: @MainActor () -> WindowDisplayAttribution.Table
    private var displayTable: WindowDisplayAttribution.Table
    private var screenParametersObserver: NSObjectProtocol?

    /// Per-pid state of the skip gate. Refreshed at the end of reconcileSeats by a successful full read from
    /// **any source** (the frontmost pid stays fresh through the 2Hz frontmost poll and can be skipped by the
    /// periodic tick); AX / workspace events mark it dirty.
    private struct ReconcileGateState {
        var lastCGIDs: Set<CGWindowID>
        var lastFullReadUptime: TimeInterval
        var dirty: Bool
        var lastReadWasUnread: Bool
        var lastRoundChanged: Bool
    }

    private var gateStates: [pid_t: ReconcileGateState] = [:]

    /// Event cache of the frontmost app. Every read of `NSWorkspace.frontmostApplication` is a synchronous LS
    /// XPC round trip (before the change: the 2Hz frontmost poll plus one more per rebuildSnapshot, the main
    /// source of the remaining LS cost in the 2026-08-22 true-idle attribution). Maintained by didActivate
    /// notifications (for **all** activations, not only regular; the cache must reflect the real frontmost
    /// app); the 5s reconcile self-heals with one real query, so a missed notification is wrong for ≤5s at
    /// worst, and the correctness of the active highlight depends only on the value at rebuildSnapshot time,
    /// which the next activation / self-heal always corrects. DOCK_FRONTMOST_CACHE=0 falls back to a real
    /// query every time.
    private let frontmostCacheEnabled: Bool
    private var cachedFrontmostPID: pid_t?

    /// Reuse gate for the full CG list on the event read path (DOCK_CG_SNAPSHOT_REUSE=0 disables). The
    /// decision and the hard ordering rule are in `CGSnapshotReuseDecision`; the cache is refreshed only by a
    /// **fresh capture** on the event read path (a reuse round does not refresh the age, or the age cap would
    /// be void), and the 5s reconcile batch path neither reads nor writes it.
    private let cgSnapshotReuseEnabled: Bool
    /// Global event generation: incremented by any AX / workspace event (markReconcileGateDirty, app added /
    /// removed). The cache records the generation at capture time; a changed generation -> the next event
    /// read captures fresh. Global instead of per-pid is deliberately conservative.
    private var cgEventGeneration: UInt64 = 0
    private var cachedCGSnapshot: AppTrackerCGWindowSnapshot?
    private var cachedCGProbeIDs: Set<CGWindowID>?
    private var cachedCGAtUptime: TimeInterval = -.infinity
    private var cachedCGGeneration: UInt64 = 0

    /// State of the catch-up scan probe gate (DOCK_SCAN_GATE=0 disables). The memo records only "no eligible
    /// window" conclusions; dirty is set by workspace launch notifications; a slow full scan every 60s covers
    /// gate leaks.
    private let scanGateEnabled: Bool
    private var scanMemos: [pid_t: ScanProbeGateDecision.Memo] = [:]
    private var scanDirtyPIDs: Set<pid_t> = []
    private var lastFullScanUptime: TimeInterval?
    /// Cache of the catch-up scan candidate list (pid + bundleID). Property access on
    /// `NSWorkspace.runningApplications` (processIdentifier / bundleIdentifier / isTerminated…) is **one
    /// synchronous LaunchServices XPC per app**; in the 2026-08-22 true-idle attribution it was most of the
    /// scan cost (118/142 samples), and it grows with the number of apps. The list is rebuilt only when
    /// membership may have changed (launch / quit / admission mark it dirty + the 60s slow scan as fallback),
    /// and a quiet tick never touches NSWorkspace; candidate liveness uses ProcessLiveness, and identity is
    /// covered by re-checking the generation at probe time.
    private var scanCandidateCache: [(pid: pid_t, bundleID: String?)]?
    #if DEBUG
    /// Tests only: a fixture pid cannot create a real AXObserver, so this overrides the skip gate's
    /// observerActive criterion.
    private var observerActiveOverridesForTesting: [pid_t: Bool] = [:]
    #endif
    private let windowEligibility = AppTrackerWindowEligibility()
    private let logger = Logger(subsystem: "no.thilip.nitiadock", category: "app-tracker")
    private let inventoryLog: WindowInventoryAnomalyLog

    init(
        inventoryLog: WindowInventoryAnomalyLog = WindowInventoryAnomalyLog(),
        reader: any AppTrackerWindowReading = AXWindowReader(),
        processProvider: any AppTrackerProcessProviding = LiveAppTrackerProcessProvider(),
        cgSnapshotProvider: @escaping @Sendable () -> AppTrackerCGWindowSnapshot = {
            AppTrackerCGWindowSnapshot.capture()
        },
        onScreenWindowIDsProvider: @escaping @Sendable () -> Set<CGWindowID> = {
            AppTrackerCGWindowSnapshot.captureOnScreenWindowIDs()
        },
        eventAXAsyncEnabled: Bool = DebugSwitch.eventAxAsync.isEnabled(in: ProcessInfo.processInfo.environment),
        periodicAXTimeoutMS: Int = Int(DebugSwitch.reconcileAxTimeoutMs.value(in: ProcessInfo.processInfo.environment) ?? "") ?? 100,
        reconcileSkipEnabled: Bool = DebugSwitch.reconcileSkip.isEnabled(in: ProcessInfo.processInfo.environment),
        scanGateEnabled: Bool = DebugSwitch.scanGate.isEnabled(in: ProcessInfo.processInfo.environment),
        frontmostCacheEnabled: Bool = DebugSwitch.frontmostCache.isEnabled(in: ProcessInfo.processInfo.environment),
        cgSnapshotReuseEnabled: Bool = DebugSwitch.cgSnapshotReuse.isEnabled(in: ProcessInfo.processInfo.environment),
        uptimeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        displayTableProvider: @escaping @MainActor () -> WindowDisplayAttribution.Table = { .empty }
    ) {
        self.inventoryLog = inventoryLog
        self.displayTableProvider = displayTableProvider
        self.displayTable = displayTableProvider()
        self.reader = reader
        self.processProvider = processProvider
        self.cgSnapshotProvider = cgSnapshotProvider
        self.onScreenWindowIDsProvider = onScreenWindowIDsProvider
        self.eventAXAsyncEnabled = eventAXAsyncEnabled
        self.periodicReconcileTimeout = periodicAXTimeoutMS > 0 ? TimeInterval(periodicAXTimeoutMS) / 1000.0 : nil
        self.reconcileSkipEnabled = reconcileSkipEnabled
        self.scanGateEnabled = scanGateEnabled
        self.frontmostCacheEnabled = frontmostCacheEnabled
        self.cgSnapshotReuseEnabled = cgSnapshotReuseEnabled
        self.uptimeProvider = uptimeProvider
    }

    func start() {
        guard workspaceObservers.isEmpty else { return }
        let info = Bundle.main.infoDictionary
        inventoryLog.record(.sessionStart(InventorySessionStartPayload(
            version: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String,
            processID: ProcessInfo.processInfo.processIdentifier,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString
        )))
        // Subscribe to notifications before seeding: launch / quit events during the seed are no longer
        // missed (addApp has an apps[pid] == nil guard, so repeated admission is safe).
        subscribeWorkspaceNotifications()
        // Screen parameters changed: skip one turn before refreshing so `TaskbarScreenOrchestrator`
        // has pushed the shared topology snapshot into the common table first.
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleScreenParametersChanged() }
        }
        displayTable = displayTableProvider()
        seedRunningApps()
        startReconcileTimer()
        startFrontmostPollTimer()
        // Four catch-up scan rounds after the seed: hung apps are skipped by the seed's time-limited read,
        // and the scan admits them gradually with inventoryWindows time-limited reads.
        for delay in [0.5, 1.0, 2.0, 4.0] {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.scanNonAdmittedApps()
            }
        }
    }

    func stop() {
        reconcileTimer?.invalidate()
        reconcileTimer = nil
        frontmostPollTimer?.invalidate()
        frontmostPollTimer = nil
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
        for obs in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        workspaceObservers.removeAll()
        for obs in observers.values { obs.stop() }
        observers.removeAll()
        apps.removeAll()
        appOrder.removeAll()
        destroyedCGIDs.removeAll()
        reconcileOrdinalsByPID.removeAll()
        lastReconcileAtByPID.removeAll()
        shadowPoolDiagnosticsByPID.removeAll()
        heldLogDeduplicator.removeAll()
        pendingEventReads.removeAll()
        trailingEventSources.removeAll()
        mutationGenerations.removeAll()
        gateStates.removeAll()
        scanMemos.removeAll()
        scanDirtyPIDs.removeAll()
        lastFullScanUptime = nil
        scanCandidateCache = nil
        cachedFrontmostPID = nil
        snapshot = .empty
        inventoryLog.flush()
    }

    // MARK: - Tombstone

    private func isTombstoned(_ cgID: CGWindowID) -> Bool {
        guard let removedAt = destroyedCGIDs[cgID] else { return false }
        return Date().timeIntervalSince(removedAt) <= Self.tombstoneTTL
    }

    private func purgeStaleTombstones() {
        let now = Date()
        destroyedCGIDs = destroyedCGIDs.filter { _, date in
            now.timeIntervalSince(date) <= Self.tombstoneTTL
        }
    }

    /// The system reuses cgIDs: on real window destruction the cgID is removed at once from every seat
    /// history (formerCgIDs) and from the shadow tab pool, so that after reuse by a new window it is not
    /// wrongly absorbed by member / shadow pool folding. Cleared across pids (cgIDs are globally unique and
    /// reuse ignores the process).
    private func purgeFromSeatHistories(_ cgID: CGWindowID) {
        for pid in appOrder {
            guard var app = apps[pid] else { continue }
            var touched = false
            if app.shadowTabCgIDs.remove(cgID) != nil { touched = true }
            for wid in app.windowOrder where app.windowsByID[wid]?.formerCgIDs.contains(cgID) == true {
                app.windowsByID[wid]?.formerCgIDs.remove(cgID)
                touched = true
            }
            if touched { apps[pid] = app }
        }
    }

    /// "Same pid + pixel-identical frame" key. A physical seat uses it to claim the new current tab of a "tab
    /// switch replacement": the tabs of one physical window have exactly the same frame, so the new current
    /// tab appears on the seat's current frame.
    private func frameKey(_ pid: pid_t, _ bounds: CGRect?) -> String? {
        guard let b = bounds else { return nil }
        return "\(pid)|\(Int(b.origin.x.rounded())):\(Int(b.origin.y.rounded())):\(Int(b.size.width.rounded())):\(Int(b.size.height.rounded()))"
    }

    /// Physical seat reconcile (single-seat model, tab drag root fix step 1). Converges an app's current
    /// AX-eligible windows into "one physical window = one seat". The seat is anchored to the frame, and the
    /// token, once assigned, does not follow the current tab's cgID:
    /// - **Tab switch**: the old activeCgID leaves AX and a new cgID takes its place on the same frame -> the
    ///   seat swaps activeCgID in place, token unchanged (the card does not jump).
    /// - **Current tab dragged out**: the old activeCgID moves to a new frame and another tab takes the old
    ///   frame -> the seat stays on the old frame with the new tab, and the old activeCgID is "evicted" into
    ///   a new seat (tear-out splits off a card).
    /// - **Minimized / in background with no replacement**: while still in CG the seat is kept and marked
    ///   minimized; it is removed only once CG drops it (Safari minimize keeps its card).
    /// - Background tabs do NOT keep their own seat. With several old seats on one frame (overlapping
    ///   windows) nothing is replaced and a new seat is created instead, to avoid wrong merges.
    /// Returns true when the seat set or key attributes changed (the caller uses it to decide whether to
    /// rebuild the snapshot).
    @discardableResult
    private func reconcileSeats(
        pid: pid_t,
        cgSnapshot: AppTrackerCGWindowSnapshot,
        now: Date,
        source: InventoryReconcileSource,
        preloadedEligible: [AXWindowSnapshot]? = nil,
        preloadedReadOutcome: InventoryAXReadOutcome? = nil,
        preloadedReadMode: InventoryReconcileReadMode? = nil
    ) -> Bool {
        guard var app = apps[pid] else { return false }
        let cgIDs = cgSnapshot.allWindowIDs
        let onScreenCGIDs = cgSnapshot.onScreenWindowIDs
        let cgPidIDs = cgSnapshot.windowIDsByPID[pid] ?? []
        // The shadow tab pool is judged against the PREVIOUS round's snapshot: in a minimize burst all tabs
        // flood into AX, so a pool computed this round would be empty.
        let shadowPool = app.shadowTabCgIDs
        let eligible: [AXWindowSnapshot]
        let axReadOutcome: InventoryAXReadOutcome
        if let preloaded = preloadedEligible {
            eligible = preloaded
            axReadOutcome = preloadedReadOutcome ?? .success(count: preloaded.count)
        } else {
            switch mainActorWindowRead(forPID: pid) {
            case .success(let windows):
                axReadOutcome = .success(count: windows.count)
                eligible = windows.filter {
                    isEligible(
                        $0,
                        application: eligibilityApplication(for: app),
                        cgSnapshot: cgSnapshot
                    )
                }
            case .unread(let error):
                axReadOutcome = .unread(errorCode: error.rawValue)
                eligible = []
            }
        }
        if axReadOutcome.kind == .unread {
            // An unread AX round is unknown, never evidence of absence. In particular it must not
            // start grace periods, update the shadow-tab pool, or advance phantom healing.
            inventoryLog.record(.reconcileUnread(InventoryReconcileUnreadPayload(
                pid: pid,
                bundleID: app.bundleIdentifier,
                source: source,
                readMode: preloadedReadMode ?? .untimed,
                usedPreloadedAX: preloadedEligible != nil,
                errorCode: axReadOutcome.errorCode ?? AXError.failure.rawValue
            )))
            gateStates[pid]?.lastReadWasUnread = true
            return false
        }
        let reconcileContext = inventoryLog.isEnabled
            ? inventoryReconcileContext(
                pid: pid,
                source: source,
                now: now,
                usedPreloadedAX: preloadedEligible != nil,
                axReadOutcome: axReadOutcome
            )
            : nil
        func fk(_ b: CGRect?) -> String? { frameKey(pid, b) }

        var eligibleByCgID: [CGWindowID: AXWindowSnapshot] = [:]
        for s in eligible { if let c = s.cgWindowID { eligibleByCgID[c] = s } }

        // Also feed the AX elements to the action path's side cache (see the `AXElementCache` comment). This
        // is the only write site: this round has passed the `.unread` early-exit gate, so the elements were
        // really read. **A cgID missing from AX this round is not removed for that reason**: Safari-family
        // windows leave AXWindows entirely once minimized, which is exactly when the cache matters most.
        // Removal only follows the full CG list (the retain line below), destroy notifications and process
        // exit.
        if AXElementCache.isEnabled {
            for (c, s) in eligibleByCgID { elementCache.store(pid: pid, cgWindowID: c, element: s.element) }
            elementCache.retain(pid: pid, liveCGWindowIDs: cgIDs)
        }

        let before = seatSignature(app)
        var usedEligible: Set<CGWindowID> = []
        var newOrder: [CGWindowID] = []
        var newByID: [CGWindowID: WindowEntry] = [:]
        func place(_ e: WindowEntry) { newOrder.append(e.cgWindowID); newByID[e.cgWindowID] = e }
        // history = the "former active tabs" set inherited when the seat continues. Intersected with the full
        // CG list: tabs that really closed drop out, so a reused cgID is not wrongly folded into the old
        // seat. wasEverVisible = whether the seat was visible before (inherited on continuation); appearing
        // with min=false this time counts too. A phantom seat never gets this flag (the first threshold of
        // the self-heal decision).
        func make(token: String, _ s: AXWindowSnapshot, previousTitle: String? = nil,
                  history: Set<CGWindowID> = [], wasEverVisible: Bool = false,
                  previousDisplayUUID: String? = nil, previousHoldUntil: Date? = nil) -> WindowEntry {
            // The attribution key follows the frame only while visible; minimized / hidden keeps the previous
            // seat's value (frozen on the last visible display); the optimistic key of a cross-display drag
            // does not move during the freeze either; a pinned one (`.distantFuture`) is released only when
            // this AX read really sees a visible frame.
            let visible = !s.isMinimized && !app.isHidden
            let fresh = visible ? WindowDisplayAttribution.displayUUID(for: s.bounds, table: displayTable) : nil
            let sticky = previousHoldUntil == .distantFuture
            let held = !sticky && (previousHoldUntil.map { $0 > now } ?? false)
            let displayUUID: String?
            let holdUntil: Date?
            if sticky {
                displayUUID = fresh ?? previousDisplayUUID
                holdUntil = fresh == nil ? previousHoldUntil : nil
            } else if held {
                displayUUID = previousDisplayUUID
                holdUntil = previousHoldUntil
            } else {
                displayUUID = fresh ?? previousDisplayUUID
                holdUntil = nil
            }
            return WindowEntry(cgWindowID: s.cgWindowID!, token: token,
                               title: s.titleRead.resolvedTitle(previousTitle: previousTitle),
                               bounds: s.bounds, isMinimized: s.isMinimized, isFocused: s.isFocusedWindow,
                               everSeenVisible: wasEverVisible || !s.isMinimized,
                               formerCgIDs: history.subtracting([s.cgWindowID!]).intersection(cgIDs),
                               displayUUID: displayUUID,
                               displayUUIDHoldUntil: holdUntil)
        }
        // How many old seats currently claim a frame (>1 = overlapping-window ambiguity: skipped for tab
        // switch replacement, conservatively no merge)
        func seatsAtFrame(_ key: String) -> Int {
            app.windowOrder.filter { fk(app.windowsByID[$0]?.bounds) == key }.count
        }

        // Number of seats whose current activeCgID is still in AX: the "sibling seat present" threshold of
        // phantom self-heal (the phantom itself is absent, so it is not counted).
        let axPresentSeatCount = app.windowOrder.filter { eligibleByCgID[$0] != nil }.count
        var healedSeats: [(cgID: CGWindowID, token: String, episodeID: UUID)] = []
        var releasedSeats: [(seat: WindowEntry, reason: InventorySeatReleasedReason)] = []
        var tearOutCgIDs: Set<CGWindowID> = []
        // Seats released because they merged in as tabs -> owning seat (member learning, written back in one
        // go after Pass A since the owner may not be seated yet).
        var mergedIntoOwner: [(cgID: CGWindowID, ownerActiveCgID: CGWindowID)] = []
        // Sibling view for TabMergeDecision: old seats present in AX this round, frames taken from this
        // round's AX snapshot (the seat's own may be stale).
        func axPresentSeatsForMerge(excluding candidate: CGWindowID) -> [TabMergeDecision.AXPresentSeat] {
            app.windowOrder.compactMap { id in
                guard id != candidate, let snap = eligibleByCgID[id] else { return nil }
                return TabMergeDecision.AXPresentSeat(activeCgID: id, bounds: snap.bounds, isMinimized: snap.isMinimized)
            }
        }

        // Pass A: each old seat tries to continue
        for cgID in app.windowOrder {
            guard var seat = app.windowsByID[cgID] else { continue }
            let X = seat.cgWindowID
            let seatKey = fk(seat.bounds)
            if let snapX = eligibleByCgID[X], !usedEligible.contains(X) {
                if inventoryLog.isEnabled, let episodeID = seat.absenceEpisodeID {
                    heldLogDeduplicator.clear(pid: pid, seatToken: seat.token, episodeID: episodeID)
                }
                InventoryAbsenceEpisode.clear(
                    absentSince: &seat.minAbsentSince,
                    episodeID: &seat.absenceEpisodeID
                )
                // X is still visible. Check "current tab dragged out": X moved to a new frame and another
                // eligible window Y came up on the old frame. **No tear-out during a cross-display move
                // freeze** (`displayUUIDHoldUntil` valid / pinned): we wrote that frame move ourselves, and
                // the seat must follow X. Otherwise the seat stays on the old frame, adopts Y and inherits
                // the key just written for the target display plus the freeze, while X falls to Pass B as a
                // new seat: both cards sit on the target bar, and once the freeze ends the old seat jumps
                // back to the source display (2026-09-03, multi-tab Finder).
                let moveHeld = seat.displayUUIDHoldUntil.map { $0 == .distantFuture || $0 > now } ?? false
                if let seatKey, fk(snapX.bounds) != seatKey, !moveHeld,
                   let Y = eligible.first(where: { s in
                       // Y must be a window that has no seat yet (the tab that surfaced). A window
                       // that already owns a seat merely shares the frame (two zoomed windows):
                       // taking it over left it in the order twice.
                       guard let c = s.cgWindowID, c != X, !usedEligible.contains(c),
                             app.windowsByID[c] == nil else { return false }
                       return fk(s.bounds) == seatKey
                   }), let yc = Y.cgWindowID {
                    // The seat stays on the old frame and is replaced by Y, token unchanged. X is evicted as
                    // an independent window -> NOT recorded in history
                    place(make(token: seat.token, Y, history: seat.formerCgIDs,
                               wasEverVisible: seat.everSeenVisible,
                               previousDisplayUUID: seat.displayUUID,
                               previousHoldUntil: seat.displayUUIDHoldUntil))
                    usedEligible.insert(yc)
                    observers[pid]?.registerWindow(Y.element, cgWindowID: yc)   // taking over a new activeCgID requires subscribing, see the replacement branch below
                    tearOutCgIDs.insert(X)
                    // X is not marked used -> falls to Pass B as a new seat (the evicted current tab)
                } else {
                    // Normal: follow X (the frame may move)
                    if case .unread(let error) = snapX.titleRead, let reconcileContext {
                        inventoryLog.record(.titleHeld(InventoryTitleHeldPayload(
                            context: reconcileContext,
                            pid: pid,
                            bundleID: app.bundleIdentifier,
                            seatToken: seat.token,
                            activeCgID: X,
                            errorCode: error.rawValue
                        )))
                    }
                    place(make(token: seat.token, snapX, previousTitle: seat.title,
                               history: seat.formerCgIDs,
                               wasEverVisible: seat.everSeenVisible,
                               previousDisplayUUID: seat.displayUUID,
                               previousHoldUntil: seat.displayUUIDHoldUntil))
                    usedEligible.insert(X)
                }
            } else {
                // X left AX: did a new current tab take over the old frame -> tab switch
                if let seatKey, seatsAtFrame(seatKey) == 1,
                   let Y = eligible.first(where: { s in
                       guard let c = s.cgWindowID, !usedEligible.contains(c), app.windowsByID[c] == nil else { return false }
                       return fk(s.bounds) == seatKey
                   }), let yc = Y.cgWindowID {
                    if inventoryLog.isEnabled, let episodeID = seat.absenceEpisodeID {
                        heldLogDeduplicator.clear(pid: pid, seatToken: seat.token, episodeID: episodeID)
                    }
                    InventoryAbsenceEpisode.clear(
                        absentSince: &seat.minAbsentSince,
                        episodeID: &seat.absenceEpisodeID
                    )
                    // Replaced, token unchanged -> the card does not jump. X is the background tab switched
                    // away from -> recorded in history (a closed tab has a tombstone / has left CG, and the
                    // intersection in make keeps really closed ones out)
                    var history = seat.formerCgIDs
                    if !isTombstoned(X) { history.insert(X) }
                    place(make(token: seat.token, Y, history: history,
                               wasEverVisible: seat.everSeenVisible,
                               previousDisplayUUID: seat.displayUUID,
                               previousHoldUntil: seat.displayUUIDHoldUntil))
                    usedEligible.insert(yc)
                    // The Y taking over must subscribe to per-window notifications here
                    // (destroy/min/demin/title are subscribed only at the three places that take over an
                    // activeCgID: new seat, replacement, drag-out swap). Otherwise closing Y sends no destroy
                    // notification -> no tombstone; a window Ghostty closed lingers in the full CG list, and
                    // the seat takes the "still in CG" retention branch and leaves a phantom card forever
                    // (measured 2026-08-23, closing the last tab of a minimized tab group).
                    observers[pid]?.registerWindow(Y.element, cgWindowID: yc)
                } else if cgIDs.contains(X) && !isTombstoned(X) {
                    // X left AX but is still in CG. Tell "minimized / hidden (keep the seat)" from "window
                    // lingering in CG after close (remove)": signal = whether it was min the last time before
                    // leaving AX (minimizing first marks min through the Miniaturized notification; closing
                    // does not).
                    seat.formerCgIDs.formIntersection(cgIDs)   // history reuse guard: out of CG means out of history
                    if seat.isMinimized || app.isHidden {
                        InventoryAbsenceEpisode.beginIfNeeded(
                            absentSince: &seat.minAbsentSince,
                            episodeID: &seat.absenceEpisodeID,
                            now: now
                        )
                        let absentFor = now.timeIntervalSince(seat.minAbsentSince ?? now)
                        let evaluation = PhantomSeatDecision.evaluate(
                            everSeenVisible: seat.everSeenVisible,
                            axAbsentFor: absentFor,
                            threshold: Self.phantomReapGrace,
                            cgStillPresent: true,
                            axReadSawWindows: !eligible.isEmpty,
                            axPresentSiblingCount: axPresentSeatCount
                        )
                        // Phantom seat self-heal: never visible + absent from AX long enough + app not hung +
                        // a sibling seat present in AX -> judged a phantom split off by a failed fold and
                        // released (not placed). Really minimized / hidden windows fail the everSeenVisible
                        // or sibling threshold and keep their seat indefinitely as before.
                        if evaluation.shouldRelease, let episodeID = seat.absenceEpisodeID {
                            healedSeats.append((X, seat.token, episodeID))
                            releasedSeats.append((seat, .phantomHealed))
                            if inventoryLog.isEnabled {
                                heldLogDeduplicator.clear(
                                    pid: pid, seatToken: seat.token, episodeID: episodeID
                                )
                            }
                        } else {
                            if let reconcileContext,
                               absentFor >= Self.phantomReapGrace,
                               let episodeID = seat.absenceEpisodeID,
                               heldLogDeduplicator.shouldRecord(
                                   pid: pid,
                                   seatToken: seat.token,
                                   episodeID: episodeID,
                                   reasons: evaluation.holdReasons
                               ) {
                                inventoryLog.record(.phantomHeld(InventoryPhantomHeldPayload(
                                    context: reconcileContext,
                                    pid: pid,
                                    bundleID: app.bundleIdentifier,
                                    seatToken: seat.token,
                                    activeCgID: X,
                                    absenceEpisodeID: episodeID,
                                    holdReasons: evaluation.holdReasons.map(\.rawValue).sorted(),
                                    appHidden: app.isHidden,
                                    everSeenVisible: seat.everSeenVisible,
                                    absentForMs: Int((absentFor * 1_000).rounded()),
                                    thresholdMs: Int((Self.phantomReapGrace * 1_000).rounded()),
                                    eligibleWindowCount: eligible.count,
                                    axPresentSiblingCount: axPresentSeatCount,
                                    bounds: seat.bounds.map(InventoryLogRect.init)
                                )))
                            }
                            seat.isFocused = false
                            place(seat)                   // really minimized (Safari leaves AX) / app hidden -> keep the seat
                        }
                    } else {
                        // Not minimized, app not hidden, yet it left AX: first ask whether it was merged into
                        // another window as a background tab (TabMergeDecision: CG says off screen + CG
                        // bounds match the frame of a sibling seat present in AX). Yes -> release, otherwise
                        // one window gets two cards and every later tab switch splits off another.
                        let mergeVerdict = TabMergeDecision.verdict(
                            candidateIsOnScreen: onScreenCGIDs.contains(X),
                            candidateCGBounds: cgSnapshot.boundsByWindowID[X],
                            candidateSeatBounds: seat.bounds,
                            axPresentSeats: axPresentSeatsForMerge(excluding: X),
                            frameKey: fk
                        )
                        if case .release(let owner) = mergeVerdict {
                            releasedSeats.append((seat, .mergedIntoTabbedWindow))
                            if let owner { mergedIntoOwner.append((cgID: X, ownerActiveCgID: owner)) }
                        } else {
                            seat.isFocused = false
                            // AX success does not mean the window list is complete. As long as CG still
                            // confirms the current activeCgID exists and there is no destroy tombstone, the
                            // seat is kept; AX absence alone can never prove the window closed.
                            place(seat)
                        }
                    }
                } else {
                    // Gone from CG too -> really closed, drop it.
                    releasedSeats.append((seat, .leftCGList))
                }
            }
        }

        // Pass B: unclaimed eligible windows -> new seats (new window / evicted current tab). The token uses
        // a global auto-increment counter, NEVER derived from cgID: cgIDs are reused and deriving from them
        // collides (measured: old seat seed=68 with activeCgID already 60, then 68 became its own window and
        // produced the same token -> two seats on one card).
        // **Minimize fold**: when a multi-tab window is minimized, Ghostty exposes ALL tabs of that window at
        // once as AX windows (normally only the current tab). They are all min=true, background tabs of the
        // same (minimized) window, and fold into the already placed seat without creating new ones (otherwise
        // one card splits off per tab).
        // Three decision levels (TabFoldDecision): membership (was this seat's active tab, independent of
        // geometry) -> exact frame match -> size fallback (same width / height + off screen, rescues
        // "background tab AX coordinates stale after a window move"). A fold with a unique owner records the
        // candidate in the seat history (member learning), so the next fold no longer depends on geometry.
        // A non-min window on the same frame is the legitimate "two independent windows overlap" case and
        // gets its own seat as usual.
        // Member learning for merged-in tabs: the owning seat is always seated in Pass A this round (it is
        // present in AX), so it is written back before Pass B and a minimize burst right after in the same
        // round can still fold by membership.
        for merged in mergedIntoOwner {
            newByID[merged.ownerActiveCgID]?.formerCgIDs.insert(merged.cgID)
        }
        var placedForFold: [TabFoldDecision.PlacedSeat] = newOrder.compactMap { id in
            guard let e = newByID[id] else { return nil }
            return TabFoldDecision.PlacedSeat(activeCgID: e.cgWindowID, bounds: e.bounds,
                                              isMinimized: e.isMinimized, formerCgIDs: e.formerCgIDs)
        }
        for s in eligible {
            guard let c = s.cgWindowID, !usedEligible.contains(c), newByID[c] == nil else { continue }
            let verdict = TabFoldDecision.verdict(
                candidateCgID: c,
                candidateBounds: s.bounds,
                candidateIsMinimized: s.isMinimized,
                candidateIsOnScreen: onScreenCGIDs.contains(c),
                candidateIsKnownShadow: shadowPool.contains(c),
                placedSeats: placedForFold,
                frameKey: fk
            )
            switch verdict {
            case .fold(let owner, _):
                usedEligible.insert(c)   // background tab -> folded into the existing seat, no new one
                if let owner { newByID[owner]?.formerCgIDs.insert(c) }   // member learning
            case .newSeat:
                let hadPlacedSeat = !placedForFold.isEmpty
                if s.isMinimized, !placedForFold.isEmpty {
                    // Diagnostics (permanent): a min=true candidate that fails all four decision levels and
                    // reaches new seat creation while seats are already placed = potential split point; dump
                    // every decision input to capture the scene. placed empty (an independent window that was
                    // already minimized at seed) is a correct new seat and is not logged. The normal path
                    // prints nothing: do not clean this up as leftover again.
                    let cand = s.bounds.map { "\(Int($0.origin.x)),\(Int($0.origin.y)) \(Int($0.width))x\(Int($0.height))" } ?? "nil"
                    let placedDesc = placedForFold.map { p in
                        let b = p.bounds.map { "\(Int($0.origin.x)),\(Int($0.origin.y)) \(Int($0.width))x\(Int($0.height))" } ?? "nil"
                        return "(cg=\(p.activeCgID) min=\(p.isMinimized) b=[\(b)] hist=\(p.formerCgIDs.sorted()))"
                    }.joined(separator: " ")
                    print("[tabfold] split point pid=\(pid) new seat for min window cg=\(c) b=[\(cand)] onScreen=\(onScreenCGIDs.contains(c)) shadow=\(shadowPool.contains(c)) pool=\(shadowPool.count) placed=\(placedDesc)")
                }
                nextSeatSerial += 1
                let entry = make(token: "tabgrp-\(pid)-s\(nextSeatSerial)", s)
                if let reconcileContext {
                    let isOnScreen = onScreenCGIDs.contains(c)
                    let creationReason = InventorySeatCreationReason.classify(
                        hasPlacedSeat: hadPlacedSeat,
                        isTearOut: tearOutCgIDs.contains(c),
                        isMinimized: s.isMinimized,
                        isOnScreen: isOnScreen
                    )
                    let relations: [InventorySeatRelation] = newOrder.compactMap { id in
                        guard let existing = newByID[id] else { return nil }
                        let exactFrame = fk(existing.bounds) != nil && fk(existing.bounds) == fk(s.bounds)
                        let nearbyFrame: Bool
                        if let lhs = existing.bounds, let rhs = s.bounds {
                            nearbyFrame = WindowFrameMatchPolicy.areClose(lhs, rhs)
                        } else {
                            nearbyFrame = false
                        }
                        let sizeMatches: Bool
                        if let lhs = existing.bounds, let rhs = s.bounds {
                            sizeMatches = abs(lhs.width - rhs.width) < 3 && abs(lhs.height - rhs.height) < 3
                        } else {
                            sizeMatches = false
                        }
                        return InventorySeatRelation(
                            seatToken: existing.token,
                            activeCgID: existing.cgWindowID,
                            isMinimized: existing.isMinimized,
                            everSeenVisible: existing.everSeenVisible,
                            bounds: existing.bounds.map(InventoryLogRect.init),
                            formerCgIDs: existing.formerCgIDs.sorted(),
                            formerContainsCandidate: existing.formerCgIDs.contains(c),
                            normalizedTitleMatches: WindowInventoryDiagnosticRelations.normalizedTitlesMatch(
                                existing.title, s.title
                            ),
                            exactFrameMatches: exactFrame,
                            nearbyFrameMatches: nearbyFrame,
                            sizeMatches: sizeMatches
                        )
                    }
                    inventoryLog.record(.seatCreated(InventorySeatCreatedPayload(
                        context: reconcileContext,
                        pid: pid,
                        bundleID: app.bundleIdentifier,
                        seatToken: entry.token,
                        activeCgID: c,
                        creationReason: creationReason,
                        isMinimized: s.isMinimized,
                        isOnScreen: isOnScreen,
                        isFocused: s.isFocusedWindow,
                        appHidden: app.isHidden,
                        bounds: s.bounds.map(InventoryLogRect.init),
                        candidateKnownShadow: shadowPool.contains(c),
                        eligibleWindowCount: eligible.count,
                        minimizedEligibleCount: eligible.filter(\.isMinimized).count,
                        onScreenEligibleCount: eligible.compactMap(\.cgWindowID).filter {
                            onScreenCGIDs.contains($0)
                        }.count,
                        cgWindowCount: cgPidIDs.count,
                        eligibleCgIDs: eligible.compactMap(\.cgWindowID).sorted(),
                        cgWindowIDs: cgPidIDs.sorted(),
                        shadowPool: shadowPool.sorted(),
                        existingSeats: relations
                    )))
                }
                place(entry)
                observers[pid]?.registerWindow(s.element, cgWindowID: c)
                placedForFold.append(TabFoldDecision.PlacedSeat(activeCgID: entry.cgWindowID, bounds: entry.bounds,
                                                                isMinimized: entry.isMinimized, formerCgIDs: entry.formerCgIDs))
            }
        }

        // Phantom self-heal bookkeeping: with exactly one seat present in AX the released cgID is recorded in
        // its history (the next burst folds at once by membership); with several seats it is ambiguous and
        // nothing is learned. The released id returns to the shadow pool anyway and is still blocked by the
        // pool.
        if !healedSeats.isEmpty {
            let axPresentPlaced = newOrder.filter { eligibleByCgID[$0] != nil }
            let ownerCandidates = axPresentPlaced.compactMap { cgID -> InventoryPhantomOwner? in
                guard let token = newByID[cgID]?.token else { return nil }
                return InventoryPhantomOwner(seatToken: token, activeCgID: cgID)
            }
            let owner = InventoryPhantomOwnerResolution.uniqueOwner(from: ownerCandidates)
            for healed in healedSeats {
                if let owner {
                    newByID[owner.activeCgID]?.formerCgIDs.insert(healed.cgID)
                }
                if let reconcileContext {
                    inventoryLog.record(.phantomHealed(InventoryPhantomHealedPayload(
                        context: reconcileContext,
                        pid: pid,
                        bundleID: app.bundleIdentifier,
                        releasedSeatToken: healed.token,
                        releasedActiveCgID: healed.cgID,
                        absenceEpisodeID: healed.episodeID,
                        ownerSeatToken: owner?.seatToken,
                        ownerActiveCgID: owner?.activeCgID,
                        ownerCandidateCount: ownerCandidates.count
                    )))
                }
                let ownerDescription = owner.map { String($0.activeCgID) } ?? "none (ambiguous)"
                print("[tabheal] self-heal pid=\(pid) released phantom seat cg=\(healed.cgID) merged into=\(ownerDescription)")
            }
        }

        for released in releasedSeats {
            let snapshot = inventorySeatReleaseSnapshot(app: app, seats: [released.seat])
            for payload in InventorySeatReleasePlan.payloads(
                for: snapshot,
                reason: released.reason,
                context: reconcileContext
            ) {
                inventoryLog.record(.seatReleased(payload))
            }
        }

        // Roll the shadow tab pool to the next round (this round's decisions used the old pool). Health
        // threshold: AX read no window at all while CG still has some (app hung / AX read failed) -> leave
        // the pool alone this round. Rules: out of CG (really closed) -> out of the pool; appearing in AX
        // with min=false (active tab / really visible window / torn-out tab) -> out of the pool; in CG but
        // not in AX and not a seated activeCgID (Safari-style real windows retained as min and grace-held
        // seats stay out of the pool, so they are not wrongly folded after a seat is lost) -> into the pool.
        // Appearing in AX with min=true does not leave the pool: that is the minimize burst itself, and the
        // pool must hold through the whole minimized period.
        let shouldUpdateShadowPool = !eligible.isEmpty || cgPidIDs.isEmpty
        if shouldUpdateShadowPool {
            var pool = app.shadowTabCgIDs
            pool.formIntersection(cgPidIDs)
            for s in eligible { if let c = s.cgWindowID, !s.isMinimized { pool.remove(c) } }
            pool.formUnion(cgPidIDs.subtracting(eligibleByCgID.keys).subtracting(newOrder))
            app.shadowTabCgIDs = pool

            if let reconcileContext {
                var diagnostic = shadowPoolDiagnosticsByPID[pid] ?? ShadowPoolDiagnosticState()
                func recordShadowPool(_ status: InventoryShadowPoolStatus) {
                    inventoryLog.record(.shadowPoolState(InventoryShadowPoolPayload(
                        context: reconcileContext,
                        pid: pid,
                        bundleID: app.bundleIdentifier,
                        status: status,
                        previousSuccessfulRoundID: diagnostic.lastSuccessfulRoundID,
                        before: shadowPool.sorted(),
                        after: pool.sorted(),
                        added: pool.subtracting(shadowPool).sorted(),
                        removed: shadowPool.subtracting(pool).sorted(),
                        eligibleWindowCount: eligible.count,
                        cgWindowCount: cgPidIDs.count
                    )))
                }
                if !diagnostic.initialized {
                    recordShadowPool(.initialized)
                }
                if diagnostic.updateWasSkipped {
                    recordShadowPool(.resumed)
                } else if diagnostic.initialized, pool != shadowPool {
                    recordShadowPool(.changed)
                }
                diagnostic.initialized = true
                diagnostic.updateWasSkipped = false
                diagnostic.lastSuccessfulRoundID = reconcileContext.roundID
                shadowPoolDiagnosticsByPID[pid] = diagnostic
            }
        } else if let reconcileContext {
            var diagnostic = shadowPoolDiagnosticsByPID[pid] ?? ShadowPoolDiagnosticState()
            if !diagnostic.updateWasSkipped {
                inventoryLog.record(.shadowPoolState(InventoryShadowPoolPayload(
                    context: reconcileContext,
                    pid: pid,
                    bundleID: app.bundleIdentifier,
                    status: .updateSkipped,
                    previousSuccessfulRoundID: diagnostic.lastSuccessfulRoundID,
                    before: shadowPool.sorted(),
                    after: shadowPool.sorted(),
                    added: [],
                    removed: [],
                    eligibleWindowCount: eligible.count,
                    cgWindowCount: cgPidIDs.count
                )))
            }
            diagnostic.updateWasSkipped = true
            shadowPoolDiagnosticsByPID[pid] = diagnostic
        }

        app.windowOrder = newOrder
        app.windowsByID = newByID
        apps[pid] = app
        let changed = seatSignature(app) != before
        gateStates[pid] = ReconcileGateState(
            lastCGIDs: cgPidIDs,
            lastFullReadUptime: uptimeProvider(),
            dirty: false,
            lastReadWasUnread: false,
            lastRoundChanged: changed || app.shadowTabCgIDs != shadowPool
        )
        return changed
    }

    private func inventoryReconcileContext(
        pid: pid_t,
        source: InventoryReconcileSource,
        now: Date,
        usedPreloadedAX: Bool,
        axReadOutcome: InventoryAXReadOutcome
    ) -> InventoryReconcileContext {
        nextInventoryRoundID += 1
        let ordinal = (reconcileOrdinalsByPID[pid] ?? 0) + 1
        let gapMs = lastReconcileAtByPID[pid].map {
            max(0, Int((now.timeIntervalSince($0) * 1_000).rounded()))
        }
        reconcileOrdinalsByPID[pid] = ordinal
        lastReconcileAtByPID[pid] = now
        return InventoryReconcileContext(
            roundID: nextInventoryRoundID,
            appReconcileOrdinal: ordinal,
            source: source,
            gapMs: gapMs,
            usedPreloadedAX: usedPreloadedAX,
            axReadOutcome: axReadOutcome
        )
    }

    private func clearInventoryDiagnostics(pid: pid_t) {
        reconcileOrdinalsByPID.removeValue(forKey: pid)
        lastReconcileAtByPID.removeValue(forKey: pid)
        shadowPoolDiagnosticsByPID.removeValue(forKey: pid)
        heldLogDeduplicator.removeAll(pid: pid)
    }

    private func inventorySeatReleaseSnapshot(
        app: AppEntry,
        seats: [WindowEntry]? = nil
    ) -> InventorySeatReleaseSnapshot {
        let selected = seats ?? app.windowOrder.compactMap { app.windowsByID[$0] }
        return InventorySeatReleaseSnapshot(
            pid: app.pid,
            bundleID: app.bundleIdentifier,
            appHidden: app.isHidden,
            seats: selected.map { entry in
                InventorySeatReleaseSnapshot.Seat(
                    seatToken: entry.token,
                    activeCgID: entry.cgWindowID,
                    isMinimized: entry.isMinimized,
                    isFocused: entry.isFocused,
                    everSeenVisible: entry.everSeenVisible,
                    bounds: entry.bounds
                )
            }
        )
    }

    private func recordProcessGoneSeats(app: AppEntry) {
        let snapshot = inventorySeatReleaseSnapshot(app: app)
        for payload in InventorySeatReleasePlan.processGonePayloads(for: snapshot) {
            inventoryLog.record(.seatReleased(payload))
        }
    }

    /// Lightweight fingerprint of the seat set (order + token + title + minimized / focus + display), used to
    /// tell whether this reconcile actually changed anything. The display is the coarse display UUID; **the
    /// coordinates themselves never enter the fingerprint**.
    private func seatSignature(_ app: AppEntry) -> String {
        app.windowOrder.map { id -> String in
            let e = app.windowsByID[id]
            return "\(id):\(e?.token ?? ""):\(e?.title ?? ""):\(e?.isMinimized == true ? 1 : 0):\(e?.isFocused == true ? 1 : 0):\(e?.displayUUID ?? "")"
        }.joined(separator: "|")
    }

    // MARK: - Display attribution (multi-display ④)

    /// 5s tick: recomputes the display of **all** visible seats from CG bounds, covering pids skipped by the
    /// skip gate that got no AX read (a background app's window moved to another display switches within 5s
    /// at most). Changes only the attribution key, **never `bounds`** (the AX frame that `frameKey` /
    /// `seatsAtFrame` rely on) nor the skip gate state. CG unreadable / touching no display -> keep the old
    /// key.
    private func refreshDisplayAttributionFromCG(_ cgSnapshot: AppTrackerCGWindowSnapshot) -> Bool {
        guard !cgSnapshot.boundsByWindowID.isEmpty, !displayTable.displays.isEmpty else { return false }
        let now = Date()
        var changed = false
        for pid in appOrder {
            guard let app = apps[pid], !app.isHidden else { continue }
            for cgID in app.windowOrder {
                guard let seat = app.windowsByID[cgID], !seat.isMinimized,
                      !(seat.displayUUIDHoldUntil.map { $0 > now } ?? false),
                      let rect = cgSnapshot.boundsByWindowID[cgID],
                      let key = WindowDisplayAttribution.displayUUID(for: rect, table: displayTable),
                      key != seat.displayUUID else { continue }
                apps[pid]?.windowsByID[cgID]?.displayUUID = key
                changed = true
            }
        }
        return changed
    }

    /// Screen parameter change (replug / new main display / rearrangement): swap the display table and
    /// recompute visible seats from stored AX frames; where that fails keep the old key (the projection layer
    /// puts keys pointing at an unplugged display on the main display). No AX read, no CG capture.
    private func handleScreenParametersChanged() {
        displayTable = displayTableProvider()
        let now = Date()
        var changed = false
        for pid in appOrder {
            guard let app = apps[pid], !app.isHidden else { continue }
            for cgID in app.windowOrder {
                guard let seat = app.windowsByID[cgID], !seat.isMinimized,
                      !(seat.displayUUIDHoldUntil.map { $0 > now } ?? false),
                      let key = WindowDisplayAttribution.displayUUID(for: seat.bounds, table: displayTable),
                      key != seat.displayUUID else { continue }
                apps[pid]?.windowsByID[cgID]?.displayUUID = key
                changed = true
            }
        }
        if changed { rebuildSnapshot(onScreenCGIDs: lastOnScreenCGIDs) }
    }

    /// Optimistic update for a cross-display drag (`AppRuntime.moveWindow`): the user action writes the
    /// attribution key and publishes, so the card jumps to the target bar at once without waiting for the
    /// next read. `.brief` freezes for `displayMoveHold` (the AX frame write is in flight on the action
    /// queue, and reads landing meanwhile still see the old position); `.untilVisible` pins it until it is
    /// next visible in AX (off-screen / phantom windows AX has no handle for: dragging = change of address);
    /// on write failure the caller rolls back with the old key and `.none` (the true value is corrected later
    /// by AX / CG reads). Registered seats only.
    static let displayMoveHold: TimeInterval = 1.5

    enum DisplayKeyHold { case none, brief, untilVisible }

    /// A "running but no windows" fallback card / running kept placeholder was dragged onto another display's
    /// bar: for every process of this bundle the "display its windows were last on" becomes that display and
    /// is published (a bundle has only one fallback card, so recording per bundle keeps it across pid
    /// changes).
    func noteNoWindowHome(bundleID: String, displayUUID: String) {
        guard !bundleID.isEmpty else { return }
        var changed = false
        var matched = 0
        for pid in appOrder where apps[pid]?.bundleIdentifier == bundleID {
            matched += 1
            guard apps[pid]?.lastWindowDisplayUUID != displayUUID else { continue }
            apps[pid]?.lastWindowDisplayUUID = displayUUID
            changed = true
        }
        if Self.displayTraceEnabled {
            displayTraceLogger.info("noteNoWindowHome bundle=\(bundleID, privacy: .public) to=\(displayUUID, privacy: .public) matchedPIDs=\(matched) changed=\(changed)")
        }
        if changed { rebuildSnapshot(onScreenCGIDs: lastOnScreenCGIDs) }
    }

    /// Verdict after the AX frame write of a cross-display drag fails: window on screen right now (a real
    /// window the user can see) -> roll back to the source display; not on screen (off-screen / phantom seat)
    /// -> nothing to move, pin it to the target display as a "change of address".
    enum FailedMoveVerdict: Equatable { case rolledBack, pinnedToTarget, seatGone }

    @discardableResult
    func resolveFailedWindowMove(pid: pid_t, cgWindowID: CGWindowID, target: String, previous: String?) -> FailedMoveVerdict {
        guard apps[pid]?.windowsByID[cgWindowID] != nil else { return .seatGone }
        if lastOnScreenCGIDs.contains(cgWindowID) {
            noteWindowMoved(pid: pid, cgWindowID: cgWindowID, displayUUID: previous, hold: .none)
            return .rolledBack
        }
        noteWindowMoved(pid: pid, cgWindowID: cgWindowID, displayUUID: target, hold: .untilVisible)
        return .pinnedToTarget
    }

    private static let displayTraceEnabled = DebugSwitch.displayTrace.isEnabled(in: ProcessInfo.processInfo.environment)
    private let displayTraceLogger = Logger(subsystem: "no.thilip.nitiadock", category: "display-trace")

    @discardableResult
    func noteWindowMoved(pid: pid_t, cgWindowID: CGWindowID, displayUUID: String?, hold: DisplayKeyHold = .brief) -> Bool {
        guard let seat = apps[pid]?.windowsByID[cgWindowID] else { return false }
        let holdUntil: Date?
        switch hold {
        case .none: holdUntil = nil
        case .brief: holdUntil = Date().addingTimeInterval(Self.displayMoveHold)
        case .untilVisible: holdUntil = .distantFuture
        }
        apps[pid]?.windowsByID[cgWindowID]?.displayUUIDHoldUntil = holdUntil
        if Self.displayTraceEnabled {
            displayTraceLogger.info("noteWindowMoved pid=\(pid) cg=\(cgWindowID) \(seat.displayUUID ?? "nil", privacy: .public) → \(displayUUID ?? "nil", privacy: .public) hold=\(String(describing: hold), privacy: .public)")
        }
        guard seat.displayUUID != displayUUID else { return true }
        apps[pid]?.windowsByID[cgWindowID]?.displayUUID = displayUUID
        rebuildSnapshot(onScreenCGIDs: lastOnScreenCGIDs)
        return true
    }

    // MARK: - Seed

    private func seedRunningApps() {
        let seedStart = Date()
        // Env var DOCK_SEED_AX_TIMEOUT_MS: 0 = fall back to the old read without timeout; other values
        // override the milliseconds; default 100ms.
        let timeoutMS = DebugSwitch.seedAxTimeoutMs.value(in: ProcessInfo.processInfo.environment)
        let useTimeout: Bool
        var messagingTimeout: TimeInterval = 0.1
        if let ms = timeoutMS, let val = Int(ms) {
            if val == 0 {
                useTimeout = false
            } else {
                useTimeout = true
                messagingTimeout = TimeInterval(val) / 1000.0
            }
        } else {
            useTimeout = true
        }

        var admittedCount = 0
        var unreadList: [String] = []
        let cgSnapshot = cgSnapshotProvider()

        for app in NSWorkspace.shared.runningApplications {
            guard isRegularNonSelf(app) else { continue }
            let pid = app.processIdentifier
            let bid = app.bundleIdentifier
            let eligibilityApplication = eligibilityApplication(for: app)
            let probeIdentity = inventoryLog.isEnabled ? processIdentity(pid: pid, bundleID: bid) : nil

            // Time-limited probe: a hung app times out on the first AX message -> .unread -> skipped, left to
            // the catch-up scan.
            let result: AXWindowReadResult
            if useTimeout {
                result = reader.inventoryWindows(forPID: pid, messagingTimeout: messagingTimeout)
            } else {
                // Keep legacy untimed/two-attempt behavior while preserving `.unread` for diagnostics.
                result = reader.windowReadResult(forPID: pid)
            }

            let probedEligible: [AXWindowSnapshot]
            let inventoryReadOutcome: InventoryAXReadOutcome
            switch result {
            case .success(let snaps):
                probedEligible = snaps.filter {
                    isEligible($0, application: eligibilityApplication, cgSnapshot: cgSnapshot)
                }
                inventoryReadOutcome = .success(count: snaps.count)
            case .unread(let error):
                probedEligible = []
                inventoryReadOutcome = .unread(errorCode: error.rawValue)
                unreadList.append(app.localizedName ?? bid ?? "\(pid)")
            }

            let seedVerdict: InventoryAdmissionProbeVerdict
            if FinderWindowRules.isFinder(bundleIdentifier: bid) {
                seedVerdict = .admitFinderPersistent
            } else if case .unread = result {
                seedVerdict = .skipUnread
            } else if probedEligible.isEmpty {
                seedVerdict = .skipNoEligible
            } else {
                seedVerdict = .admit
            }
            if let probeIdentity {
                recordAdmissionProbe(
                    source: .seed,
                    identity: probeIdentity,
                    readMode: useTimeout ? .timed : .untimed,
                    messagingTimeoutMs: useTimeout ? Int((messagingTimeout * 1_000).rounded()) : nil,
                    maxAttempts: useTimeout ? 1 : 2,
                    result: result,
                    eligibleWindowCount: result.isSuccess ? probedEligible.count : nil,
                    verdict: seedVerdict
                )
            }

            if FinderWindowRules.isFinder(bundleIdentifier: bid) {
                // Finder always holds its slot: on unread it is placed with no windows first (the slot is
                // permanent; notifications / reconcile fill it in later).
                addApp(app, enumerateImmediately: false)
                reconcileSeats(
                    pid: pid,
                    cgSnapshot: cgSnapshot,
                    now: Date(),
                    source: .seed,
                    preloadedEligible: probedEligible,
                    preloadedReadOutcome: inventoryReadOutcome,
                    preloadedReadMode: useTimeout ? .timed : .untimed
                )
                admittedCount += 1
                continue
            }

            if !probedEligible.isEmpty {
                addApp(app, enumerateImmediately: false)
                reconcileSeats(
                    pid: pid,
                    cgSnapshot: cgSnapshot,
                    now: Date(),
                    source: .seed,
                    preloadedEligible: probedEligible,
                    preloadedReadOutcome: inventoryReadOutcome,
                    preloadedReadMode: useTimeout ? .timed : .untimed
                )
                admittedCount += 1
            }
        }

        rebuildSnapshot(onScreenCGIDs: cgSnapshot.onScreenWindowIDs)

        let elapsed = Date().timeIntervalSince(seedStart)
        logger.info("seed done: \(admittedCount) admitted, \(unreadList.count) unread [\(unreadList.joined(separator: ", "))], elapsed=\(String(format: "%.2f", elapsed))s")
    }

    // MARK: - Workspace Notifications

    private func subscribeWorkspaceNotifications() {
        let nc = NSWorkspace.shared.notificationCenter

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in self?.handleAppLaunched(app) }
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in self?.handleAppTerminated(pid: pid) }
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in self?.handleAppHidden(pid: pid) }
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in self?.handleAppUnhidden(pid: pid) }
        })

        workspaceObservers.append(nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in
                // The frontmost cache applies to all activations (accessory apps and this app also take the
                // foreground); the regular filter in handleAppActivated only governs admission, not the
                // frontmost fact.
                self?.cachedFrontmostPID = pid
                self?.handleAppActivated(app)
            }
        })
    }

    // MARK: - Workspace Handlers

    private func handleAppLaunched(_ app: NSRunningApplication) {
        guard isRegularNonSelf(app) else { return }
        scanDirtyPIDs.insert(app.processIdentifier)
        scanCandidateCache = nil
        if FinderWindowRules.isFinder(bundleIdentifier: app.bundleIdentifier) {
            // Remove any stale Finder entry left over from a quit/relaunch cycle,
            // then add the fresh entry with the new pid.
            if let stalePID = appOrder.first(where: {
                FinderWindowRules.isFinder(bundleIdentifier: apps[$0]?.bundleIdentifier)
            }), stalePID != app.processIdentifier {
                observers[stalePID]?.stop()
                observers.removeValue(forKey: stalePID)
                apps.removeValue(forKey: stalePID)
                appOrder.removeAll { $0 == stalePID }
                clearInventoryDiagnostics(pid: stalePID)
                gateStates.removeValue(forKey: stalePID)
                invalidateEventReads(pid: stalePID)
                elementCache.removeAll(pid: stalePID)
            }
            addApp(app, enumerateImmediately: true)
            rebuildSnapshot()
            return
        }
        scheduleRetryAdmission(app: app, delays: [0.2, 0.5, 1.0, 2.0])
    }

    private func handleAppActivated(_ app: NSRunningApplication) {
        guard isRegularNonSelf(app) else { return }
        guard apps[app.processIdentifier] == nil else {
            markReconcileGateDirty(pid: app.processIdentifier)
            rebuildSnapshot()  // frontmost changed → active highlight update
            return
        }
        addApp(app, enumerateImmediately: true)
        rebuildSnapshot()
    }

    private func handleAppTerminated(pid: pid_t) {
        cgEventGeneration &+= 1
        invalidateEventReads(pid: pid)
        observers[pid]?.stop()
        observers.removeValue(forKey: pid)
        if let app = apps[pid] { recordProcessGoneSeats(app: app) }
        clearInventoryDiagnostics(pid: pid)
        gateStates.removeValue(forKey: pid)
        scanMemos.removeValue(forKey: pid)
        scanDirtyPIDs.remove(pid)
        scanCandidateCache = nil

        // Finder relaunches immediately via launchd. Keep the entry (no windows) so the chip
        // stays visible during the gap. handleAppLaunched will replace this stale entry with
        // the new pid when Finder comes back up.
        if FinderWindowRules.isFinder(bundleIdentifier: apps[pid]?.bundleIdentifier) {
            apps[pid]?.windowsByID = [:]
            apps[pid]?.windowOrder = []
            rebuildSnapshot()
            return
        }

        apps.removeValue(forKey: pid)
        appOrder.removeAll { $0 == pid }
        elementCache.removeAll(pid: pid)
        rebuildSnapshot()
    }

    private func handleAppHidden(pid: pid_t) {
        markReconcileGateDirty(pid: pid)
        apps[pid]?.isHidden = true
        rebuildSnapshot()
    }

    private func handleAppUnhidden(pid: pid_t) {
        markReconcileGateDirty(pid: pid)
        apps[pid]?.isHidden = false
        rebuildSnapshot()
    }

    // MARK: - App Management

    private func addApp(
        _ app: NSRunningApplication,
        enumerateImmediately: Bool,
        source: InventoryReconcileSource = .initialEnumeration
    ) {
        let pid = app.processIdentifier
        guard apps[pid] == nil else { return }
        cgEventGeneration &+= 1

        apps[pid] = AppEntry(
            pid: pid,
            bundleIdentifier: app.bundleIdentifier,
            appName: app.localizedName ?? app.bundleIdentifier ?? "\(pid)",
            activationPolicy: app.activationPolicy,
            executablePath: app.executableURL?.path,
            windowsByID: [:],
            windowOrder: [],
            isHidden: app.isHidden
        )
        appOrder.append(pid)
        mutationGenerations[pid, default: 0] &+= 1
        scanMemos.removeValue(forKey: pid)
        scanDirtyPIDs.remove(pid)
        scanCandidateCache = nil

        if AXIsProcessTrusted() {
            let obs = AppWindowObserver(pid: pid)
            obs.onWindowCreated = { [weak self] pid in self?.handleWindowCreated(pid: pid) }
            obs.onWindowDestroyed = { [weak self] pid, cgID in self?.handleWindowDestroyed(pid: pid, cgWindowID: cgID) }
            obs.onWindowMinimized = { [weak self] pid, cgID in self?.handleWindowMinimized(pid: pid, cgWindowID: cgID) }
            obs.onWindowDeminiaturized = { [weak self] pid, cgID in self?.handleWindowDeminiaturized(pid: pid, cgWindowID: cgID) }
            obs.onFocusedWindowChanged = { [weak self] pid in self?.handleFocusedWindowChanged(pid: pid) }
            obs.onTitleChanged = { [weak self] pid, cgID in self?.handleTitleChanged(pid: pid, cgWindowID: cgID) }
            obs.start()
            observers[pid] = obs
        }

        if enumerateImmediately {
            enumerateWindows(for: pid, source: source)
        }
    }

    private func scheduleRetryAdmission(app: NSRunningApplication, delays: [TimeInterval]) {
        let pid = app.processIdentifier
        for delay in delays {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self else { return }
                if self.apps[pid] != nil {
                    self.enumerateWindows(for: pid, source: .initialEnumeration)
                    return
                }
                guard NSRunningApplication(processIdentifier: pid)?.isTerminated == false else { return }
                let windows = self.mainActorWindowRead(forPID: pid).windowsOrEmpty
                let cgSnapshot = self.cgSnapshotProvider()
                let eligibilityApplication = self.eligibilityApplication(for: app)
                let hasEligible = windows.contains {
                    self.isEligible($0, application: eligibilityApplication, cgSnapshot: cgSnapshot)
                }
                if hasEligible {
                    self.addApp(app, enumerateImmediately: true)
                    self.rebuildSnapshot()
                }
            }
        }
    }

    // MARK: - Window Enumeration

    /// Timeout for the few AX reads that still run on the main actor (admitting an app on
    /// activation or launch). An app that is launching or beachballing cannot answer AX; without
    /// a timeout each read blocks the bar for the system default (~6 s, twice). A timed-out read
    /// is `.unread`, which is "unknown", and the launch retries and polls pick the app up later.
    static let mainActorAXTimeout: TimeInterval = 0.25

    /// The synchronous read for main-actor callers. Only the two compatibility switches
    /// (`DOCK_EVENT_AX_ASYNC=0`, `DOCK_RECONCILE_AX_TIMEOUT_MS=0`) keep the old untimed read.
    private func mainActorWindowRead(forPID pid: pid_t) -> AXWindowReadResult {
        guard eventAXAsyncEnabled, periodicReconcileTimeout != nil else {
            return reader.windowReadResult(forPID: pid)
        }
        return reader.inventoryWindows(forPID: pid, messagingTimeout: Self.mainActorAXTimeout)
    }

    /// AX against our own process is answered in-process on the calling thread, so a background
    /// read of our own windows (the Settings card) would run AppKit accessibility code off the main
    /// thread. Those reads run on the main actor instead; they never leave the process, so they
    /// cannot block on another app.
    nonisolated private static func inventoryRead(
        _ reader: AppTrackerWindowReading, pid: pid_t, messagingTimeout: TimeInterval
    ) async -> AXWindowReadResult {
        guard pid == ProcessInfo.processInfo.processIdentifier else {
            return reader.inventoryWindows(forPID: pid, messagingTimeout: messagingTimeout)
        }
        return await MainActor.run { reader.inventoryWindows(forPID: pid, messagingTimeout: messagingTimeout) }
    }

    private func enumerateWindows(for pid: pid_t, source: InventoryReconcileSource) {
        guard apps[pid] != nil else { return }
        let cgSnapshot = cgSnapshotProvider()
        if reconcileSeats(pid: pid, cgSnapshot: cgSnapshot, now: Date(), source: source) {
            rebuildSnapshot(onScreenCGIDs: cgSnapshot.onScreenWindowIDs)
        }
    }

    private func isEligible(
        _ snap: AXWindowSnapshot,
        application: AppTrackerWindowEligibility.Application,
        cgSnapshot: AppTrackerCGWindowSnapshot
    ) -> Bool {
        let alpha = snap.cgWindowID.flatMap { cgSnapshot.alphaByWindowID[$0] }
        return windowEligibility.isEligible(
            title: snap.title,
            role: snap.role,
            subrole: snap.subrole,
            bounds: snap.bounds,
            alpha: alpha,
            isMinimized: snap.isMinimized,
            application: application
        )
    }

    private func eligibilityApplication(for app: AppEntry) -> AppTrackerWindowEligibility.Application {
        AppTrackerWindowEligibility.Application(
            bundleIdentifier: app.bundleIdentifier,
            appName: app.appName,
            activationPolicy: app.activationPolicy,
            executablePath: app.executablePath
        )
    }

    private func eligibilityApplication(for app: NSRunningApplication) -> AppTrackerWindowEligibility.Application {
        AppTrackerWindowEligibility.Application(
            bundleIdentifier: app.bundleIdentifier,
            appName: app.localizedName ?? app.bundleIdentifier ?? "\(app.processIdentifier)",
            activationPolicy: app.activationPolicy,
            executablePath: app.executableURL?.path
        )
    }

    // MARK: - AX Event Handlers

    private func handleWindowCreated(pid: pid_t) {
        markReconcileGateDirty(pid: pid)
        scheduleEventRead(pid: pid, source: .windowCreated)
    }

    private func handleWindowDestroyed(pid: pid_t, cgWindowID: CGWindowID) {
        guard apps[pid] != nil else { return }
        markReconcileGateDirty(pid: pid)
        invalidateEventReads(pid: pid)
        destroyedCGIDs[cgWindowID] = Date()
        purgeFromSeatHistories(cgWindowID)
        // The element cache entry is removed only on a real close. The destroy notification may precede the
        // full CG list update, so it is removed explicitly here instead of waiting for the CG intersection in
        // reconcileSeats below.
        elementCache.remove(pid: pid, cgWindowID: cgWindowID)
        // The seat is not removed directly: if this is the current tab of a tabbed window being closed while
        // the same physical window has another tab to take over, reconcileSeats swaps the seat's activeCgID
        // in place and keeps the token (the card neither flashes nor changes identity). Closing the whole
        // window really removes it. The reconcile uses the time-limited background event read (as for created
        // / focus / title). This used to call `reconcileSeats` directly on the main actor with an unlimited
        // read; if the app of the closing window was stuck, the taskbar main thread froze for up to ~12s.
        scheduleEventRead(pid: pid, source: .windowDestroyed)
    }

    private func handleWindowMinimized(pid: pid_t, cgWindowID: CGWindowID) {
        markReconcileGateDirty(pid: pid)
        invalidateEventReads(pid: pid)
        apps[pid]?.windowsByID[cgWindowID]?.isMinimized = true
        apps[pid]?.windowsByID[cgWindowID]?.isFocused = false
        rebuildSnapshot()
    }

    private func handleWindowDeminiaturized(pid: pid_t, cgWindowID: CGWindowID) {
        markReconcileGateDirty(pid: pid)
        invalidateEventReads(pid: pid)
        apps[pid]?.windowsByID[cgWindowID]?.isMinimized = false
        rebuildSnapshot()
    }

    private func handleFocusedWindowChanged(pid: pid_t) {
        markReconcileGateDirty(pid: pid)
        scheduleEventRead(pid: pid, source: .focusChanged)
    }

    private func handleTitleChanged(pid: pid_t, cgWindowID: CGWindowID) {
        markReconcileGateDirty(pid: pid)
        scheduleEventRead(pid: pid, source: .titleChanged)
    }

    private func markReconcileGateDirty(pid: pid_t) {
        gateStates[pid]?.dirty = true
        cgEventGeneration &+= 1
    }

    private func invalidateEventReads(pid: pid_t) {
        mutationGenerations[pid, default: 0] &+= 1
        trailingEventSources.removeValue(forKey: pid)
    }

    private func scheduleEventRead(pid: pid_t, source: InventoryReconcileSource) {
        guard apps[pid] != nil else { return }
        guard eventAXAsyncEnabled else {
            enumerateWindows(for: pid, source: source)
            return
        }
        if pendingEventReads[pid] != nil {
            // Coalesce any burst while a read is in flight into exactly one read using the latest
            // event source. Completion consumes and clears this slot before starting it.
            trailingEventSources[pid] = source
            return
        }

        nextEventReadToken &+= 1
        let request = PendingEventRead(
            token: nextEventReadToken,
            mutationGeneration: mutationGenerations[pid, default: 0],
            identity: processIdentity(pid: pid, bundleID: apps[pid]?.bundleIdentifier),
            source: source
        )
        pendingEventReads[pid] = request
        let reader = self.reader
        let cgSnapshotProvider = self.cgSnapshotProvider
        let probeProvider = self.onScreenWindowIDsProvider
        let ticket = makeCGSnapshotReuseTicket(pid: pid)

        Task.detached { [weak self] in
            let result = await Self.inventoryRead(reader, pid: pid, messagingTimeout: 0.1)
            // Hard ordering rule: probe first, full capture second (see the header comment of
            // CGSnapshotReuseDecision).
            let acquisition: CGSnapshotAcquisition
            switch CGSnapshotReuseDecision.preVerdict(ticket.input) {
            case .captureWithoutProbe:
                acquisition = CGSnapshotAcquisition(
                    snapshot: cgSnapshotProvider(), probeIDs: nil, fresh: true, ticket: ticket
                )
            case .captureAndPrime:
                let probe = probeProvider()
                acquisition = CGSnapshotAcquisition(
                    snapshot: cgSnapshotProvider(), probeIDs: probe, fresh: true, ticket: ticket
                )
            case .probeThenCompare:
                let probe = probeProvider()
                switch CGSnapshotReuseDecision.probeVerdict(
                    probe: probe, cachedProbe: ticket.cachedProbeIDs ?? []
                ) {
                case .reuse:
                    acquisition = CGSnapshotAcquisition(
                        // preVerdict already guarantees hasCache; the defensive fallback captures fresh.
                        snapshot: ticket.cachedSnapshot ?? cgSnapshotProvider(),
                        probeIDs: probe, fresh: false, ticket: ticket
                    )
                case .captureAndPrime:
                    acquisition = CGSnapshotAcquisition(
                        snapshot: cgSnapshotProvider(), probeIDs: probe, fresh: true, ticket: ticket
                    )
                }
            }
            await MainActor.run { [weak self] in
                self?.noteCGSnapshotAcquisition(acquisition)
                self?.completeEventRead(
                    pid: pid,
                    request: request,
                    result: result,
                    cgSnapshot: acquisition.snapshot
                )
            }
        }
    }

    /// Source of the CG list a background event read brings back: fresh capture (with the same round's probe,
    /// used to link the cache) or reused cache.
    private struct CGSnapshotAcquisition: Sendable {
        let snapshot: AppTrackerCGWindowSnapshot
        let probeIDs: Set<CGWindowID>?
        let fresh: Bool
        let ticket: CGSnapshotReuseTicket
    }

    /// Ticket assembly on the main thread: the static criteria are fixed here (age is computed at assembly
    /// time; the background read's duration margin is already in `defaultMaxCacheAge`). The cached snapshot /
    /// probe set travel with the ticket, and the background task never reads main-thread state again.
    private struct CGSnapshotReuseTicket: Sendable {
        let input: CGSnapshotReuseDecision.Input
        let cachedSnapshot: AppTrackerCGWindowSnapshot?
        let cachedProbeIDs: Set<CGWindowID>?
        let uptime: TimeInterval
        let generation: UInt64
    }

    private func makeCGSnapshotReuseTicket(pid: pid_t) -> CGSnapshotReuseTicket {
        let now = uptimeProvider()
        let app = apps[pid]
        let input = CGSnapshotReuseDecision.Input(
            reuseEnabled: cgSnapshotReuseEnabled,
            hasCache: cachedCGSnapshot != nil && cachedCGProbeIDs != nil,
            cachedCaptureFailed: cachedCGSnapshot?.captureFailed ?? true,
            cacheAge: now - cachedCGAtUptime,
            generationMatches: cachedCGGeneration == cgEventGeneration,
            hasAbsenceClock: app?.windowOrder.contains {
                app?.windowsByID[$0]?.minAbsentSince != nil
            } ?? false,
            hasPhantomCandidate: app?.windowOrder.contains {
                app?.windowsByID[$0]?.everSeenVisible == false
            } ?? false,
            observerActive: observerActive(pid: pid)
        )
        return CGSnapshotReuseTicket(
            input: input,
            cachedSnapshot: cachedCGSnapshot,
            cachedProbeIDs: cachedCGProbeIDs,
            uptime: now,
            generation: cgEventGeneration
        )
    }

    /// Only a **fresh capture** refreshes the cache (a reuse round does not, or the age cap would be void).
    /// Out-of-order landings are blocked by the ticket assembly time: an old ticket's fresh capture does not
    /// overwrite a newer cache. The generation recorded is the value at assembly time: an event in between
    /// leaves the cache generation behind -> fresh capture next round, conservative.
    private func noteCGSnapshotAcquisition(_ acquisition: CGSnapshotAcquisition) {
        guard cgSnapshotReuseEnabled, acquisition.fresh,
              let probe = acquisition.probeIDs,
              acquisition.ticket.uptime >= cachedCGAtUptime else { return }
        cachedCGSnapshot = acquisition.snapshot
        cachedCGProbeIDs = probe
        cachedCGAtUptime = acquisition.ticket.uptime
        cachedCGGeneration = acquisition.ticket.generation
    }

    private enum EventReadLanding {
        case staleToken                  // token was invalidated / replaced: the whole landing is void (trailing is handled by the new in-flight read)
        case skipped                     // token matched and was consumed, but generation / process identity mismatch -> no state touched
        case reconciled(seatsChanged: Bool)
    }

    /// Shared core for landing one time-limited background read: validates and consumes the pending token,
    /// then after the mutation generation and process identity checks runs reconcileSeats. Does **not**
    /// rebuild the snapshot and does **not** consume trailing: the single-shot path (event / frontmost poll)
    /// adds the on-screen forced refresh, the batch path (periodic reconcile) rebuilds once per batch, and
    /// each finishes up outside.
    private func landEventRead(
        pid: pid_t,
        request: PendingEventRead,
        result: AXWindowReadResult,
        cgSnapshot: AppTrackerCGWindowSnapshot
    ) -> EventReadLanding {
        guard pendingEventReads[pid]?.token == request.token else { return .staleToken }
        pendingEventReads.removeValue(forKey: pid)

        let currentIdentity = apps[pid].map {
            processIdentity(pid: pid, bundleID: $0.bundleIdentifier)
        }
        guard mutationGenerations[pid, default: 0] == request.mutationGeneration,
              currentIdentity.map({
                  ScanAdmissionDecision.ProcessIdentity.matches(probed: request.identity, current: $0)
              }) == true,
              let app = apps[pid] else { return .skipped }

        let readOutcome: InventoryAXReadOutcome
        let eligible: [AXWindowSnapshot]
        switch result {
        case .success(let windows):
            readOutcome = .success(count: windows.count)
            let application = eligibilityApplication(for: app)
            eligible = windows.filter {
                isEligible($0, application: application, cgSnapshot: cgSnapshot)
            }
        case .unread(let error):
            readOutcome = .unread(errorCode: error.rawValue)
            eligible = []
        }
        let seatsChanged = reconcileSeats(
            pid: pid,
            cgSnapshot: cgSnapshot,
            now: Date(),
            source: request.source,
            preloadedEligible: eligible,
            preloadedReadOutcome: readOutcome,
            preloadedReadMode: .timed
        )
        return .reconciled(seatsChanged: seatsChanged)
    }

    private func completeEventRead(
        pid: pid_t,
        request: PendingEventRead,
        result: AXWindowReadResult,
        cgSnapshot: AppTrackerCGWindowSnapshot
    ) {
        switch landEventRead(pid: pid, request: request, result: result, cgSnapshot: cgSnapshot) {
        case .staleToken:
            return
        case .skipped:
            break
        case .reconciled(let seatsChanged):
            let onScreenChanged = request.source == .frontmostPoll
                && cgSnapshot.onScreenWindowIDs != lastOnScreenCGIDs
            if seatsChanged || onScreenChanged {
                rebuildSnapshot(onScreenCGIDs: cgSnapshot.onScreenWindowIDs)
            }
        }
        consumeTrailingEventRead(pid: pid)
    }

    private func consumeTrailingEventRead(pid: pid_t) {
        if let trailingSource = trailingEventSources.removeValue(forKey: pid), apps[pid] != nil {
            scheduleEventRead(pid: pid, source: trailingSource)
        }
    }

    // MARK: - Reconcile

    private func startReconcileTimer() {
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
        reconcileTimer?.tolerance = 0.5
    }

    // Fast frontmost poll: on a tab switch in a native tab group (e.g. Ghostty) AX may report nothing at all,
    // and the min flag is wrong for seconds. The truth is the CG on-screen set, which changes at once on a
    // tab switch. The frontmost app is checked every 0.5s: if the on-screen set changed (a tab switch),
    // rebuild, and the tab group's visible tab updates with it at once. AX title / focus are filled in along
    // the way. When the frontmost app is untracked the whole tick exits (an unattended measurement can thus
    // go inactive for its whole duration: every arm must record and fix the frontmost app). On quiet ticks
    // the full CG list is reused under the CGSnapshotReuseDecision gate; AX reads run as usual.
    private func startFrontmostPollTimer() {
        frontmostPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollFrontmostApp() }
        }
        frontmostPollTimer?.tolerance = 0.05
    }

    private func currentFrontmostPID() -> pid_t? {
        guard frontmostCacheEnabled else {
            return NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        if let cached = cachedFrontmostPID { return cached }
        let live = NSWorkspace.shared.frontmostApplication?.processIdentifier
        cachedFrontmostPID = live
        return live
    }

    /// Self-heal by a real query every 5s (called from the reconcile tick). When live is nil (transiently no
    /// frontmost app) the old value is kept.
    private func refreshFrontmostCache() {
        guard frontmostCacheEnabled else { return }
        if let live = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            cachedFrontmostPID = live
        }
    }

    private func pollFrontmostApp() {
        guard AXIsProcessTrusted() else { return }
        guard let pid = currentFrontmostPID(), apps[pid] != nil else { return }

        scheduleFrontmostPoll(pid: pid)
    }

    private func scheduleFrontmostPoll(pid: pid_t) {
        guard apps[pid] != nil else { return }

        // Keep the 0.5s cadence, but never perform the full AXWindows read on the main actor.
        // Slow frontmost apps previously blocked SwiftUI animation for 200-400ms every tick.
        if eventAXAsyncEnabled {
            scheduleEventRead(pid: pid, source: .frontmostPoll)
            return
        }

        // In the single-seat model a tab switch in a tabbed window = the seat's activeCgID is replaced, and
        // reconcileSeats converges at once. It runs every 0.5s for the frontmost app, so tab switch /
        // minimize / tear-out show within a second (no longer relying on AX event reliability).
        let cgSnapshot = cgSnapshotProvider()
        var changed = reconcileSeats(pid: pid, cgSnapshot: cgSnapshot, now: Date(), source: .frontmostPoll)
        // A changed on-screen set (tab switch) also forces one refresh, covering the corner case where the
        // seat fingerprint is unchanged but the visible tab changed.
        let onScreen = cgSnapshot.onScreenWindowIDs
        if onScreen != lastOnScreenCGIDs { changed = true }
        if changed { rebuildSnapshot(onScreenCGIDs: onScreen) }
    }

    private func reconcile() {
        guard AXIsProcessTrusted() else { return }
        purgeStaleTombstones()
        refreshFrontmostCache()
        let now = Date()
        var changed = false

        // Remove entries for processes that no longer exist. This handles multi-process apps where
        // didTerminateApplicationNotification fires for the host pid while the window was tracked
        // under a different pid: the workspace notification removes the wrong entry and the
        // tracked pid's app entry stays indefinitely.
        var deadPIDs: [pid_t] = []
        for pid in appOrder {
            if !processProvider.isAlive(pid: pid) {
                // Finder's entry is intentionally kept alive across quit/relaunch cycles
                // (handleAppTerminated clears windows but preserves the slot).
                if FinderWindowRules.isFinder(bundleIdentifier: apps[pid]?.bundleIdentifier) { continue }
                deadPIDs.append(pid)
                logger.info("reconcile: pid=\(pid) no longer exists (POSIX kill(0) == ESRCH), removing stale entry")
            }
        }
        for pid in deadPIDs {
            // Before batch-deleting AppEntry, write one seatReleased(.processGone) per seat in windowOrder.
            // This path has no AX / CG sample for this round and no InventoryReconcileContext, only the seat
            // state already in memory; never fake unsampled fields as 0 / false. The log identity is the
            // stable pid + seatToken.
            if let app = apps[pid] { recordProcessGoneSeats(app: app) }
            observers[pid]?.stop()
            observers.removeValue(forKey: pid)
            apps.removeValue(forKey: pid)
            appOrder.removeAll { $0 == pid }
            clearInventoryDiagnostics(pid: pid)
            gateStates.removeValue(forKey: pid)
            invalidateEventReads(pid: pid)
            elementCache.removeAll(pid: pid)
            changed = true
        }

        // Snapshot CG window state once for the entire reconcile pass.
        let cgSnapshot = cgSnapshotProvider()
        // Multi-display ④: all visible seats switch display by this round's CG bounds (skipped pids are
        // covered too).
        if !cgSnapshot.captureFailed, refreshDisplayAttributionFromCG(cgSnapshot) { changed = true }

        if let timeout = periodicReconcileTimeout, eventAXAsyncEnabled {
            // Removals from the dead-process sweep go on screen at once, without waiting for the batch read
            // to land.
            if changed { rebuildSnapshot(onScreenCGIDs: cgSnapshot.onScreenWindowIDs) }
            schedulePeriodicBatchRead(cgSnapshot: cgSnapshot, timeout: timeout)
        } else {
            // Old path (DOCK_RECONCILE_AX_TIMEOUT_MS=0 or DOCK_EVENT_AX_ASYNC=0): unlimited synchronous
            // per-pid reads on the main thread.
            for pid in appOrder {
                if reconcileSeats(pid: pid, cgSnapshot: cgSnapshot, now: now, source: .periodicReconcile) { changed = true }
            }
            if changed { rebuildSnapshot(onScreenCGIDs: cgSnapshot.onScreenWindowIDs) }
        }
        scanNonAdmittedApps(cgSnapshot: cgSnapshot)
    }

    /// Batched background read of the periodic reconcile: pids with a read already in flight are skipped (its
    /// landing brings fresh data), the rest register pending tokens as a batch and are read serially with
    /// time limits in **one** detached task; the whole batch lands once and rebuilds at most once. AX events
    /// arriving while the batch read is in flight merge into trailing as usual (one in-flight read per pid,
    /// unchanged); on the next tick pids that have not landed yet are skipped because pending exists, so
    /// nothing piles up.
    private func schedulePeriodicBatchRead(cgSnapshot: AppTrackerCGWindowSnapshot, timeout: TimeInterval) {
        var batch: [(pid: pid_t, request: PendingEventRead)] = []
        for pid in appOrder {
            guard pendingEventReads[pid] == nil, let app = apps[pid] else { continue }
            if reconcileSkipEnabled, shouldSkipPeriodicRead(pid: pid, app: app, cgSnapshot: cgSnapshot) {
                continue
            }
            nextEventReadToken &+= 1
            let request = PendingEventRead(
                token: nextEventReadToken,
                mutationGeneration: mutationGenerations[pid, default: 0],
                identity: processIdentity(pid: pid, bundleID: app.bundleIdentifier),
                source: .periodicReconcile
            )
            pendingEventReads[pid] = request
            batch.append((pid, request))
        }
        guard !batch.isEmpty else { return }
        let reader = self.reader

        Task.detached { [weak self] in
            var results: [(pid: pid_t, request: PendingEventRead, result: AXWindowReadResult)] = []
            for entry in batch {
                results.append((
                    entry.pid,
                    entry.request,
                    await Self.inventoryRead(reader, pid: entry.pid, messagingTimeout: timeout)
                ))
            }
            let landed = results
            await MainActor.run { [weak self] in
                self?.completePeriodicBatch(landed, cgSnapshot: cgSnapshot)
            }
        }
    }

    /// Silent skip decision (pure decision: PeriodicReconcileSkipDecision, skips only when all eight
    /// conditions pass). Skip = no AX read is scheduled for this pid this round; all state stays unadvanced
    /// (same semantics as `.unread`).
    private func shouldSkipPeriodicRead(
        pid: pid_t,
        app: AppEntry,
        cgSnapshot: AppTrackerCGWindowSnapshot
    ) -> Bool {
        let gate = gateStates[pid]
        let input = PeriodicReconcileSkipDecision.Input(
            captureFailed: cgSnapshot.captureFailed,
            currentCGIDs: cgSnapshot.windowIDsByPID[pid] ?? [],
            lastObservedCGIDs: gate?.lastCGIDs,
            dirtySinceLastRead: gate?.dirty ?? true,
            hasAbsenceClock: app.windowOrder.contains { app.windowsByID[$0]?.minAbsentSince != nil },
            hasPhantomCandidate: app.windowOrder.contains { app.windowsByID[$0]?.everSeenVisible == false },
            lastReadWasUnread: gate?.lastReadWasUnread ?? true,
            lastRoundChanged: gate?.lastRoundChanged ?? true,
            observerActive: observerActive(pid: pid),
            uptimeSinceLastFullRead: gate.map { uptimeProvider() - $0.lastFullReadUptime } ?? .infinity
        )
        return PeriodicReconcileSkipDecision.verdict(input) == .skip
    }

    private func observerActive(pid: pid_t) -> Bool {
        #if DEBUG
        if let override = observerActiveOverridesForTesting[pid] { return override }
        #endif
        return observers[pid]?.isActive ?? false
    }

    private func completePeriodicBatch(
        _ results: [(pid: pid_t, request: PendingEventRead, result: AXWindowReadResult)],
        cgSnapshot: AppTrackerCGWindowSnapshot
    ) {
        var changed = false
        var landedPIDs: [pid_t] = []
        for entry in results {
            switch landEventRead(pid: entry.pid, request: entry.request, result: entry.result, cgSnapshot: cgSnapshot) {
            case .staleToken:
                continue
            case .skipped:
                landedPIDs.append(entry.pid)
            case .reconciled(let seatsChanged):
                if seatsChanged { changed = true }
                landedPIDs.append(entry.pid)
            }
        }
        if changed { rebuildSnapshot(onScreenCGIDs: cgSnapshot.onScreenWindowIDs) }
        for pid in landedPIDs { consumeTrailingEventRead(pid: pid) }
    }

    /// `cgSnapshot`: the reconcile tick passes this round's CG capture in -> the probe gate applies (CG
    /// presence criterion + memo) and the capture is reused for admission; nil (the four catch-up rounds
    /// after launch) -> gate and memo are bypassed entirely and admission captures its own snapshot,
    /// bit-for-bit as before the change.
    private func scanNonAdmittedApps(cgSnapshot: AppTrackerCGWindowSnapshot? = nil) {
        guard !isScanningCandidates else { return }
        var slowFullScanDue = false
        if cgSnapshot != nil, scanGateEnabled {
            let uptime = uptimeProvider()
            slowFullScanDue = lastFullScanUptime.map {
                uptime - $0 >= ScanProbeGateDecision.defaultFullScanInterval
            } ?? true
            if slowFullScanDue { lastFullScanUptime = uptime }
        }
        // Candidates travel with **the process generation at probe time**: the pid may be reused during the
        // background probe, and the callback must be able to detect the swap.
        let candidates: [(pid: pid_t, identity: ScanAdmissionDecision.ProcessIdentity)]
        if let cgSnapshot, scanGateEnabled {
            // Gated path: the candidate list comes from the cache (see the scanCandidateCache comment);
            // NSWorkspace is re-enumerated only on invalidation or when the slow scan is due. Stale cache
            // entries (already admitted / dead) are filtered out cheaply every tick.
            if scanCandidateCache == nil || slowFullScanDue {
                scanCandidateCache = enumerateScanCandidates()
            }
            candidates = (scanCandidateCache ?? []).compactMap { entry in
                guard apps[entry.pid] == nil, processProvider.isAlive(pid: entry.pid) else { return nil }
                let identity = processIdentity(pid: entry.pid, bundleID: entry.bundleID)
                let verdict = ScanProbeGateDecision.verdict(.init(
                    captureFailed: cgSnapshot.captureFailed,
                    cgWindowIDs: cgSnapshot.windowIDsByPID[entry.pid] ?? [],
                    memo: scanMemos[entry.pid],
                    currentIdentity: identity,
                    workspaceDirty: scanDirtyPIDs.contains(entry.pid),
                    slowFullScanDue: slowFullScanDue
                ))
                guard case .probe = verdict else { return nil }
                scanDirtyPIDs.remove(entry.pid)
                return (entry.pid, identity)
            }
        } else {
            // Bypass (launch catch-up rounds / DOCK_SCAN_GATE=0): bit-for-bit as before the change, full live
            // enumeration.
            candidates = NSWorkspace.shared.runningApplications.compactMap { app in
                let pid = app.processIdentifier
                guard isRegularNonSelf(app), !app.isTerminated, apps[pid] == nil else { return nil }
                scanDirtyPIDs.remove(pid)
                return (pid, processIdentity(pid: pid, bundleID: app.bundleIdentifier))
            }
        }
        guard !candidates.isEmpty else { return }

        isScanningCandidates = true
        let reader = self.reader

        Task.detached { [weak self] in
            // The background does AX reads only (100ms limit, a hung app does not stall the main thread). The
            // eligible filter stays on the main thread: it depends on the instance property eligibilityPolicy
            // and is pure computation over fields already read, with zero AX round trips.
            let probeStart = DispatchTime.now().uptimeNanoseconds
            var probed: [(pid: pid_t, identity: ScanAdmissionDecision.ProcessIdentity, result: AXWindowReadResult)] = []
            for candidate in candidates {
                probed.append((
                    candidate.pid,
                    candidate.identity,
                    reader.inventoryWindows(forPID: candidate.pid, messagingTimeout: 0.1)
                ))
            }
            let results = probed
            let probeElapsed = TimeInterval(DispatchTime.now().uptimeNanoseconds - probeStart) / 1_000_000_000

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isScanningCandidates = false
                self.admitScannedApps(results, tickSnapshot: cgSnapshot, probeElapsed: probeElapsed)
            }
        }
    }

    /// One real NSWorkspace enumeration (each per-app property access is a synchronous LS XPC; do not call it
    /// on quiet ticks).
    private func enumerateScanCandidates() -> [(pid: pid_t, bundleID: String?)] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            let pid = app.processIdentifier
            guard isRegularNonSelf(app), !app.isTerminated, apps[pid] == nil else { return nil }
            return (pid, app.bundleIdentifier)
        }
    }

    /// Catch-up scan admission. Three hard rules (all locked by unit tests in `ScanAdmissionDecision`):
    /// admission looks at the set **after the eligible filter** (a non-empty raw AX list ≠ a window that
    /// belongs on the taskbar; a wrong admission leaves a permanent `app-*` card); the probe result **must be
    /// reused** (no second AX read without a timeout, which is exactly the main-thread blocking the 100ms
    /// probe avoids); process state and generation are **re-checked** in the main-thread callback (the pid
    /// may have been reused).
    private func admitScannedApps(
        _ probed: [(pid: pid_t, identity: ScanAdmissionDecision.ProcessIdentity, result: AXWindowReadResult)],
        tickSnapshot: AppTrackerCGWindowSnapshot? = nil,
        probeElapsed: TimeInterval = .infinity
    ) {
        guard !probed.isEmpty else { return }
        // Reuse the reconcile tick's CG capture (saves a second full list every 5 seconds). If the probe took
        // too long (>1s, hung apps queued on timeouts) or no snapshot came along (launch catch-up rounds),
        // capture one now; the generation re-check (ScanAdmissionDecision.verdict) still covers correctness
        // against a "momentarily stale snapshot". Probing and admitting on the same snapshot, as seed does,
        // is an existing precedent.
        let cgSnapshot: AppTrackerCGWindowSnapshot
        if let tickSnapshot, probeElapsed <= 1.0 {
            cgSnapshot = tickSnapshot
        } else {
            cgSnapshot = cgSnapshotProvider()
        }
        var admitted = false

        for entry in probed {
            guard let app = NSRunningApplication(processIdentifier: entry.pid) else {
                scanMemos.removeValue(forKey: entry.pid)
                recordAdmissionProbe(
                    source: .scan,
                    identity: entry.identity,
                    readMode: .timed,
                    messagingTimeoutMs: 100,
                    maxAttempts: 1,
                    result: entry.result,
                    eligibleWindowCount: nil,
                    verdict: .skipProcessUnavailable
                )
                continue
            }
            let bundleID = app.bundleIdentifier
            let eligibilityApplication = eligibilityApplication(for: app)

            let rawWindows: [AXWindowSnapshot]?
            let readOutcome: InventoryAXReadOutcome
            switch entry.result {
            case .success(let snaps):
                rawWindows = snaps
                readOutcome = .success(count: snaps.count)
            case .unread(let error):
                rawWindows = nil
                readOutcome = .unread(errorCode: error.rawValue)
            }

            let prepared = ScanAdmissionDecision.prepare(rawWindows: rawWindows) {
                isEligible($0, application: eligibilityApplication, cgSnapshot: cgSnapshot)
            }
            let verdict = ScanAdmissionDecision.verdict(
                prepared,
                probedIdentity: entry.identity,
                currentIdentity: processIdentity(pid: entry.pid, bundleID: bundleID),
                isRegularNonSelf: isRegularNonSelf(app),
                isTerminated: app.isTerminated,
                alreadyTracked: apps[entry.pid] != nil
            )
            recordAdmissionProbe(
                source: .scan,
                identity: entry.identity,
                readMode: .timed,
                messagingTimeoutMs: 100,
                maxAttempts: 1,
                result: entry.result,
                eligibleWindowCount: prepared.readFailed ? nil : prepared.eligible.count,
                verdict: inventoryAdmissionVerdict(verdict)
            )
            // The memo records only "confirmed no eligible window" conclusions (.unread is never memoized, so
            // hung apps keep their 5s retry); any other conclusion clears the old memo.
            if verdict == .skipNoEligible {
                scanMemos[entry.pid] = ScanProbeGateDecision.Memo(
                    identity: entry.identity,
                    lastCGIDs: cgSnapshot.windowIDsByPID[entry.pid] ?? [],
                    verdictWasNoEligible: true
                )
            } else {
                scanMemos.removeValue(forKey: entry.pid)
            }
            guard verdict == .admit else { continue }

            admit(app: app, prepared: prepared, readOutcome: readOutcome, cgSnapshot: cgSnapshot)
            admitted = true
        }

        if admitted { rebuildSnapshot(onScreenCGIDs: cgSnapshot.onScreenWindowIDs) }
    }

    /// Lands one catch-up scan admission. Accepts only `Prepared`: the raw AX list never enters this scope,
    /// which rules out by scope feeding an unfiltered array to `reconcileSeats`.
    private func admit(
        app: NSRunningApplication,
        prepared: ScanAdmissionDecision.Prepared<AXWindowSnapshot>,
        readOutcome: InventoryAXReadOutcome,
        cgSnapshot: AppTrackerCGWindowSnapshot
    ) {
        let pid = app.processIdentifier
        addApp(app, enumerateImmediately: false)
        reconcileSeats(
            pid: pid,
            cgSnapshot: cgSnapshot,
            now: Date(),
            source: .initialEnumeration,
            preloadedEligible: prepared.eligible,
            preloadedReadOutcome: readOutcome,
            preloadedReadMode: .timed
        )
        logger.info("scan: admitted pid=\(pid) (\(app.localizedName ?? app.bundleIdentifier ?? "?"))")
    }

    private func processIdentity(pid: pid_t, bundleID: String?) -> ScanAdmissionDecision.ProcessIdentity {
        processProvider.identity(pid: pid, bundleID: bundleID)
    }

    private func recordAdmissionProbe(
        source: InventoryAdmissionProbeSource,
        identity: ScanAdmissionDecision.ProcessIdentity,
        readMode: InventoryAdmissionReadMode,
        messagingTimeoutMs: Int?,
        maxAttempts: Int,
        result: AXWindowReadResult,
        eligibleWindowCount: Int?,
        verdict: InventoryAdmissionProbeVerdict
    ) {
        guard inventoryLog.isEnabled else { return }
        let readResult: InventoryAdmissionProbeReadResult
        let errorCode: Int32?
        let rawWindowCount: Int?
        switch result {
        case .success(let windows):
            readResult = .success
            errorCode = nil
            rawWindowCount = windows.count
        case .unread(let error):
            readResult = .unread
            errorCode = error.rawValue
            rawWindowCount = nil
        }
        inventoryLog.record(.admissionProbe(InventoryAdmissionProbePayload(
            source: source,
            pid: identity.pid,
            bundleID: identity.bundleID,
            processStartTimeSec: identity.startTimeSec,
            processStartTimeUsec: identity.startTimeUsec,
            readMode: readMode,
            messagingTimeoutMs: messagingTimeoutMs,
            maxAttempts: maxAttempts,
            readResult: readResult,
            errorCode: errorCode,
            rawWindowCount: rawWindowCount,
            eligibleWindowCount: eligibleWindowCount,
            verdict: verdict
        )))
    }

    private func inventoryAdmissionVerdict(
        _ verdict: ScanAdmissionDecision.Verdict
    ) -> InventoryAdmissionProbeVerdict {
        switch verdict {
        case .admit: return .admit
        case .skipNotRegular: return .skipNotRegular
        case .skipTerminated: return .skipTerminated
        case .skipAlreadyTracked: return .skipAlreadyTracked
        case .skipIdentityMismatch: return .skipIdentityMismatch
        case .skipUnread: return .skipUnread
        case .skipNoEligible: return .skipNoEligible
        }
    }

    // MARK: - Snapshot Building

    private func rebuildSnapshot(onScreenCGIDs: Set<CGWindowID>? = nil) {
        // Read frontmost PID once; passed to windowStatus to determine active highlight
        let frontmostPID = currentFrontmostPID()
        lastOnScreenCGIDs = onScreenCGIDs ?? onScreenWindowIDsProvider()

        var windows: [WindowID: WindowRecord] = [:]
        var orderedWindowIDs: [WindowID] = []
        let fallbackByPID = Dictionary(uniqueKeysWithValues: AppFallbackChipDecision.fallbacks(
            for: appOrder.compactMap { pid in
                apps[pid].map { app in
                    AppFallbackChipDecision.Process(
                        pid: pid,
                        bundleID: app.bundleIdentifier,
                        appName: app.appName,
                        hasSeats: !app.windowOrder.isEmpty,
                        isFrontmost: pid == frontmostPID
                    )
                }
            }
        ).map { ($0.pid, $0) })

        // Remember the display each app's windows were last on: with seats it follows the first seat that has
        // an attribution key, without seats it is kept.
        for pid in appOrder {
            guard let app = apps[pid],
                  let home = app.windowOrder.compactMap({ app.windowsByID[$0]?.displayUUID }).first,
                  home != app.lastWindowDisplayUUID else { continue }
            apps[pid]?.lastWindowDisplayUUID = home
        }

        for pid in appOrder {
            guard let app = apps[pid] else { continue }

            if app.windowOrder.isEmpty {
                guard let fallback = fallbackByPID[pid] else { continue }
                let id = WindowID(rawValue: fallback.windowID)
                windows[id] = WindowRecord(
                    id: id,
                    appID: AppID(rawValue: app.bundleIdentifier ?? app.appName),
                    pid: pid,
                    bundleIdentifier: app.bundleIdentifier,
                    title: app.appName,
                    bounds: nil,
                    status: app.isHidden ? .hidden : .inactive,
                    isOnDesktop: pid == frontmostPID,
                    groupID: id.rawValue,   // a fallback card is its own group and never merges into another
                    displayUUID: app.lastWindowDisplayUUID
                )
                orderedWindowIDs.append(id)
            } else {
                // Single-seat model: one seat = one physical window = one card. Stable card identity = the
                // seat token (does not follow the current tab's cgID); action target = the current
                // activeCgID. Visibility uses the seat state directly (a current tab leaving AX is replaced
                // by the new tab at once, so no stale min remains; a really minimized seat is marked
                // isMinimized).
                for cgID in app.windowOrder {
                    guard let seat = app.windowsByID[cgID] else { continue }
                    let id = WindowID(rawValue: "cgw-\(cgID)")
                    windows[id] = WindowRecord(
                        id: id,
                        appID: AppID(rawValue: app.bundleIdentifier ?? app.appName),
                        pid: pid,
                        bundleIdentifier: app.bundleIdentifier,
                        title: seat.title,
                        bounds: seat.bounds,
                        status: windowStatus(isHidden: app.isHidden, isMinimized: seat.isMinimized, isFocused: seat.isFocused, pid: pid, frontmostPID: frontmostPID),
                        cgWindowID: cgID,
                        isOnDesktop: !seat.isMinimized && !app.isHidden,
                        groupID: seat.token,
                        displayUUID: seat.displayUUID
                    )
                    orderedWindowIDs.append(id)
                }
            }
        }

        let next = DockSnapshot(windows: windows, orderedWindowIDs: orderedWindowIDs)
        guard next != snapshot else { return }
        snapshot = next
    }

    private func windowStatus(isHidden: Bool, isMinimized: Bool, isFocused: Bool, pid: pid_t, frontmostPID: pid_t?) -> WindowStatus {
        if isHidden { return .hidden }
        if isMinimized { return .minimized }
        if isFocused && pid == frontmostPID { return .active }
        return .inactive
    }

    private func isRegularNonSelf(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular &&
        app.bundleIdentifier != DockWindowEligibilityPolicy.selfBundleIdentifier
    }

    #if DEBUG
    // MARK: - Deterministic inventory fixtures

    func installFixtureForTesting(_ app: AppEntry) {
        apps[app.pid] = app
        if !appOrder.contains(app.pid) { appOrder.append(app.pid) }
        mutationGenerations[app.pid, default: 0] &+= 1
    }

    func fixtureAppForTesting(pid: pid_t) -> AppEntry? {
        apps[pid]
    }

    @discardableResult
    func reconcileFixtureForTesting(
        pid: pid_t,
        cgSnapshot: AppTrackerCGWindowSnapshot,
        now: Date,
        eligible: [AXWindowSnapshot],
        readOutcome: InventoryAXReadOutcome,
        readMode: InventoryReconcileReadMode = .timed
    ) -> Bool {
        reconcileSeats(
            pid: pid,
            cgSnapshot: cgSnapshot,
            now: now,
            source: .periodicReconcile,
            preloadedEligible: eligible,
            preloadedReadOutcome: readOutcome,
            preloadedReadMode: readMode
        )
    }

    func scheduleEventReadForTesting(pid: pid_t, source: InventoryReconcileSource) {
        scheduleEventRead(pid: pid, source: source)
    }

    func scheduleFrontmostPollForTesting(pid: pid_t) {
        scheduleFrontmostPoll(pid: pid)
    }

    func minimizeForTesting(pid: pid_t, cgWindowID: CGWindowID) {
        handleWindowMinimized(pid: pid, cgWindowID: cgWindowID)
    }

    func destroyForTesting(pid: pid_t, cgWindowID: CGWindowID) {
        handleWindowDestroyed(pid: pid, cgWindowID: cgWindowID)
    }

    func rebuildSnapshotForTesting(onScreenCGIDs: Set<CGWindowID> = []) {
        rebuildSnapshot(onScreenCGIDs: onScreenCGIDs)
    }

    @discardableResult
    func refreshDisplayAttributionFromCGForTesting(cgSnapshot: AppTrackerCGWindowSnapshot) -> Bool {
        refreshDisplayAttributionFromCG(cgSnapshot)
    }

    func screenParametersChangedForTesting() {
        handleScreenParametersChanged()
    }

    func hasPendingEventReadForTesting(pid: pid_t) -> Bool {
        pendingEventReads[pid] != nil || trailingEventSources[pid] != nil
    }

    func setFrontmostPIDForTesting(_ pid: pid_t?) {
        cachedFrontmostPID = pid
    }

    /// Cache state of the CG reuse gate (non-nil after a fresh landing).
    func cgSnapshotCacheForTesting() -> (probeIDs: Set<CGWindowID>, atUptime: TimeInterval)? {
        guard cachedCGSnapshot != nil, let probe = cachedCGProbeIDs else { return nil }
        return (probe, cachedCGAtUptime)
    }

    func bumpCGEventGenerationForTesting() {
        cgEventGeneration &+= 1
    }

    func setObserverActiveForTesting(pid: pid_t, active: Bool) {
        observerActiveOverridesForTesting[pid] = active
    }

    func runPeriodicBatchForTesting(
        cgSnapshot: AppTrackerCGWindowSnapshot,
        timeoutOverride: TimeInterval? = nil
    ) {
        schedulePeriodicBatchRead(
            cgSnapshot: cgSnapshot,
            timeout: timeoutOverride ?? periodicReconcileTimeout ?? 0.1
        )
    }
    #endif
}
