import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

private let windowLiftAXMessagingTimeout: TimeInterval = 0.1

struct WindowLiftCGCandidate: Equatable {
    let key: WindowLiftAvoidance.WindowKey
    let quartzFrame: CGRect
}

struct WindowLiftCGScanResult {
    /// Frontmost large-window candidate per screen (keyed by index into the passed
    /// `screenCGFrames`); screens without one are absent from the dictionary.
    let candidatesByScreenIndex: [Int: WindowLiftCGCandidate]
    let onScreenFrames: [WindowLiftAvoidance.WindowKey: CGRect]
    let liveWindowKeys: Set<WindowLiftAvoidance.WindowKey>?
}

/// Lift avoidance host: provides the geometry of "which screens have an always-shown,
/// visible taskbar", one per screen (under ③④ the orchestration layer aggregates the units).
@MainActor
protocol WindowLiftAvoidanceHost: AnyObject {
    func windowLiftAvoidanceContexts() -> [WindowLiftAvoidanceContext]
}

enum WindowLiftCGWindowProbe {
    static func frontmostLargeWindow(
        on screenCGFrame: CGRect,
        excludingPID selfPID: pid_t
    ) -> WindowLiftCGCandidate? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        return frontmostLargeWindow(in: list, on: screenCGFrame, excludingPID: selfPID)
    }

    static func capture(
        on screenCGFrames: [CGRect],
        excludingPID selfPID: pid_t,
        includeLiveWindowKeys: Bool
    ) -> WindowLiftCGScanResult {
        let onScreenList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        var onScreenFrames: [WindowLiftAvoidance.WindowKey: CGRect] = [:]
        for info in onScreenList {
            guard let key = windowKey(in: info),
                  let bounds = windowBounds(in: info) else { continue }
            onScreenFrames[key] = bounds
        }

        let liveWindowKeys: Set<WindowLiftAvoidance.WindowKey>?
        if includeLiveWindowKeys,
           let fullList = CGWindowListCopyWindowInfo(
               [.optionAll, .excludeDesktopElements],
               kCGNullWindowID
           ) as? [[String: Any]] {
            liveWindowKeys = Set(fullList.compactMap(windowKey(in:)))
        } else {
            liveWindowKeys = nil
        }

        // One CG full list, with the same filter run once per screen (the 0.7
        // width gate is shared with fullscreen detection and not relaxed).
        var candidates: [Int: WindowLiftCGCandidate] = [:]
        for (index, frame) in screenCGFrames.enumerated() {
            if let candidate = frontmostLargeWindow(in: onScreenList, on: frame, excludingPID: selfPID) {
                candidates[index] = candidate
            }
        }
        return WindowLiftCGScanResult(
            candidatesByScreenIndex: candidates,
            onScreenFrames: onScreenFrames,
            liveWindowKeys: liveWindowKeys
        )
    }

    static func liveWindowKeys() -> Set<WindowLiftAvoidance.WindowKey>? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }
        return Set(list.compactMap(windowKey(in:)))
    }

    static func frames(
        for keys: Set<WindowLiftAvoidance.WindowKey>
    ) -> [WindowLiftAvoidance.WindowKey: CGRect] {
        guard !keys.isEmpty else { return [:] }

        var frames: [WindowLiftAvoidance.WindowKey: CGRect] = [:]
        for key in keys {
            guard let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenAboveWindow, .optionIncludingWindow, .excludeDesktopElements],
                key.cgWindowID
            ) as? [[String: Any]],
                  let info = list.first(where: { windowKey(in: $0) == key }),
                  let bounds = windowBounds(in: info) else {
                continue
            }
            frames[key] = bounds
        }
        return frames
    }

    static func frame(for key: WindowLiftAvoidance.WindowKey) -> CGRect? {
        frames(for: [key])[key]
    }

    private static func frontmostLargeWindow(
        in list: [[String: Any]],
        on screenCGFrame: CGRect,
        excludingPID selfPID: pid_t
    ) -> WindowLiftCGCandidate? {
        for info in list {
            guard number(in: info, key: kCGWindowLayer)?.intValue == 0,
                  let key = windowKey(in: info),
                  key.pid != selfPID,
                  let bounds = windowBounds(in: info),
                  bounds.intersects(screenCGFrame),
                  bounds.width > screenCGFrame.width * 0.7,
                  bounds.width >= 80,
                  bounds.height >= 40,
                  (number(in: info, key: kCGWindowAlpha)?.doubleValue ?? 1) > 0 else {
                continue
            }
            return WindowLiftCGCandidate(key: key, quartzFrame: bounds)
        }
        return nil
    }

    private static func windowKey(in info: [String: Any]) -> WindowLiftAvoidance.WindowKey? {
        guard let pid = number(in: info, key: kCGWindowOwnerPID)?.int32Value,
              let windowID = number(in: info, key: kCGWindowNumber)?.uint32Value,
              windowID != 0 else {
            return nil
        }
        return WindowLiftAvoidance.WindowKey(pid: pid, cgWindowID: windowID)
    }

    private static func windowBounds(in info: [String: Any]) -> CGRect? {
        guard let dictionary = info[kCGWindowBounds as String] as? [String: Any] else {
            return nil
        }
        return CGRect(dictionaryRepresentation: dictionary as CFDictionary)
    }

    private static func number(in info: [String: Any], key: CFString) -> NSNumber? {
        info[key as String] as? NSNumber
    }
}

@MainActor
final class WindowLiftAvoidanceController {
    private struct ManagedFrames {
        let nativeAppKit: CGRect
        let targetAppKit: CGRect
        let nativeQuartz: CGRect
        let targetQuartz: CGRect
        let primaryScreenHeight: CGFloat
    }

    private enum ValidationStage: String {
        case candidateMoved
        case handleUnavailable
        case roleUnavailable
        case unsupportedRole
        case fullscreen
        case minimized
        case frameUnavailable
        case frameMismatch
        case capabilityUnavailable
        case sizeNotSettable
    }

    private enum ValidationOutcome {
        case ready(AXWindowHandle)
        case transient(ValidationStage)
        case unsupported(ValidationStage)
    }

    private struct WriteAnomaly {
        let reason: AXWindowFrameWriteFailure
        let rollback: AXWindowFrameRollbackResult
        let decision: WindowLiftAvoidance.AnimationWriteFailureDecision
        let progress: Double
    }

    private enum OperationOutcome {
        case completed(CGRect, reliftCount: Int, anomalies: [WriteAnomaly])
        case externalFrame(CGRect, anomalies: [WriteAnomaly])
        case reliftLimitReached(CGRect, reliftCount: Int, anomalies: [WriteAnomaly])
        case failed(
            reason: AXWindowFrameWriteFailure,
            rollback: AXWindowFrameRollbackResult,
            progress: Double,
            reliftCount: Int,
            anomalies: [WriteAnomaly]
        )
        case transientValidation(ValidationStage)
        case unsupportedValidation(ValidationStage)
        case cancelled
    }

    private static let trackedProbeInterval = WindowLiftAvoidance.trackedSessionProbeInterval

    private weak var host: WindowLiftAvoidanceHost?
    private let logger = Logger(
        subsystem: "no.thilip.nitiadock",
        category: "WindowLiftAvoidance"
    )
    private var pollTimer: Timer?
    private var pollTimerInterval: TimeInterval?
    private var eventPollTimer: Timer?
    private var eventPollCoalescer = WindowLiftAvoidance.EventPollCoalescer()
    private var scanTask: Task<Void, Never>?
    private var trackedProbeTimer: Timer?
    private var trackedProbeTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var writeTasks: [WindowLiftAvoidance.WindowKey: Task<Void, Never>] = [:]
    private var writeDrainTasks: [
        WindowLiftAvoidance.WindowKey: [Task<Void, Never>]
    ] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var geometryObserver: FrontmostWindowGeometryObserver?
    private var states: [WindowLiftAvoidance.WindowKey: WindowLiftAvoidance.SessionState] = [:]
    private var managedFrames: [WindowLiftAvoidance.WindowKey: ManagedFrames] = [:] {
        didSet { persistJournal() }
    }
    private var suppressedFrames: [WindowLiftAvoidance.WindowKey: ManagedFrames] = [:]
    private var observationWatermarks: [WindowLiftAvoidance.WindowKey: UInt64] = [:]
    private var validationGenerations: [WindowLiftAvoidance.WindowKey: UInt64] = [:]
    private var lastTraceClassifications: [
        WindowLiftAvoidance.WindowKey: WindowLiftAvoidance.FrameClassification
    ] = [:]
    /// Context set last given by the host (one per screen). Any change to the set =
    /// restore all lifted windows and rescan (generalizes today's screen-change behavior).
    private var lastContexts: [WindowLiftAvoidanceContext] = []
    /// Context of the screen each session belongs to (sessions sit on different screens
    /// in multi-screen setups). Added/removed with `states`; probing handles each by it.
    private var sessionContexts: [WindowLiftAvoidance.WindowKey: WindowLiftAvoidanceContext] = [:]
    private var nextGeneration: UInt64 = 0
    private var scanGeneration: UInt64 = 0
    private var trackedProbeGeneration: UInt64 = 0
    private var restoreGeneration: UInt64 = 0
    private var scanInFlight = false
    private var usesAnimatedLift = false
    private var traceEnabled = false
    private var periodicPollCount: UInt64 = 0
    private var eventPollCount: UInt64 = 0
    private var trailingEventPollCount: UInt64 = 0
    private var isEnabled = false
    /// User setting (menu "Keep maximized windows above the taskbar"). **Off by default**;
    /// `AppDelegate` seeds it once at startup from the persisted value and then keeps it in
    /// sync by subscription. It lives on the controller rather than being gated only by
    /// callers: `endPermissionUncertainty()` calls `start()` internally, so with only an
    /// outside gate a single permission flap could turn a feature the user disabled back on.
    private var isEnabledBySetting = false

    /// While frozen: drop only task references, never touch `states` / `managedFrames` /
    /// `suppressedFrames` / `pendingRestorations`. After permission is revoked AX cannot move
    /// windows, so clearing snapshots then means losing the ability to restore for good.
    private var isPermissionFrozen = false
    private var freezeGeneration: UInt64 = 0
    /// Windows pending restore are owned by the controller: an item is removed only once
    /// restored. This data used to be copied into locals and handed to a detached task,
    /// where the freeze mechanism could not take it over when permission was lost midway.
    private var pendingRestorations: [WindowLiftAvoidance.WindowKey: ManagedFrames] = [:] {
        didSet { persistJournal() }
    }
    /// Where the frames of windows we resized are written down, so the next launch can put them
    /// back if this process dies without running `stopAndRestore` (crash, force quit). `nil` = no
    /// journal (tests).
    private let journalDefaults: UserDefaults?
    private var journalStartTimes: [WindowLiftAvoidance.WindowKey: timeval] = [:]
    /// Process start time at enqueue, used to detect pid reuse after a long freeze.
    private var pendingRestorationStartTimes: [WindowLiftAvoidance.WindowKey: timeval] = [:]
    /// Write tasks that were cancelled but have not finished. A cancelled
    /// AX call cannot be interrupted midway, so they must be drained before
    /// restoring, or a late rollback would overwrite the restore result.
    private var pendingDrains: [Task<Void, Never>] = []
    private let isTrustedProbe: () -> Bool

    private enum RestoreOutcome: Equatable {
        /// Restored, or confirmed not to need restoring (user moved it, window gone, pid reused).
        case handled
        /// Out of reach this round (most likely Accessibility
        /// permission not granted yet); keep it for the next attempt.
        case unreachable
    }

    init(
        host: WindowLiftAvoidanceHost,
        journalDefaults: UserDefaults? = nil,
        isTrustedProbe: @escaping () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.host = host
        self.journalDefaults = journalDefaults
        self.isTrustedProbe = isTrustedProbe
    }

    // MARK: - Crash journal

    private static let journalKey = "forkWindowLiftJournal"
    private static let journalRectNames = ["nativeAppKit", "targetAppKit", "nativeQuartz", "targetQuartz"]

    /// Mirrors every window we have resized (live sessions and queued restorations) into the
    /// journal. Runs on each change of either dictionary; they hold a handful of windows.
    private func persistJournal() {
        guard let journalDefaults else { return }
        let all = pendingRestorations.merging(managedFrames) { _, managed in managed }
        journalStartTimes = journalStartTimes.filter { all[$0.key] != nil }
        guard !all.isEmpty else {
            journalDefaults.removeObject(forKey: Self.journalKey)
            return
        }
        var rows: [[String: Double]] = []
        for (key, frames) in all {
            guard let start = pendingRestorationStartTimes[key] ?? journalStartTimes[key]
                    ?? ProcessLiveness.startTime(pid: key.pid) else { continue }
            journalStartTimes[key] = start
            var row: [String: Double] = [
                "pid": Double(key.pid),
                "cgWindowID": Double(key.cgWindowID),
                "startSec": Double(start.tv_sec),
                "startUsec": Double(start.tv_usec),
                "primaryScreenHeight": Double(frames.primaryScreenHeight)
            ]
            let rects = [frames.nativeAppKit, frames.targetAppKit, frames.nativeQuartz, frames.targetQuartz]
            for (name, rect) in zip(Self.journalRectNames, rects) {
                row[name + ".x"] = Double(rect.minX)
                row[name + ".y"] = Double(rect.minY)
                row[name + ".w"] = Double(rect.width)
                row[name + ".h"] = Double(rect.height)
            }
            rows.append(row)
        }
        journalDefaults.set(rows, forKey: Self.journalKey)
    }

    /// Call once at launch, before `start()`. Windows a previous run left resized are queued for
    /// the normal restore path, which re-checks each one (same process, window still there, frame
    /// still the one we wrote) and drops anything that does not match.
    func restoreWindowsLeftByPreviousRun() {
        guard let journalDefaults,
              let rows = journalDefaults.array(forKey: Self.journalKey) as? [[String: Double]] else { return }
        for row in rows.prefix(64) {
            guard let pid = row["pid"], let windowID = row["cgWindowID"],
                  let startSec = row["startSec"], let startUsec = row["startUsec"],
                  let screenHeight = row["primaryScreenHeight"],
                  pid >= 1, pid <= Double(Int32.max), windowID >= 1, windowID <= Double(UInt32.max),
                  startSec >= 0, startSec <= 1e11, startUsec >= 0, startUsec < 1_000_000,
                  screenHeight.isFinite, screenHeight > 0 else { continue }
            var rects: [CGRect] = []
            for name in Self.journalRectNames {
                guard let x = row[name + ".x"], let y = row[name + ".y"],
                      let width = row[name + ".w"], let height = row[name + ".h"],
                      x.isFinite, y.isFinite, width.isFinite, height.isFinite,
                      width > 0, height > 0 else { break }
                rects.append(CGRect(x: x, y: y, width: width, height: height))
            }
            guard rects.count == Self.journalRectNames.count else { continue }
            let key = WindowLiftAvoidance.WindowKey(pid: pid_t(pid), cgWindowID: CGWindowID(windowID))
            pendingRestorationStartTimes[key] = timeval(tv_sec: Int(startSec), tv_usec: Int32(startUsec))
            pendingRestorations[key] = ManagedFrames(
                nativeAppKit: rects[0],
                targetAppKit: rects[1],
                nativeQuartz: rects[2],
                targetQuartz: rects[3],
                primaryScreenHeight: CGFloat(screenHeight)
            )
        }
        guard !pendingRestorations.isEmpty else {
            journalDefaults.removeObject(forKey: Self.journalKey)
            return
        }
        restoreSettledWindowsAndClearSessions()
    }

    // MARK: - Permission freeze

    /// Called the first time the permission cannot be read. Nothing has
    /// changed in the UI yet, but snapshots must be locked immediately.
    func beginPermissionUncertainty() {
        enterFreeze(reason: "permissionUncertain")
    }

    /// False-alarm path: the permission reads fine again. **Staged unfreeze**: drain old writers,
    /// bump the generation to reject late callbacks, converge frozen sessions against the current
    /// situation, and only then resume polling. Clearing the freeze flag directly would leave a
    /// `.writing` session whose writer is dead and which never issues a new write (the pure reducer
    /// only updates the generation on later observations), so that window would never move again.
    func endPermissionUncertainty() {
        guard isPermissionFrozen else { return }
        freezeGeneration &+= 1
        let generation = freezeGeneration
        let drains = pendingDrains
        pendingDrains.removeAll()

        Task { @MainActor [weak self] in
            for task in drains { await task.value }
            guard let self, self.freezeGeneration == generation, self.isPermissionFrozen else { return }
            self.isPermissionFrozen = false
            self.convergeFrozenSessions()
            self.start()
        }
    }

    /// Called right after permission returns, before restarting the
    /// process: drain → unfreeze → restore → wait for restores to finish.
    func restoreAndStopForPermissionRecovery() async {
        freezeGeneration &+= 1
        let drains = pendingDrains
        pendingDrains.removeAll()
        for task in drains { await task.value }

        isPermissionFrozen = false
        stop()
        while let task = restoreTask {
            await task.value
        }
    }

    private func enterFreeze(reason: String) {
        guard !isPermissionFrozen else { return }
        isPermissionFrozen = true
        // A poll() already queued on the main queue only looks at this field, so it must be turned off too.
        isEnabled = false
        freezeGeneration &+= 1
        pollTimer?.invalidate()
        pollTimer = nil
        pollTimerInterval = nil
        resetEventPolling()
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        scanInFlight = false
        stopTrackedProbe()
        geometryObserver?.stop()
        geometryObserver = nil
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        for task in writeTasks.values {
            task.cancel()
            pendingDrains.append(task)
        }
        for tasks in writeDrainTasks.values { pendingDrains.append(contentsOf: tasks) }
        writeTasks.removeAll()
        writeDrainTasks.removeAll()

        logger.notice("""
            lift frozen reason=\(reason, privacy: .public) \
            sessions=\(self.states.count, privacy: .public) \
            pending=\(self.pendingRestorations.count, privacy: .public)
            """)
    }

    /// Unfreeze convergence: a `.writing` session whose writer
    /// was cancelled cannot finish on its own; clear it in place.
    /// Cleared with `suppressUntilNative`, so the next round does not take
    /// the already lifted position for the native one and lift again.
    private func convergeFrozenSessions() {
        let stalled = states.compactMap { key, state -> WindowLiftAvoidance.WindowKey? in
            if case .writing = state { return key }
            return nil
        }
        for key in stalled {
            clearManagedSession(
                for: key,
                cancelWriter: false,
                reason: "permissionUnfreeze",
                suppressUntilNative: true
            )
        }
    }

    /// During a freeze, every operation that would erase session data is forbidden.
    private func canMutateSessions() -> Bool { !isPermissionFrozen }

    /// Single gate for destructive entry points; also runs
    /// a **silent** trust self-check (never with a prompt).
    ///
    /// Snapshot protection must be the controller's own job: the watchdog samples every 5 seconds; as
    /// long as there is a session, suppressed frame or restore task, this keeps polling every 0.2s.
    /// The 1s slow rate applies only when idle with no snapshot to protect. In the 0–5 seconds between
    /// revocation and the watchdog's first false, a single screen switch by the user would make
    /// `reconcileContext` clear the snapshots before restoring, while AX can already no longer write.
    private func ensureTrustedOrFreeze() -> Bool {
        if isPermissionFrozen { return false }
        guard isTrustedProbe() else {
            enterFreeze(reason: "selfCheck")
            return false
        }
        return true
    }

    deinit {
        MainActor.assumeIsolated { stop() }
    }

    /// The user's switch. Off → `stop()` (which also restores lifted windows to their native size);
    /// on → restart polling.
    ///
    /// Not restarted during a freeze: `enterFreeze` has already removed the workspace observers
    /// and cleared `isEnabled`, so `start()` would only attach an idle timer and reinstall
    /// observers that must not exist while frozen. On unfreeze `endPermissionUncertainty()`
    /// calls `start()` itself, and that path now honors this flag too.
    func setEnabledBySetting(_ enabled: Bool) {
        guard isEnabledBySetting != enabled else { return }
        isEnabledBySetting = enabled
        if enabled {
            guard !isPermissionFrozen else { return }
            start()
        } else {
            stop()
        }
    }

    func start(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard !isEnabled else { return }
        guard isEnabledBySetting else { return }
        guard DebugSwitch.windowLift.isEnabled(in: environment) else {
            logger.info("window lift disabled by DOCK_WINDOW_LIFT=0")
            return
        }

        isEnabled = true
        usesAnimatedLift = DebugSwitch.windowLiftAnim.isEnabled(in: environment)
        traceEnabled = DebugSwitch.windowLiftTrace.isEnabled(in: environment)
        periodicPollCount = 0
        eventPollCount = 0
        trailingEventPollCount = 0
        subscribeWorkspaceNotifications()

        let geometryObserver = FrontmostWindowGeometryObserver()
        geometryObserver.onEvent = { [weak self] _ in
            self?.requestEventPoll()
        }
        self.geometryObserver = geometryObserver
        let initialPID = NSWorkspace.shared.runningApplications.first(where: { $0.isActive })?
            .processIdentifier
        geometryObserver.start(pid: initialPID)

        updatePollTimerLifecycle()
        poll()
        if traceEnabled {
            logger.info("window lift trace started animated=\(self.usesAnimatedLift, privacy: .public)")
        }
    }

    func stop() {
        // After a freeze isEnabled and pollTimer are both cleared; checking only those two would make stop()
        // a no-op and leave pending windows never restored, so outstanding restores must be checked too.
        guard isEnabled || pollTimer != nil || geometryObserver != nil
            || !states.isEmpty || !pendingRestorations.isEmpty else { return }
        tracePollSummary(reason: "stop")
        isEnabled = false
        pollTimer?.invalidate()
        pollTimer = nil
        pollTimerInterval = nil
        resetEventPolling()
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        scanInFlight = false
        stopTrackedProbe()
        geometryObserver?.stop()
        geometryObserver = nil
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        restoreSettledWindowsAndClearSessions()
        lastContexts = []
        sessionContexts.removeAll()
    }

    func stopAndRestore() async {
        stop()
        while let task = restoreTask {
            await task.value
        }
    }

    private func subscribeWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activePID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.cancelWrites(except: activePID)
                self.geometryObserver?.activate(pid: activePID)
                self.requestEventPoll()
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            Task { @MainActor [weak self] in
                guard let self, let pid else { return }
                self.removeStates(forPID: pid)
            }
        })
    }

    private func hostContexts() -> [WindowLiftAvoidanceContext] {
        host?.windowLiftAvoidanceContexts() ?? []
    }

    private func poll() {
        guard isEnabled, ensureTrustedOrFreeze() else { return }
        let contexts = hostContexts()
        reconcileContexts(contexts)
        guard !contexts.isEmpty, !scanInFlight, restoreTask == nil else { return }

        scanInFlight = true
        scanGeneration &+= 1
        let generation = scanGeneration
        nextGeneration &+= 1
        let observationGeneration = nextGeneration
        let tracked = !states.isEmpty || !suppressedFrames.isEmpty
        let selfPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let screenCGFrames = contexts.map(\.screenCGFrame)
        scanTask = Task.detached { [weak self] in
            let result = WindowLiftCGWindowProbe.capture(
                on: screenCGFrames,
                excludingPID: selfPID,
                includeLiveWindowKeys: tracked
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.handleScanResult(
                    result,
                    contexts: contexts,
                    scanGeneration: generation,
                    observationGeneration: observationGeneration
                )
            }
        }
    }

    private func updatePollTimerLifecycle() {
        guard isEnabled else {
            pollTimer?.invalidate()
            pollTimer = nil
            pollTimerInterval = nil
            return
        }

        let interval = WindowLiftAvoidance.PollCadence.interval(
            hasSessions: !states.isEmpty,
            hasSuppressedFrames: !suppressedFrames.isEmpty,
            isRestoring: restoreTask != nil
        )
        guard pollTimer == nil || pollTimerInterval != interval else { return }

        let previousInterval = pollTimerInterval
        if traceEnabled, let previous = previousInterval {
            logger.info(
                "lift trace cadence from=\(previous, privacy: .public) to=\(interval, privacy: .public)"
            )
        }
        pollTimer?.invalidate()
        resetEventPolling()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.periodicPollCount &+= 1
                self.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        pollTimerInterval = interval

        // The old fixed 0.2s timer always supplied one more convergence scan after a
        // transient validation/session clear. Preserve that behavior when dropping to idle.
        if previousInterval == WindowLiftAvoidance.globalDetectionInterval,
           interval == WindowLiftAvoidance.PollCadence.idleInterval {
            Task { @MainActor [weak self] in self?.requestEventPoll() }
        }
    }

    private var usesFastPollCadence: Bool {
        pollTimerInterval == WindowLiftAvoidance.globalDetectionInterval
    }

    private func requestEventPoll() {
        guard isEnabled, !usesFastPollCadence else { return }
        let action = eventPollCoalescer.request(
            at: ProcessInfo.processInfo.systemUptime,
            scanInFlight: scanInFlight
        )
        performEventPollAction(action, trailing: false)
    }

    private func finishEventPollAfterScan() {
        guard isEnabled, !usesFastPollCadence else { return }
        let action = eventPollCoalescer.scanCompleted(
            at: ProcessInfo.processInfo.systemUptime
        )
        performEventPollAction(action, trailing: true)
    }

    private func performEventPollAction(
        _ action: WindowLiftAvoidance.EventPollCoalescer.Action,
        trailing: Bool
    ) {
        switch action {
        case .none:
            break
        case .start:
            eventPollTimer?.invalidate()
            eventPollTimer = nil
            if trailing {
                trailingEventPollCount &+= 1
            } else {
                eventPollCount &+= 1
            }
            poll()
        case .schedule(let delay):
            guard eventPollTimer == nil else { return }
            let timer = Timer(timeInterval: max(0, delay), repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.eventPollTimer = nil
                    let action = self.eventPollCoalescer.cooldownFired(
                        at: ProcessInfo.processInfo.systemUptime,
                        scanInFlight: self.scanInFlight
                    )
                    self.performEventPollAction(action, trailing: true)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            eventPollTimer = timer
        }
    }

    private func resetEventPolling() {
        eventPollTimer?.invalidate()
        eventPollTimer = nil
        eventPollCoalescer.reset()
    }

    private func tracePollSummary(reason: String) {
        guard traceEnabled else { return }
        logger.info(
            "lift trace poll-summary reason=\(reason, privacy: .public) periodic=\(self.periodicPollCount, privacy: .public) event=\(self.eventPollCount, privacy: .public) trailing=\(self.trailingEventPollCount, privacy: .public)"
        )
    }

    private func updateTrackedProbeLifecycle() {
        guard isEnabled, !states.isEmpty, restoreTask == nil else {
            stopTrackedProbe()
            return
        }
        guard trackedProbeTimer == nil else { return }

        let timer = Timer(timeInterval: Self.trackedProbeInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.probeTrackedFrames() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackedProbeTimer = timer
    }

    private func stopTrackedProbe() {
        trackedProbeTimer?.invalidate()
        trackedProbeTimer = nil
        trackedProbeGeneration &+= 1
        trackedProbeTask?.cancel()
        trackedProbeTask = nil
    }

    private func probeTrackedFrames() {
        guard isEnabled,
              restoreTask == nil,
              trackedProbeTask == nil,
              !lastContexts.isEmpty else {
            updateTrackedProbeLifecycle()
            return
        }
        let contexts = lastContexts
        guard hostContexts() == contexts else {
            stopTrackedProbe()
            return
        }

        sessionContexts = sessionContexts.filter { states[$0.key] != nil }
        let keys = Set(states.keys)
        guard !keys.isEmpty else {
            updateTrackedProbeLifecycle()
            return
        }

        trackedProbeGeneration &+= 1
        let generation = trackedProbeGeneration
        nextGeneration &+= 1
        let observationGeneration = nextGeneration
        trackedProbeTask = Task.detached { [weak self] in
            let frames = WindowLiftCGWindowProbe.frames(for: keys)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.handleTrackedProbeResult(
                    frames,
                    contexts: contexts,
                    probeGeneration: generation,
                    observationGeneration: observationGeneration
                )
            }
        }
    }

    private func handleTrackedProbeResult(
        _ quartzFrames: [WindowLiftAvoidance.WindowKey: CGRect],
        contexts: [WindowLiftAvoidanceContext],
        probeGeneration: UInt64,
        observationGeneration: UInt64
    ) {
        guard probeGeneration == trackedProbeGeneration else { return }
        trackedProbeTask = nil
        guard hostContexts() == contexts else {
            stopTrackedProbe()
            return
        }

        for (key, quartzFrame) in quartzFrames {
            // The session's screen must still be in the set; if not (that screen's bar was
            // hidden / unplugged), reconcileContexts has already restored it wholesale.
            guard let context = sessionContexts[key], contexts.contains(context) else { continue }
            _ = handleTrackedObservation(
                quartzFrame,
                for: key,
                context: context,
                observationGeneration: observationGeneration
            )
        }
        updateTrackedProbeLifecycle()
    }

    @discardableResult
    private func handleTrackedObservation(
        _ quartzFrame: CGRect,
        for key: WindowLiftAvoidance.WindowKey,
        context: WindowLiftAvoidanceContext,
        observationGeneration: UInt64
    ) -> Bool {
        guard let state = states[key], let frames = managedFrames[key] else { return false }
        guard acceptObservation(for: key, generation: observationGeneration) else { return true }

        let appKitFrame = WindowLiftAvoidance.appKitFrame(
            fromQuartz: quartzFrame,
            primaryScreenHeight: context.primaryScreenHeight
        )
        let classification = WindowLiftAvoidance.frameClassification(
            of: appKitFrame,
            nativeFrame: frames.nativeAppKit,
            targetFrame: frames.targetAppKit
        )
        traceClassification(classification, for: key)

        if case let .writing(attempt) = state,
           validationGenerations[key] == attempt.generation,
           classification == .external {
            // The bounded CG/AX confirmation owns zoom-tail movement until it either stabilizes or
            // returns candidateMoved. No AX write has happened yet, so never suppress this frame.
            return true
        }

        if case .lifted = state, classification == .native {
            guard NSRunningApplication(processIdentifier: key.pid)?.isActive == true,
                  hostContexts().contains(context) else {
                return true
            }
        }

        let transition = WindowLiftAvoidance.reduce(
            state: state,
            event: .nonMaximizedObserved(
                generation: observationGeneration,
                at: ProcessInfo.processInfo.systemUptime,
                frame: appKitFrame
            )
        )
        let candidate = WindowLiftCGCandidate(
            key: key,
            quartzFrame: WindowLiftAvoidance.quartzFrame(
                fromAppKit: appKitFrame,
                primaryScreenHeight: context.primaryScreenHeight
            )
        )
        apply(
            transition,
            for: candidate,
            context: context,
            operationGeneration: observationGeneration
        )
        return true
    }

    /// Any change to the context **set** (a screen's bar shown/hidden, size step changed, screen
    /// plugged/unplugged) → restore all lifted windows and rescan next round (re-lift within ≤0.2s).
    /// Generalizes the single-screen "restore on screen change" behavior; per-screen incremental
    /// restore is deferred until someone reports "windows on the other screen jump too".
    private func reconcileContexts(_ contexts: [WindowLiftAvoidanceContext]) {
        guard canMutateSessions() else { return }
        guard contexts != lastContexts else { return }
        observationWatermarks.removeAll()
        suppressedFrames.removeAll()
        scanGeneration &+= 1
        scanTask?.cancel()
        scanTask = nil
        scanInFlight = false
        updatePollTimerLifecycle()

        if !lastContexts.isEmpty {
            restoreSettledWindowsAndClearSessions()
        }
        lastContexts = contexts
    }

    private func handleScanResult(
        _ result: WindowLiftCGScanResult,
        contexts: [WindowLiftAvoidanceContext],
        scanGeneration: UInt64,
        observationGeneration: UInt64
    ) {
        guard scanGeneration == self.scanGeneration else { return }
        scanTask = nil
        scanInFlight = false
        defer { finishEventPollAfterScan() }
        // Already queued scan callbacks must pass the gate too: guards
        // on a few cleanup functions do not stop in-flight work.
        guard canMutateSessions() else { return }
        guard hostContexts() == contexts else { return }

        if let liveWindowKeys = result.liveWindowKeys {
            pruneDeadWindowStates(
                liveWindowKeys: liveWindowKeys,
                observationGeneration: observationGeneration
            )
        }
        let reconciledKeys = reconcileTrackedFrames(
            result.onScreenFrames,
            contexts: contexts,
            observationGeneration: observationGeneration
        )

        // Candidates per screen; a window spanning screens belongs only to the screen
        // holding most of its area. Only the frontmost app's windows are lifted, so
        // taking the first candidate in screen order that passes every gate is enough.
        let screenCGFrames = contexts.map(\.screenCGFrame)
        for (index, context) in contexts.enumerated() {
            guard let candidate = result.candidatesByScreenIndex[index],
                  WindowLiftAvoidance.owningContextIndex(for: candidate.quartzFrame, screenCGFrames: screenCGFrames) == index,
                  !reconciledKeys.contains(candidate.key) else { continue }
            if handleScanCandidate(
                candidate,
                context: context,
                observationGeneration: observationGeneration
            ) {
                return
            }
        }
    }

    /// Returns true = this candidate was handled (lifted, or
    /// already in a session); later screens need not be checked.
    private func handleScanCandidate(
        _ candidate: WindowLiftCGCandidate,
        context: WindowLiftAvoidanceContext,
        observationGeneration: UInt64
    ) -> Bool {
        guard acceptObservation(
            for: candidate.key,
            generation: observationGeneration
        ) else {
            return false
        }
        let appKitFrame = WindowLiftAvoidance.appKitFrame(
            fromQuartz: candidate.quartzFrame,
            primaryScreenHeight: context.primaryScreenHeight
        )
        if let suppressed = suppressedFrames[candidate.key] {
            let classification = WindowLiftAvoidance.frameClassification(
                of: appKitFrame,
                nativeFrame: suppressed.nativeAppKit,
                targetFrame: suppressed.targetAppKit
            )
            traceClassification(classification, for: candidate.key)
            guard classification == .native else { return false }
            suppressedFrames.removeValue(forKey: candidate.key)
            updatePollTimerLifecycle()
            if traceEnabled {
                logger.info(
                    "lift trace suppression cleared pid=\(candidate.key.pid, privacy: .public) wid=\(candidate.key.cgWindowID, privacy: .public)"
                )
            }
        }
        guard context.geometry.fillsVisibleFrame(appKitFrame),
              let targetFrame = context.geometry.adjustedFrame(for: appKitFrame),
              let app = NSRunningApplication(processIdentifier: candidate.key.pid),
              app.isActive,
              !app.isTerminated,
              app.activationPolicy == .regular || app.activationPolicy == .accessory else {
            return false
        }

        let operationGeneration = observationGeneration
        let transition = WindowLiftAvoidance.reduce(
            state: states[candidate.key] ?? .idle,
            event: .maximizedDetected(
                generation: operationGeneration,
                at: ProcessInfo.processInfo.systemUptime,
                nativeFrame: appKitFrame,
                targetFrame: targetFrame
            )
        )
        apply(
            transition,
            for: candidate,
            context: context,
            operationGeneration: operationGeneration
        )
        return true
    }

    private func reconcileTrackedFrames(
        _ quartzFrames: [WindowLiftAvoidance.WindowKey: CGRect],
        contexts: [WindowLiftAvoidanceContext],
        observationGeneration: UInt64
    ) -> Set<WindowLiftAvoidance.WindowKey> {
        var reconciled: Set<WindowLiftAvoidance.WindowKey> = []
        for key in Array(states.keys) {
            guard let quartzFrame = quartzFrames[key],
                  let context = sessionContexts[key], contexts.contains(context) else { continue }
            if handleTrackedObservation(
                quartzFrame,
                for: key,
                context: context,
                observationGeneration: observationGeneration
            ) {
                reconciled.insert(key)
            }
        }
        return reconciled
    }

    private func acceptObservation(
        for key: WindowLiftAvoidance.WindowKey,
        generation: UInt64
    ) -> Bool {
        guard generation > (observationWatermarks[key] ?? 0) else { return false }
        observationWatermarks[key] = generation
        return true
    }

    private func apply(
        _ transition: WindowLiftAvoidance.Transition,
        for candidate: WindowLiftCGCandidate,
        context: WindowLiftAvoidanceContext,
        operationGeneration: UInt64
    ) {
        sessionContexts[candidate.key] = context
        if transition.action == .clear {
            clearManagedSession(
                for: candidate.key,
                cancelWriter: true,
                reason: "reducerClear",
                suppressUntilNative: true
            )
            return
        }
        store(transition.state, for: candidate.key)
        switch transition.action {
        case .none:
            break
        case .clear:
            break
        case let .abandon(reason):
            logger.error(
                "lift abandoned pid=\(candidate.key.pid, privacy: .public) wid=\(candidate.key.cgWindowID, privacy: .public) reason=\(String(describing: reason), privacy: .public)"
            )
        case let .write(targetFrame, rollbackFrame, generation, isRelift):
            guard generation == operationGeneration else { return }
            beginWrite(
                candidate: candidate,
                nativeFrame: rollbackFrame,
                targetFrame: targetFrame,
                context: context,
                generation: generation,
                isRelift: isRelift
            )
        }
    }

    private func beginWrite(
        candidate: WindowLiftCGCandidate,
        nativeFrame: CGRect,
        targetFrame: CGRect,
        context: WindowLiftAvoidanceContext,
        generation: UInt64,
        isRelift: Bool
    ) {
        let key = candidate.key
        guard case let .writing(attempt) = states[key],
              attempt.generation == generation else {
            return
        }
        let nativeQuartz = WindowLiftAvoidance.quartzFrame(
            fromAppKit: nativeFrame,
            primaryScreenHeight: context.primaryScreenHeight
        )
        let targetQuartz = WindowLiftAvoidance.quartzFrame(
            fromAppKit: targetFrame,
            primaryScreenHeight: context.primaryScreenHeight
        )
        managedFrames[key] = ManagedFrames(
            nativeAppKit: nativeFrame,
            targetAppKit: targetFrame,
            nativeQuartz: nativeQuartz,
            targetQuartz: targetQuartz,
            primaryScreenHeight: context.primaryScreenHeight
        )
        validationGenerations[key] = generation

        let animate = usesAnimatedLift
        let reader = AXWindowReader()
        var drains = writeDrainTasks.removeValue(forKey: key) ?? []
        if let previousWriter = writeTasks.removeValue(forKey: key) {
            previousWriter.cancel()
            drains.append(previousWriter)
        }
        let task = Task.detached { [weak self] in
            for drain in drains {
                await drain.value
            }
            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.finishOperation(for: key, generation: generation, outcome: .cancelled)
                }
                return
            }

            let mayBegin = await MainActor.run { [weak self] in
                self?.canContinueOperation(
                    for: key,
                    generation: generation,
                    context: context
                ) ?? false
            }
            guard mayBegin, !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.finishOperation(for: key, generation: generation, outcome: .cancelled)
                }
                return
            }

            let detectedAt = ProcessInfo.processInfo.systemUptime
            let validation = await Self.validatedHandle(
                reader: reader,
                candidate: candidate,
                detectedAt: detectedAt
            )
            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.finishOperation(for: key, generation: generation, outcome: .cancelled)
                }
                return
            }

            let handle: AXWindowHandle
            switch validation {
            case let .ready(validatedHandle):
                handle = validatedHandle
            case let .transient(stage):
                await MainActor.run { [weak self] in
                    self?.finishOperation(
                        for: key,
                        generation: generation,
                        outcome: .transientValidation(stage)
                    )
                }
                return
            case let .unsupported(stage):
                await MainActor.run { [weak self] in
                    self?.finishOperation(
                        for: key,
                        generation: generation,
                        outcome: .unsupportedValidation(stage)
                    )
                }
                return
            }

            let mayContinue = await MainActor.run { [weak self] in
                self?.canBeginAXWrite(
                    for: key,
                    generation: generation,
                    context: context
                ) ?? false
            }
            guard mayContinue, !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.finishOperation(for: key, generation: generation, outcome: .cancelled)
                }
                return
            }

            let outcome = await Self.write(
                reader: reader,
                element: handle.element,
                nativeFrame: nativeQuartz,
                targetFrame: targetQuartz,
                animated: animate,
                initialReliftCount: attempt.reliftCount,
                primaryScreenHeight: context.primaryScreenHeight
            )
            await MainActor.run { [weak self] in
                self?.finishOperation(for: key, generation: generation, outcome: outcome)
            }
        }
        writeTasks[key] = task
        if isRelift {
            logger.notice(
                "lift relift begin pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) count=\(attempt.reliftCount, privacy: .public)"
            )
        } else if traceEnabled {
            logger.info(
                "lift trace begin pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) generation=\(generation, privacy: .public) animated=\(animate, privacy: .public)"
            )
        }
        updateTrackedProbeLifecycle()
    }

    nonisolated private static func validatedHandle(
        reader: AXWindowReader,
        candidate: WindowLiftCGCandidate,
        detectedAt: TimeInterval
    ) async -> ValidationOutcome {
        let schedule = WindowLiftAvoidance.PollSchedule.standard
        var lastTransientStage: ValidationStage = .handleUnavailable

        for index in schedule.deadlines.indices {
            guard !Task.isCancelled else { return .transient(lastTransientStage) }
            let elapsed = ProcessInfo.processInfo.systemUptime - detectedAt
            if let delay = schedule.remainingDelay(for: index, elapsed: elapsed), delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return .transient(lastTransientStage) }
            guard let confirmedCGFrame = WindowLiftCGWindowProbe.frame(for: candidate.key) else {
                lastTransientStage = .candidateMoved
                continue
            }
            guard let handle = reader.captureHandle(
                forPID: candidate.key.pid,
                cgWindowID: candidate.key.cgWindowID,
                messagingTimeout: windowLiftAXMessagingTimeout
            ) else {
                lastTransientStage = .handleUnavailable
                continue
            }

            let element = handle.element
            guard let role = reader.stringAttribute(
                kAXRoleAttribute as CFString,
                from: element,
                maxAttempts: 1
            ) else {
                lastTransientStage = .roleUnavailable
                continue
            }
            guard role == (kAXWindowRole as String) else { return .unsupported(.unsupportedRole) }
            if reader.boolAttribute("AXFullScreen" as CFString, from: element, maxAttempts: 1) == true {
                guard index == schedule.deadlines.index(before: schedule.deadlines.endIndex) else {
                    lastTransientStage = .fullscreen
                    continue
                }
                return .unsupported(.fullscreen)
            }
            if reader.boolAttribute(
                kAXMinimizedAttribute as CFString,
                from: element,
                maxAttempts: 1
            ) == true {
                guard index == schedule.deadlines.index(before: schedule.deadlines.endIndex) else {
                    lastTransientStage = .minimized
                    continue
                }
                return .unsupported(.minimized)
            }
            guard let confirmedAXFrame = reader.frame(
                of: element,
                messagingTimeout: windowLiftAXMessagingTimeout
            ) else {
                lastTransientStage = .frameUnavailable
                continue
            }

            switch reader.frameSettableStatus(
                of: element,
                messagingTimeout: windowLiftAXMessagingTimeout
            ).size {
            case .settable:
                break
            case .notSettable:
                return .unsupported(.sizeNotSettable)
            case .unread:
                lastTransientStage = .capabilityUnavailable
                continue
            }

            guard WindowLiftAvoidance.samplesAreStable(
                initialCGFrame: candidate.quartzFrame,
                confirmedCGFrame: confirmedCGFrame,
                confirmedAXFrame: confirmedAXFrame
            ) else {
                lastTransientStage = WindowLiftAvoidance.samplesAreStable(
                    confirmedCGFrame,
                    comparedTo: candidate.quartzFrame
                ) ? .frameMismatch : .candidateMoved
                continue
            }

            // The zero-deadline pass only captures the first synchronized sample. A write may
            // start once a later (≥100ms) confirmation fully agrees with the detected frame.
            // Early-sample jitter no longer vetoes the whole round (the old behavior forced a full 0.2s
            // rescan cycle): the write loop's stall/trajectory checks can safely absorb residual movement.
            guard index > schedule.deadlines.startIndex else {
                lastTransientStage = .frameMismatch
                continue
            }
            return .ready(handle)
        }
        return .transient(lastTransientStage)
    }

    nonisolated private static func write(
        reader: AXWindowReader,
        element: AXUIElement,
        nativeFrame: CGRect,
        targetFrame: CGRect,
        animated: Bool,
        initialReliftCount: Int,
        primaryScreenHeight: CGFloat
    ) async -> OperationOutcome {
        if !animated {
            let result = reader.setSize(
                targetFrame.size,
                for: element,
                messagingTimeout: windowLiftAXMessagingTimeout,
                verificationTolerance: WindowLiftAvoidance.verificationTolerance,
                onlyIfCurrentMatches: nativeFrame,
                restoreOnFailureTo: nil
            )
            if Task.isCancelled {
                if case let .success(actualFrame) = result {
                    rollbackCancelledWrite(
                        reader: reader,
                        element: element,
                        nativeFrame: nativeFrame,
                        attemptedFrame: actualFrame
                    )
                }
                return .cancelled
            }
            switch result {
            case let .success(actualFrame):
                return completedOrRolledBack(
                    reader: reader,
                    element: element,
                    actualFrame: actualFrame,
                    nativeFrame: nativeFrame,
                    targetFrame: targetFrame,
                    reliftCount: initialReliftCount,
                    anomalies: [],
                    primaryScreenHeight: primaryScreenHeight
                )

            case let .failure(reason, rollback):
                let decision = animationFailureDecision(
                    for: reason,
                    nativeFrame: nativeFrame,
                    targetFrame: targetFrame,
                    reliftCount: initialReliftCount,
                    lastAcknowledgedFrame: nativeFrame,
                    primaryScreenHeight: primaryScreenHeight
                )
                let anomaly = WriteAnomaly(
                    reason: reason,
                    rollback: rollback,
                    decision: decision,
                    progress: 1
                )
                switch decision {
                case let .complete(actualFrame):
                    return completedOrRolledBack(
                        reader: reader,
                        element: element,
                        actualFrame: actualFrame,
                        nativeFrame: nativeFrame,
                        targetFrame: targetFrame,
                        reliftCount: initialReliftCount,
                        anomalies: [anomaly],
                        primaryScreenHeight: primaryScreenHeight
                    )
                case let .continueFromActual(actualFrame):
                    // Stall: the write may not have been applied by the window yet (late
                    // apply on 1x screens). Wait one beat and check once more; only if
                    // still not in place, clear the session and hand it to the next scan.
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    if !Task.isCancelled,
                       let settledFrame = reader.frame(
                           of: element,
                           messagingTimeout: windowLiftAXMessagingTimeout
                       ),
                       WindowLiftAvoidance.framesMatch(settledFrame, targetFrame) {
                        return .completed(settledFrame, reliftCount: initialReliftCount, anomalies: [anomaly])
                    }
                    return .externalFrame(actualFrame, anomalies: [anomaly])
                case let .clearSession(frame),
                     let .restartFromNative(frame, _):
                    // Instant mode owns exactly one AX write. A mismatch that did not mutate the
                    // window clears this attempt and lets the next CG observation start cleanly.
                    return .externalFrame(frame, anomalies: [anomaly])
                case let .reliftLimitReached(frame, count):
                    return .reliftLimitReached(
                        frame,
                        reliftCount: count,
                        anomalies: [anomaly]
                    )
                case .abandonWriteFailed:
                    return .failed(
                        reason: reason,
                        rollback: rollback,
                        progress: 1,
                        reliftCount: initialReliftCount,
                        anomalies: [anomaly]
                    )
                }
            }
        }

        let frameInterval = 1.0 / WindowLiftAvoidance.animationFramesPerSecond
        var segmentStartFrame = nativeFrame
        var segmentProgressStart = 0.0
        let animationStartedAt = ProcessInfo.processInfo.systemUptime
        var nextDeadline = animationStartedAt + frameInterval
        var expectedFrame = nativeFrame
        var reliftCount = initialReliftCount
        var anomalies: [WriteAnomaly] = []
        // The final frame allows a limited number of stall retries: on
        // slow-apply screens the write takes effect after the read-back.
        var finalStallRetries = 0
        let maxFinalStallRetries = 3

        while true {
            let now = ProcessInfo.processInfo.systemUptime
            let animationElapsed = now - animationStartedAt
            if animationElapsed >= WindowLiftAvoidance.animationDuration {
                let result = reader.setSize(
                    targetFrame.size,
                    for: element,
                    messagingTimeout: windowLiftAXMessagingTimeout,
                    verificationTolerance: WindowLiftAvoidance.verificationTolerance,
                    onlyIfCurrentMatches: expectedFrame,
                    restoreOnFailureTo: nil
                )
                if Task.isCancelled {
                    if case let .success(actualFrame) = result {
                        rollbackCancelledWrite(
                            reader: reader,
                            element: element,
                            nativeFrame: nativeFrame,
                            attemptedFrame: actualFrame
                        )
                    }
                    return .cancelled
                }
                switch result {
                case let .success(actualFrame):
                    return completedOrRolledBack(
                        reader: reader,
                        element: element,
                        actualFrame: actualFrame,
                        nativeFrame: nativeFrame,
                        targetFrame: targetFrame,
                        reliftCount: reliftCount,
                        anomalies: anomalies,
                        primaryScreenHeight: primaryScreenHeight
                    )

                case let .failure(reason, rollback):
                    let decision = animationFailureDecision(
                        for: reason,
                        nativeFrame: nativeFrame,
                        targetFrame: targetFrame,
                        reliftCount: reliftCount,
                        lastAcknowledgedFrame: expectedFrame,
                        primaryScreenHeight: primaryScreenHeight
                    )
                    switch decision {
                    case let .complete(actualFrame):
                        return completedOrRolledBack(
                            reader: reader,
                            element: element,
                            actualFrame: actualFrame,
                            nativeFrame: nativeFrame,
                            targetFrame: targetFrame,
                            reliftCount: reliftCount,
                            anomalies: anomalies,
                            primaryScreenHeight: primaryScreenHeight
                        )
                    case let .continueFromActual(actualFrame):
                        // Final frame stalled / within trajectory: wait one beat
                        // and rewrite; fail only after a limited number of tries.
                        if finalStallRetries < maxFinalStallRetries {
                            finalStallRetries += 1
                            expectedFrame = actualFrame
                            try? await Task.sleep(
                                nanoseconds: UInt64(frameInterval * 1_000_000_000)
                            )
                            continue
                        }
                        let anomaly = WriteAnomaly(
                            reason: reason,
                            rollback: rollback,
                            decision: decision,
                            progress: 1
                        )
                        recordBounded(anomaly, in: &anomalies)
                        let finalRollback = rollbackAfterAnimationFailure(
                            rollback,
                            reader: reader,
                            element: element,
                            nativeFrame: nativeFrame,
                            currentManagedFrame: actualFrame
                        )
                        return .failed(
                            reason: reason,
                            rollback: finalRollback,
                            progress: 1,
                            reliftCount: reliftCount,
                            anomalies: anomalies
                        )
                    case let .clearSession(frame):
                        recordBounded(WriteAnomaly(
                            reason: reason,
                            rollback: rollback,
                            decision: decision,
                            progress: 1
                        ), in: &anomalies)
                        return .externalFrame(frame, anomalies: anomalies)
                    case let .restartFromNative(frame, nextReliftCount):
                        recordBounded(WriteAnomaly(
                            reason: reason,
                            rollback: rollback,
                            decision: decision,
                            progress: 1
                        ), in: &anomalies)
                        let safeRollback = rollbackAfterAnimationFailure(
                            rollback,
                            reader: reader,
                            element: element,
                            nativeFrame: nativeFrame,
                            currentManagedFrame: frame
                        )
                        return .failed(
                            reason: reason,
                            rollback: safeRollback,
                            progress: 1,
                            reliftCount: nextReliftCount,
                            anomalies: anomalies
                        )
                    case let .reliftLimitReached(frame, count):
                        recordBounded(WriteAnomaly(
                            reason: reason,
                            rollback: rollback,
                            decision: decision,
                            progress: 1
                        ), in: &anomalies)
                        return .reliftLimitReached(frame, reliftCount: count, anomalies: anomalies)
                    case .abandonWriteFailed:
                        recordBounded(WriteAnomaly(
                            reason: reason,
                            rollback: rollback,
                            decision: decision,
                            progress: 1
                        ), in: &anomalies)
                        let safeRollback = rollbackAfterAnimationFailure(
                            rollback,
                            reader: reader,
                            element: element,
                            nativeFrame: nativeFrame,
                            currentManagedFrame: expectedFrame
                        )
                        return .failed(
                            reason: reason,
                            rollback: safeRollback,
                            progress: 1,
                            reliftCount: reliftCount,
                            anomalies: anomalies
                        )
                    }
                }
            }

            let sleepDuration = max(0, nextDeadline - now)
            if sleepDuration > 0 {
                try? await Task.sleep(nanoseconds: UInt64(sleepDuration * 1_000_000_000))
            }
            guard !Task.isCancelled else {
                rollbackCancelledWrite(
                    reader: reader,
                    element: element,
                    nativeFrame: nativeFrame,
                    attemptedFrame: expectedFrame
                )
                return .cancelled
            }

            let elapsed = ProcessInfo.processInfo.systemUptime - animationStartedAt
            guard elapsed < WindowLiftAvoidance.animationDuration else { continue }
            let overallProgress = max(0, elapsed / WindowLiftAvoidance.animationDuration)
            let progress = WindowLiftAvoidance.rebasedAnimationProgress(
                overallProgress,
                startingAt: segmentProgressStart
            )
            let attemptedFrame = monotonicAttemptedFrame(
                scheduled: WindowLiftAvoidance.interpolatedFrame(
                    from: segmentStartFrame,
                    to: targetFrame,
                    progress: progress
                ),
                current: expectedFrame,
                target: targetFrame
            )
            // Round the size: 1x screens can only represent whole points, so fractional
            // requests get rounded/ignored and hit the 2pt verification tolerance.
            let attemptedSize = CGSize(
                width: attemptedFrame.width.rounded(),
                height: attemptedFrame.height.rounded()
            )
            let result = reader.setSize(
                attemptedSize,
                for: element,
                messagingTimeout: windowLiftAXMessagingTimeout,
                verificationTolerance: WindowLiftAvoidance.verificationTolerance,
                onlyIfCurrentMatches: expectedFrame,
                restoreOnFailureTo: nil
            )
            if Task.isCancelled {
                if case let .success(actualFrame) = result {
                    rollbackCancelledWrite(
                        reader: reader,
                        element: element,
                        nativeFrame: nativeFrame,
                        attemptedFrame: actualFrame
                    )
                }
                return .cancelled
            }
            switch result {
            case let .success(actualFrame):
                expectedFrame = actualFrame
                guard !Task.isCancelled else {
                    rollbackCancelledWrite(
                        reader: reader,
                        element: element,
                        nativeFrame: nativeFrame,
                        attemptedFrame: actualFrame
                    )
                    return .cancelled
                }
            case let .failure(reason, rollback):
                let decision = animationFailureDecision(
                    for: reason,
                    nativeFrame: nativeFrame,
                    targetFrame: targetFrame,
                    reliftCount: reliftCount,
                    lastAcknowledgedFrame: expectedFrame,
                    primaryScreenHeight: primaryScreenHeight
                )
                if case let .continueFromActual(actualFrame) = decision {
                    // Stall or within-trajectory self-heal: not an anomaly,
                    // the schedule makes up the step on the next frame.
                    expectedFrame = actualFrame
                } else {
                    let anomaly = WriteAnomaly(
                        reason: reason,
                        rollback: rollback,
                        decision: decision,
                        progress: overallProgress
                    )
                    recordBounded(anomaly, in: &anomalies)
                    switch decision {
                    case let .complete(actualFrame):
                        return completedOrRolledBack(
                            reader: reader,
                            element: element,
                            actualFrame: actualFrame,
                            nativeFrame: nativeFrame,
                            targetFrame: targetFrame,
                            reliftCount: reliftCount,
                            anomalies: anomalies,
                            primaryScreenHeight: primaryScreenHeight
                        )
                    case .continueFromActual:
                        break
                    case let .clearSession(frame):
                        return .externalFrame(frame, anomalies: anomalies)
                    case let .restartFromNative(frame, nextReliftCount):
                        segmentStartFrame = frame
                        expectedFrame = frame
                        reliftCount = nextReliftCount
                        segmentProgressStart = overallProgress
                        continue
                    case let .reliftLimitReached(frame, count):
                        return .reliftLimitReached(frame, reliftCount: count, anomalies: anomalies)
                    case .abandonWriteFailed:
                        let safeRollback = rollbackAfterAnimationFailure(
                            rollback,
                            reader: reader,
                            element: element,
                            nativeFrame: nativeFrame,
                            currentManagedFrame: expectedFrame
                        )
                        return .failed(
                            reason: reason,
                            rollback: safeRollback,
                            progress: overallProgress,
                            reliftCount: reliftCount,
                            anomalies: anomalies
                        )
                    }
                }
            }

            let elapsedAfterWrite = max(
                0,
                ProcessInfo.processInfo.systemUptime - animationStartedAt
            )
            let completedSlots = floor(elapsedAfterWrite / frameInterval)
            nextDeadline = animationStartedAt + (completedSlots + 1) * frameInterval
        }
    }

    nonisolated private static func completedOrRolledBack(
        reader: AXWindowReader,
        element: AXUIElement,
        actualFrame: CGRect,
        nativeFrame: CGRect,
        targetFrame: CGRect,
        reliftCount: Int,
        anomalies: [WriteAnomaly],
        primaryScreenHeight: CGFloat
    ) -> OperationOutcome {
        let actualAppKit = WindowLiftAvoidance.appKitFrame(
            fromQuartz: actualFrame,
            primaryScreenHeight: primaryScreenHeight
        )
        let targetAppKit = WindowLiftAvoidance.appKitFrame(
            fromQuartz: targetFrame,
            primaryScreenHeight: primaryScreenHeight
        )
        guard !WindowLiftAvoidance.framesMatch(
            actualAppKit,
            targetAppKit,
            tolerance: WindowLiftAvoidance.verificationTolerance
        ) else {
            return .completed(actualFrame, reliftCount: reliftCount, anomalies: anomalies)
        }

        let reason = AXWindowFrameWriteFailure.verificationMismatch(
            expected: targetFrame,
            actual: actualFrame
        )
        let rollback = rollbackManagedFrame(
            reader: reader,
            element: element,
            nativeFrame: nativeFrame,
            currentFrame: actualFrame
        )
        var finalAnomalies = anomalies
        recordBounded(
            WriteAnomaly(
                reason: reason,
                rollback: rollback,
                decision: .abandonWriteFailed,
                progress: 1
            ),
            in: &finalAnomalies
        )
        return .failed(
            reason: reason,
            rollback: rollback,
            progress: 1,
            reliftCount: reliftCount,
            anomalies: finalAnomalies
        )
    }

    nonisolated private static func animationFailureDecision(
        for reason: AXWindowFrameWriteFailure,
        nativeFrame: CGRect,
        targetFrame: CGRect,
        reliftCount: Int,
        lastAcknowledgedFrame: CGRect,
        primaryScreenHeight: CGFloat
    ) -> WindowLiftAvoidance.AnimationWriteFailureDecision {
        let failure: WindowLiftAvoidance.AnimationWriteFailure
        switch reason {
        // verificationMismatch also carries the real actual: on slow-apply screens (1x external
        // displays) an immediate read-back after a write often returns the old value, and treating
        // it as terminal would always give up on the ~2pt easing step of the first frame.
        case let .initialFrameMismatch(_, actualFrame),
             let .verificationMismatch(_, actualFrame):
            failure = .initialFrameMismatch(actualFrame: WindowLiftAvoidance.appKitFrame(
                fromQuartz: actualFrame,
                primaryScreenHeight: primaryScreenHeight
            ))
        default:
            failure = .terminalWriteFailure
        }
        let appKitDecision = WindowLiftAvoidance.animationWriteFailureDecision(
            failure,
            nativeFrame: WindowLiftAvoidance.appKitFrame(
                fromQuartz: nativeFrame,
                primaryScreenHeight: primaryScreenHeight
            ),
            targetFrame: WindowLiftAvoidance.appKitFrame(
                fromQuartz: targetFrame,
                primaryScreenHeight: primaryScreenHeight
            ),
            reliftCount: reliftCount,
            lastAcknowledgedFrame: WindowLiftAvoidance.appKitFrame(
                fromQuartz: lastAcknowledgedFrame,
                primaryScreenHeight: primaryScreenHeight
            )
        )
        func quartz(_ frame: CGRect) -> CGRect {
            WindowLiftAvoidance.quartzFrame(
                fromAppKit: frame,
                primaryScreenHeight: primaryScreenHeight
            )
        }
        switch appKitDecision {
        case let .complete(frame):
            return .complete(actualFrame: quartz(frame))
        case let .continueFromActual(frame):
            return .continueFromActual(actualFrame: quartz(frame))
        case let .clearSession(frame):
            return .clearSession(preservingFrame: quartz(frame))
        case let .restartFromNative(frame, nextReliftCount):
            return .restartFromNative(
                nativeFrame: quartz(frame),
                nextReliftCount: nextReliftCount
            )
        case let .reliftLimitReached(frame, count):
            return .reliftLimitReached(
                actualFrame: quartz(frame),
                reliftCount: count
            )
        case .abandonWriteFailed:
            return .abandonWriteFailed
        }
    }

    nonisolated private static func recordBounded(
        _ anomaly: WriteAnomaly,
        in anomalies: inout [WriteAnomaly]
    ) {
        if anomalies.count < 4 {
            anomalies.append(anomaly)
        } else {
            // Keep the beginning of the episode and always preserve the newest decision/result.
            anomalies[anomalies.count - 1] = anomaly
        }
    }

    /// A recovered trajectory mismatch may already be ahead of the elapsed-time sample. Do not
    /// grow the window back toward the native frame while the schedule catches up.
    nonisolated private static func monotonicAttemptedFrame(
        scheduled: CGRect,
        current: CGRect,
        target: CGRect
    ) -> CGRect {
        func component(_ scheduled: CGFloat, _ current: CGFloat, _ target: CGFloat) -> CGFloat {
            if target < current { return max(target, min(scheduled, current)) }
            if target > current { return min(target, max(scheduled, current)) }
            return target
        }
        return CGRect(
            origin: scheduled.origin,
            size: CGSize(
                width: component(scheduled.width, current.width, target.width),
                height: component(scheduled.height, current.height, target.height)
            )
        )
    }

    nonisolated private static func rollbackManagedFrame(
        reader: AXWindowReader,
        element: AXUIElement,
        nativeFrame: CGRect,
        currentFrame: CGRect
    ) -> AXWindowFrameRollbackResult {
        switch reader.setFrame(
            nativeFrame,
            for: element,
            messagingTimeout: windowLiftAXMessagingTimeout,
            verificationTolerance: WindowLiftAvoidance.verificationTolerance,
            onlyIfCurrentMatches: currentFrame,
            restoreOnFailureTo: currentFrame
        ) {
        case let .success(actualFrame):
            return .restored(actualFrame: actualFrame)
        case let .failure(reason, _):
            return .failed(
                reason: reason,
                actualFrame: reader.frame(
                    of: element,
                    messagingTimeout: windowLiftAXMessagingTimeout
                )
            )
        }
    }

    nonisolated private static func rollbackAfterAnimationFailure(
        _ rollback: AXWindowFrameRollbackResult,
        reader: AXWindowReader,
        element: AXUIElement,
        nativeFrame: CGRect,
        currentManagedFrame: CGRect
    ) -> AXWindowFrameRollbackResult {
        guard rollback == .notRequested,
              !WindowLiftAvoidance.framesMatch(currentManagedFrame, nativeFrame) else {
            return rollback
        }
        return rollbackManagedFrame(
            reader: reader,
            element: element,
            nativeFrame: nativeFrame,
            currentFrame: currentManagedFrame
        )
    }

    nonisolated private static func rollbackCancelledWrite(
        reader: AXWindowReader,
        element: AXUIElement,
        nativeFrame: CGRect,
        attemptedFrame: CGRect
    ) {
        let currentFrame = reader.frame(of: element, messagingTimeout: windowLiftAXMessagingTimeout)
        guard case let .restore(frame) = WindowLiftAvoidance.rollbackDecision(
            originalFrame: nativeFrame,
            attemptedFrame: attemptedFrame,
            currentFrame: currentFrame
        ) else {
            return
        }
        _ = reader.setFrame(
            frame,
            for: element,
            messagingTimeout: windowLiftAXMessagingTimeout,
            verificationTolerance: WindowLiftAvoidance.verificationTolerance,
            onlyIfCurrentMatches: attemptedFrame
        )
    }

    private func canContinueOperation(
        for key: WindowLiftAvoidance.WindowKey,
        generation: UInt64,
        context: WindowLiftAvoidanceContext
    ) -> Bool {
        guard hostContexts().contains(context),
              NSRunningApplication(processIdentifier: key.pid)?.isActive == true,
              case let .writing(attempt) = states[key],
              attempt.generation == generation else {
            return false
        }
        return true
    }

    private func canBeginAXWrite(
        for key: WindowLiftAvoidance.WindowKey,
        generation: UInt64,
        context: WindowLiftAvoidanceContext
    ) -> Bool {
        guard validationGenerations[key] == generation else { return false }
        validationGenerations.removeValue(forKey: key)
        return canContinueOperation(for: key, generation: generation, context: context)
    }

    private func finishOperation(
        for key: WindowLiftAvoidance.WindowKey,
        generation: UInt64,
        outcome: OperationOutcome
    ) {
        guard canMutateSessions() else {
            // Cancelling a write task ends up here. During a freeze it must not clear the session on the way:
            // both the `.cancelled` and `.transientValidation` branches lead to clearManagedSession.
            if let writer = writeTasks.removeValue(forKey: key) { pendingDrains.append(writer) }
            return
        }
        guard case let .writing(attempt) = states[key], attempt.generation == generation else {
            return
        }
        if validationGenerations[key] == generation {
            validationGenerations.removeValue(forKey: key)
        }
        writeTasks.removeValue(forKey: key)
        let finishedAt = ProcessInfo.processInfo.systemUptime

        switch outcome {
        case .cancelled:
            clearManagedSession(for: key, cancelWriter: false, reason: "cancelled")

        case let .transientValidation(stage):
            logger.notice(
                "lift validation transient pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) stage=\(stage.rawValue, privacy: .public)"
            )
            // Validation has not written the window yet. A moving zoom candidate must return to
            // idle so the next global sample can establish a fresh native frame.
            clearManagedSession(
                for: key,
                cancelWriter: false,
                reason: stage.rawValue
            )

        case let .unsupportedValidation(stage):
            let transition = WindowLiftAvoidance.reduce(
                state: states[key] ?? .idle,
                event: .writeFailed(
                    generation: generation,
                    at: finishedAt,
                    reliftCount: attempt.reliftCount
                )
            )
            store(transition.state, for: key)
            logger.error(
                "lift validation unsupported pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) stage=\(stage.rawValue, privacy: .public)"
            )

        case let .externalFrame(actualQuartzFrame, anomalies):
            logWriteAnomalies(anomalies, for: key, terminal: false)
            if let frames = managedFrames[key] {
                let actualAppKit = WindowLiftAvoidance.appKitFrame(
                    fromQuartz: actualQuartzFrame,
                    primaryScreenHeight: frames.primaryScreenHeight
                )
                traceClassification(
                    WindowLiftAvoidance.frameClassification(
                        of: actualAppKit,
                        nativeFrame: frames.nativeAppKit,
                        targetFrame: frames.targetAppKit
                    ),
                    for: key
                )
                if traceEnabled {
                    logger.info(
                        "lift trace preserve external pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) frame=\(String(describing: actualAppKit), privacy: .public)"
                    )
                }
            }
            clearManagedSession(
                for: key,
                cancelWriter: false,
                reason: "externalFrame",
                suppressUntilNative: true
            )

        case let .reliftLimitReached(_, reliftCount, anomalies):
            logWriteAnomalies(anomalies, for: key, terminal: true)
            let transition = WindowLiftAvoidance.reduce(
                state: states[key] ?? .idle,
                event: .reliftLimitReached(
                    generation: generation,
                    at: finishedAt,
                    reliftCount: reliftCount
                )
            )
            store(transition.state, for: key)
            logger.error(
                "lift abandoned pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) reason=reliftLimitReached count=\(reliftCount, privacy: .public)"
            )

        case let .failed(reason, rollback, progress, reliftCount, anomalies):
            logWriteAnomalies(anomalies, for: key, terminal: true)
            let transition = WindowLiftAvoidance.reduce(
                state: states[key] ?? .idle,
                event: .writeFailed(
                    generation: generation,
                    at: finishedAt,
                    reliftCount: reliftCount
                )
            )
            store(transition.state, for: key)
            logger.error(
                "lift write failed pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) progress=\(progress, format: .fixed(precision: 3), privacy: .public) reason=\(String(describing: reason), privacy: .public) rollback=\(String(describing: rollback), privacy: .public)"
            )

        case let .completed(actualQuartzFrame, reliftCount, anomalies):
            logWriteAnomalies(anomalies, for: key, terminal: false)
            guard let frames = managedFrames[key] else { return }
            let actualAppKit = WindowLiftAvoidance.appKitFrame(
                fromQuartz: actualQuartzFrame,
                primaryScreenHeight: frames.primaryScreenHeight
            )
            let transition = WindowLiftAvoidance.reduce(
                state: states[key] ?? .idle,
                event: .writeFinished(
                    generation: generation,
                    at: finishedAt,
                    actualFrame: actualAppKit,
                    reliftCount: reliftCount
                )
            )
            store(transition.state, for: key)
            if reliftCount > attempt.reliftCount {
                logger.notice(
                    "lift relift completed pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) count=\(reliftCount, privacy: .public)"
                )
            }
            if !WindowLiftAvoidance.framesMatch(actualAppKit, frames.targetAppKit) {
                logger.error(
                    "lift verification mismatch pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public)"
                )
            }
        }
        updateTrackedProbeLifecycle()
    }

    private func logWriteAnomalies(
        _ anomalies: [WriteAnomaly],
        for key: WindowLiftAvoidance.WindowKey,
        terminal: Bool
    ) {
        for anomaly in anomalies.prefix(4) {
            let progress = String(format: "%.3f", anomaly.progress)
            let message = "lift animation anomaly pid=\(key.pid) wid=\(key.cgWindowID) progress=\(progress) reason=\(String(describing: anomaly.reason)) decision=\(String(describing: anomaly.decision)) rollback=\(String(describing: anomaly.rollback))"
            if terminal {
                logger.error("\(message, privacy: .public)")
            } else {
                logger.notice("\(message, privacy: .public)")
            }
        }
    }

    private func cancelWrites(except activePID: pid_t?) {
        for (key, task) in writeTasks where key.pid != activePID {
            task.cancel()
        }
    }

    private func removeStates(forPID pid: pid_t) {
        let keys = Set(states.keys).union(suppressedFrames.keys).filter { $0.pid == pid }
        for key in keys {
            clearManagedSession(for: key, cancelWriter: true, reason: "applicationTerminated")
        }
    }

    private func pruneDeadWindowStates(
        liveWindowKeys: Set<WindowLiftAvoidance.WindowKey>,
        observationGeneration: UInt64
    ) {
        let deadKeys = WindowLiftAvoidance.prunableDeadWindowKeys(
            tracked: Set(states.keys).union(suppressedFrames.keys),
            live: liveWindowKeys,
            observationGeneration: observationGeneration,
            observationWatermarks: observationWatermarks
        )
        for key in deadKeys {
            observationWatermarks[key] = observationGeneration
            clearManagedSession(for: key, cancelWriter: true, reason: "deadWindowPrune")
        }
    }

    private func restoreSettledWindowsAndClearSessions() {
        guard canMutateSessions() else { return }

        let cancelledWrites = Array(writeTasks.values) + writeDrainTasks.values.flatMap { $0 }
        for task in cancelledWrites { task.cancel() }
        writeTasks.removeAll()
        writeDrainTasks.removeAll()

        // Pending-restore data is owned by the controller from enqueue and removed
        // only once restored, so when permission is lost midway the freeze mechanism
        // can take it over and restoring continues once access is granted again.
        for (key, state) in states {
            guard let frames = managedFrames[key] else { continue }
            switch state {
            case .writing, .lifted, .abandoned:
                pendingRestorations[key] = frames
                pendingRestorationStartTimes[key] = ProcessLiveness.startTime(pid: key.pid)
            case .idle:
                break
            }
        }

        states.removeAll()
        sessionContexts.removeAll()
        managedFrames.removeAll()
        suppressedFrames.removeAll()
        observationWatermarks.removeAll()
        validationGenerations.removeAll()
        lastTraceClassifications.removeAll()
        stopTrackedProbe()
        guard !pendingRestorations.isEmpty || !cancelledWrites.isEmpty, restoreTask == nil else {
            updatePollTimerLifecycle()
            return
        }

        restoreGeneration &+= 1
        let generation = restoreGeneration
        let items = pendingRestorations
        let startTimes = pendingRestorationStartTimes
        restoreTask = Task.detached { [weak self] in
            // A cancelled AX call cannot be interrupted mid-message. Drain every old writer before
            // allowing the next context to scan, so a late rollback cannot overwrite a new lift.
            for task in cancelledWrites {
                await task.value
            }

            let reader = AXWindowReader()
            let liveWindowKeys = WindowLiftCGWindowProbe.liveWindowKeys()
            for (key, frames) in items {
                guard !Task.isCancelled else { break }
                let outcome = Self.restoreOne(
                    key: key,
                    frames: frames,
                    expectedStartTime: startTimes[key],
                    reader: reader,
                    liveWindowKeys: liveWindowKeys
                )
                guard outcome == .handled else { continue }
                await MainActor.run { [weak self] in
                    self?.pendingRestorations.removeValue(forKey: key)
                    self?.pendingRestorationStartTimes.removeValue(forKey: key)
                }
            }
            await MainActor.run { [weak self] in
                guard let self, self.restoreGeneration == generation else { return }
                self.restoreTask = nil
                self.updatePollTimerLifecycle()
                if self.isEnabled { self.poll() }
            }
        }
        updatePollTimerLifecycle()
    }

    /// Restoring only after a long freeze, anything may have changed in between, so every item
    /// is re-verified: was the process replaced (pid reuse), does the window still exist
    /// (cgWindowID reuse), did the user move it. On any mismatch, discard; never force a change.
    nonisolated private static func restoreOne(
        key: WindowLiftAvoidance.WindowKey,
        frames: ManagedFrames,
        expectedStartTime: timeval?,
        reader: AXWindowReader,
        liveWindowKeys: Set<WindowLiftAvoidance.WindowKey>?
    ) -> RestoreOutcome {
        if let expected = expectedStartTime {
            guard let current = ProcessLiveness.startTime(pid: key.pid),
                  current.tv_sec == expected.tv_sec,
                  current.tv_usec == expected.tv_usec else {
                return .handled
            }
        }
        if liveWindowKeys?.contains(key) == false { return .handled }

        guard let handle = reader.captureHandle(
                  forPID: key.pid,
                  cgWindowID: key.cgWindowID,
                  messagingTimeout: windowLiftAXMessagingTimeout
              ),
              let currentAXFrame = reader.frame(
                  of: handle.element,
                  messagingTimeout: windowLiftAXMessagingTimeout
              ) else {
            // Most likely Accessibility permission not granted
            // yet. Keep it queued and restore once access returns.
            return .unreachable
        }

        let currentAppKitFrame = WindowLiftAvoidance.appKitFrame(
            fromQuartz: currentAXFrame,
            primaryScreenHeight: frames.primaryScreenHeight
        )
        switch WindowLiftAvoidance.frameClassification(
            of: currentAppKitFrame,
            nativeFrame: frames.nativeAppKit,
            targetFrame: frames.targetAppKit
        ) {
        case .target, .managedTrajectory:
            break
        case .native, .external:
            return .handled
        }

        _ = reader.setFrame(
            frames.nativeQuartz,
            for: handle.element,
            messagingTimeout: windowLiftAXMessagingTimeout,
            verificationTolerance: WindowLiftAvoidance.verificationTolerance,
            onlyIfCurrentMatches: currentAXFrame,
            restoreOnFailureTo: currentAXFrame
        )
        return .handled
    }

    private func store(
        _ state: WindowLiftAvoidance.SessionState,
        for key: WindowLiftAvoidance.WindowKey
    ) {
        let previous = states[key] ?? .idle
        if state == .idle {
            states.removeValue(forKey: key)
            lastTraceClassifications.removeValue(forKey: key)
        } else {
            states[key] = state
        }
        if traceEnabled, traceLabel(for: previous) != traceLabel(for: state) {
            let previousLabel = traceLabel(for: previous)
            let stateLabel = traceLabel(for: state)
            logger.info(
                "lift trace transition pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) from=\(previousLabel, privacy: .public) to=\(stateLabel, privacy: .public)"
            )
        }
        updateTrackedProbeLifecycle()
        updatePollTimerLifecycle()
    }

    private func clearManagedSession(
        for key: WindowLiftAvoidance.WindowKey,
        cancelWriter: Bool,
        reason: String,
        suppressUntilNative: Bool = false
    ) {
        guard canMutateSessions() else {
            // During a freeze only task references are dropped; session data is left untouched.
            if let writer = writeTasks.removeValue(forKey: key) {
                if cancelWriter { writer.cancel() }
                pendingDrains.append(writer)
            }
            return
        }
        if cancelWriter, let writer = writeTasks.removeValue(forKey: key) {
            writer.cancel()
            writeDrainTasks[key, default: []].append(writer)
        } else {
            writeTasks.removeValue(forKey: key)
        }
        observationWatermarks[key] = max(
            observationWatermarks[key] ?? 0,
            nextGeneration
        )
        validationGenerations.removeValue(forKey: key)
        let previous = states.removeValue(forKey: key)
        let frames = managedFrames.removeValue(forKey: key)
        if suppressUntilNative, let frames {
            suppressedFrames[key] = frames
        } else {
            suppressedFrames.removeValue(forKey: key)
        }
        lastTraceClassifications.removeValue(forKey: key)
        if traceEnabled, previous != nil {
            logger.info(
                "lift trace clear pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) reason=\(reason, privacy: .public)"
            )
        }
        updateTrackedProbeLifecycle()
        updatePollTimerLifecycle()
    }

    private func traceClassification(
        _ classification: WindowLiftAvoidance.FrameClassification,
        for key: WindowLiftAvoidance.WindowKey
    ) {
        guard traceEnabled, lastTraceClassifications[key] != classification else { return }
        lastTraceClassifications[key] = classification
        logger.info(
            "lift trace classify pid=\(key.pid, privacy: .public) wid=\(key.cgWindowID, privacy: .public) frame=\(String(describing: classification), privacy: .public)"
        )
    }

    private func traceLabel(for state: WindowLiftAvoidance.SessionState) -> String {
        switch state {
        case .idle:
            return "idle"
        case let .writing(attempt):
            return "writing(reliftCount:\(attempt.reliftCount))"
        case let .lifted(session):
            return "lifted(reliftCount:\(session.reliftCount))"
        case let .abandoned(session):
            return "abandoned(reason:\(String(describing: session.reason)),reliftCount:\(session.reliftCount))"
        }
    }
}
