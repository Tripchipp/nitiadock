import AppKit
import ApplicationServices
import Foundation
import OSLog
import os.lock

/// SkyLight Space layout reader. A single `SLSCopyManagedDisplaySpaces` was measured at about 0.132ms,
/// cheap enough for the event path; here it is read only on Space/screen changes, far less often.
///
/// **Displays must be matched by the `CGDisplayCreateUUIDFromDisplayID` UUID, not by array order**
/// (the order is unstable with multiple displays).
/// (The "always on all desktops" membership fix in `PanelCoordinator` is a second consumer, hence no longer
/// private.)
enum ManagedSpaceLayoutReader {
    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias CopySpacesFn = @convention(c) (Int32) -> CFArray?

    private static let symbols: (cid: Int32, copy: CopySpacesFn)? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        ),
            let cidSym = dlsym(handle, "SLSMainConnectionID"),
            let copySym = dlsym(handle, "SLSCopyManagedDisplaySpaces")
        else { return nil }
        let cid = unsafeBitCast(cidSym, to: MainConnectionIDFn.self)()
        return (cid, unsafeBitCast(copySym, to: CopySpacesFn.self))
    }()

    // The same NSScreen->UUID logic also exists in `DisplayIdentity.uuidString(for:)` (for pinning to a
    // display); this file's details are frozen by a project rule and the implementation is deliberately not
    // shared, so when changing one side check the other.
    static func displayUUIDString(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else { return nil }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value))
        else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String?
    }

    static func layout(forDisplayUUID uuid: String) -> SpaceLayoutSnapshot? {
        guard let symbols,
              let displays = symbols.copy(symbols.cid) as? [[String: Any]] else { return nil }
        for display in displays {
            guard display["Display Identifier"] as? String == uuid,
                  let spaces = display["Spaces"] as? [[String: Any]],
                  let current = display["Current Space"] as? [String: Any],
                  let currentID = spaceID(current) else { continue }
            var ordered: [Int] = []
            var fullscreen: Set<Int> = []
            for space in spaces {
                guard let id = spaceID(space) else { continue }
                ordered.append(id)
                if space["type"] as? Int == SpaceLayoutSnapshot.fullscreenSpaceType {
                    fullscreen.insert(id)
                }
            }
            guard !ordered.isEmpty else { return nil }
            return SpaceLayoutSnapshot(
                orderedSpaceIDs: ordered,
                fullscreenSpaceIDs: fullscreen,
                currentSpaceID: currentID
            )
        }
        return nil
    }

    private static func spaceID(_ dict: [String: Any]) -> Int? {
        (dict["ManagedSpaceID"] as? Int) ?? (dict["id64"] as? Int)
    }
}

/// "Which Spaces this window belongs to now". The issue #19 fix uses it to read back and verify: assigning
/// `collectionBehavior` once does not guarantee success, and without reading back there is no way to know
/// whether the fix took.
///
/// selector `0x7` = all Spaces (same as Dock / WindowServer use internally). Cost is on the order of
/// `SLSCopyManagedDisplaySpaces` (measured 0.132ms per call); called only on panel show/hide and
/// Space switches, not on the event path.
enum WindowSpaceMembershipReader {
    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> CFArray?

    private static let symbols: (cid: Int32, copy: CopySpacesForWindowsFn)? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        ),
            let cidSym = dlsym(handle, "SLSMainConnectionID"),
            let copySym = dlsym(handle, "SLSCopySpacesForWindows")
        else { return nil }
        let cid = unsafeBitCast(cidSym, to: MainConnectionIDFn.self)()
        return (cid, unsafeBitCast(copySym, to: CopySpacesForWindowsFn.self))
    }()

    /// Returns nil when unreadable (missing symbol / invalid window number). Callers must treat that as
    /// "unknown", not "belongs to no Space", otherwise one failed read triggers a pointless repair round.
    static func spaceIDs(forWindowNumber windowNumber: Int) -> [Int]? {
        guard windowNumber > 0, let symbols else { return nil }
        guard let raw = symbols.copy(
            symbols.cid,
            0x7,
            [NSNumber(value: windowNumber)] as CFArray
        ) as? [NSNumber] else { return nil }
        return raw.map(\.intValue)
    }
}

private final class FullscreenIntentAtomicState {
    private var lock = os_unfair_lock_s()
    private var snapshot: FullscreenIntentSnapshot?
    private var spaceLayouts: SpaceLayoutDirectory?
    private var naturalScrolling = true
    private var tapEnabled = false

    func currentSnapshot() -> FullscreenIntentSnapshot? {
        withLock { tapEnabled ? snapshot : nil }
    }

    /// Event-thread read: nil means "no display has a fullscreen Space on either side" and the caller can
    /// skip outright, without even converting to `NSEvent`. Gesture events arrive at two hundred per second,
    /// so this early exit is the normal path.
    func currentSpaceContext() -> (layouts: SpaceLayoutDirectory, naturalScrolling: Bool)? {
        withLock {
            guard tapEnabled, let spaceLayouts, spaceLayouts.hasAnyFullscreenNeighbor else {
                return nil
            }
            return (spaceLayouts, naturalScrolling)
        }
    }

    func replaceSpaceLayout(_ value: SpaceLayoutDirectory?, naturalScrolling: Bool) {
        withLock {
            spaceLayouts = value
            self.naturalScrolling = naturalScrolling
        }
    }

    func replaceSnapshot(_ value: FullscreenIntentSnapshot?) {
        withLock { snapshot = value }
    }

    func updatePanelScreens(_ frames: [CGRect]) {
        withLock {
            guard let current = snapshot else { return }
            snapshot = FullscreenIntentSnapshot(
                generation: current.generation,
                pid: current.pid,
                focusedWindowID: current.focusedWindowID,
                buttonFrame: current.buttonFrame,
                windowFrame: current.windowFrame,
                screenCGFrame: current.screenCGFrame,
                panelScreenCGFrames: frames,
                isFullscreen: current.isFullscreen,
                buttonEnabled: current.buttonEnabled
            )
        }
    }

    func setTapEnabled(_ enabled: Bool) {
        withLock { tapEnabled = enabled }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return body()
    }
}

private final class FullscreenIntentEventBridge {
    private static let handoffTimeout: DispatchTimeInterval = .milliseconds(150)

    /// Raw values of the gesture event types (`CGEventType` has no named cases, but the tap mask is indexed
    /// by raw value). From `NSEvent.EventType`: gesture 29 / magnify 30 / swipe 31 / smartMagnify 32 /
    /// rotate 18 / beginGesture 19 / endGesture 20.
    static let gestureEventRawValues: [UInt32] = [18, 19, 20, 29, 30, 31, 32]
    private static let gestureEventTypes = Set(gestureEventRawValues)

    private let state: FullscreenIntentAtomicState
    private let logger: Logger
    private let onIntent: (FullscreenIntentRequest) -> Void
    private let onSpaceSwitchIntent: (SpaceSwitchDirection, _ displayUUID: String) -> Void
    private let onGestureSample: (CGEvent) -> Void
    private let spaceSwitchEnabled: Bool
    private var gestureHopLock = os_unfair_lock_s()
    private var gestureHopInFlight = false
    /// Gesture diagnostics under `DOCK_SPACE_INTENT_TRACE=1`: reports where events went once every 60 gesture
    /// events, so two hundred log lines per second do not slow the event thread. Off by default, zero cost.
    private static let traceEnabled =
        DebugSwitch.spaceIntentTrace.isEnabled(in: ProcessInfo.processInfo.environment)
    private var gestureSeen: UInt64 = 0
    private var traceCounts: [String: Int] = [:]

    private func trace(_ outcome: String) {
        guard Self.traceEnabled else { return }
        traceCounts[outcome, default: 0] += 1
        guard gestureSeen % 60 == 0 else { return }
        let summary = traceCounts.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        logger.notice("[space-trace] seen=\(self.gestureSeen, privacy: .public) \(summary, privacy: .public)")
    }

    init(
        state: FullscreenIntentAtomicState,
        logger: Logger,
        spaceSwitchEnabled: Bool,
        onIntent: @escaping (FullscreenIntentRequest) -> Void,
        onSpaceSwitchIntent: @escaping (SpaceSwitchDirection, _ displayUUID: String) -> Void,
        onGestureSample: @escaping (CGEvent) -> Void
    ) {
        self.state = state
        self.logger = logger
        self.spaceSwitchEnabled = spaceSwitchEnabled
        self.onIntent = onIntent
        self.onSpaceSwitchIntent = onSpaceSwitchIntent
        self.onGestureSample = onGestureSample
    }

    func handle(type: CGEventType, event: CGEvent) {
        let request: FullscreenIntentRequest?
        switch type {
        case .leftMouseDown:
            request = FullscreenIntentDecision.greenButtonRequest(
                location: event.location,
                flags: event.flags,
                snapshot: state.currentSnapshot()
            )
        case .keyDown:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            // Check the Space switch first: it does not depend on the AX snapshot (whether the frontmost
            // window can go fullscreen is irrelevant when switching Spaces), while shortcutRequest returns
            // nil without a snapshot.
            if spaceSwitchEnabled,
               let direction = FullscreenSpaceSwitchDecision.arrowDirection(
                   keyCode: keyCode,
                   flags: event.flags,
                   isRepeat: isRepeat
               ) {
                handleSpaceSwitch(direction: direction, label: "arrow")
                return
            }
            request = FullscreenIntentDecision.shortcutRequest(
                keyCode: keyCode,
                flags: event.flags,
                isRepeat: isRepeat,
                snapshot: state.currentSnapshot()
            )
        default:
            if spaceSwitchEnabled, Self.gestureEventTypes.contains(type.rawValue) {
                handleGesture(event)
            }
            request = nil
        }
        guard let request else { return }
        performHandoff(label: request.source.rawValue, pid: request.pid) { [weak self] in
            self?.onIntent(request)
        }
    }

    /// The three-finger horizontal swipe does only two things: exit early, and hand the event to the main
    /// thread **asynchronously**.
    ///
    /// **Touch points are readable only from an NSEvent built from the CGEvent on the main thread**
    /// (controlled measurement 2026-08-09: on the event thread `allTouches()` / `touches(matching:)` were
    /// both empty 780/780, and an NSEvent built on the event thread and read on the main thread is empty too;
    /// only a fresh `NSEvent(cgEvent:)` on the main thread has data).
    ///
    /// This can be async and need not block input like the green-button path: the three-finger swipe leads
    /// the Space switch by about `950–1130ms`, so a few milliseconds of thread hop do not matter. An
    /// in-flight flag coalesces: with fingers on the trackpad gesture events arrive at about 200 per second,
    /// and posting them all to the main thread is both unnecessary (the criteria need only tens of
    /// milliseconds of travel) and would swamp it.
    private func handleGesture(_ event: CGEvent) {
        gestureSeen &+= 1
        guard state.currentSpaceContext() != nil else {
            trace("no-space-context")
            return
        }
        var shouldHop = false
        os_unfair_lock_lock(&gestureHopLock)
        if !gestureHopInFlight {
            gestureHopInFlight = true
            shouldHop = true
        }
        os_unfair_lock_unlock(&gestureHopLock)
        guard shouldHop else {
            trace("coalesced")
            return
        }
        guard let copy = event.copy() else {
            finishGestureHop()
            return
        }
        trace("hop")
        onGestureSample(copy)
    }

    func finishGestureHop() {
        os_unfair_lock_lock(&gestureHopLock)
        gestureHopInFlight = false
        os_unfair_lock_unlock(&gestureHopLock)
    }

    private func handleSpaceSwitch(direction: SpaceSwitchDirection, label: String) {
        // The event thread only applies the union gate (some display has a fullscreen Space in that
        // direction); which display it lands on is decided in the main-thread handoff
        // (the keyboard-focus display cannot be read; with several candidates take the one under the mouse).
        guard let context = state.currentSpaceContext(),
              !context.layouts.displays(withFullscreenNeighbor: direction).isEmpty else {
            return
        }
        performHandoff(label: label, pid: nil) { [weak self] in
            guard let self else { return }
            let target = self.state.currentSpaceContext()?.layouts
                .arrowTarget(direction, mouseLocation: NSEvent.mouseLocation)
            guard let target else { return }
            self.onSpaceSwitchIntent(direction, target.displayUUID)
        }
    }

    /// The only main-thread handoff after a hit: a bounded **synchronous** wait, the original input is
    /// released only once `orderOut` has completed. This is the only timing condition measured to work and
    /// must not become `main.async`. After a timeout the late block is turned into a no-op by
    /// `FullscreenIntentHandoffGate` and the input passes through as is (degrading to today's flicker).
    private func performHandoff(label: String, pid: pid_t?, _ body: @escaping () -> Void) {
        let gate = FullscreenIntentHandoffGate()
        let completion = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            guard gate.beginExecution() else {
                completion.signal()
                return
            }
            body()
            gate.complete()
            completion.signal()
        }

        if completion.wait(timeout: .now() + Self.handoffTimeout) == .timedOut {
            let cancelled = gate.cancelIfPending()
            logger.error(
                "handoff-timeout source=\(label, privacy: .public) pid=\(pid ?? -1, privacy: .public) cancelled=\(cancelled, privacy: .public)"
            )
        }
    }
}

private final class FullscreenIntentEventTapThread {
    private let logger: Logger
    private let bridge: FullscreenIntentEventBridge
    private let atomicState: FullscreenIntentAtomicState
    private var lifecycleLock = os_unfair_lock_s()
    private var recoveryLock = os_unfair_lock_s()
    private var recoveryPolicy = FullscreenEventTapRecoveryPolicy()
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var stopping = false
    private let finished = DispatchSemaphore(value: 0)

    init(
        logger: Logger,
        bridge: FullscreenIntentEventBridge,
        atomicState: FullscreenIntentAtomicState
    ) {
        self.logger = logger
        self.bridge = bridge
        self.atomicState = atomicState
    }

    func start() {
        withLifecycleLock {
            guard thread == nil else { return }
            stopping = false
            let thread = Thread { [weak self] in self?.run() }
            thread.name = "no.thilip.nitiadock.fullscreen-intent-tap"
            thread.qualityOfService = .userInteractive
            self.thread = thread
            thread.start()
        }
    }

    func stop() {
        atomicState.setTapEnabled(false)
        let loop: CFRunLoop? = withLifecycleLock {
            stopping = true
            return runLoop
        }
        if let loop {
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
                guard let self else { return }
                if let tap = self.withLifecycleLock({ self.tap }) {
                    CGEvent.tapEnable(tap: tap, enable: false)
                    CFMachPortInvalidate(tap)
                }
                CFRunLoopStop(loop)
            }
            CFRunLoopWakeUp(loop)
            _ = finished.wait(timeout: .now() + 1)
        }
        withLifecycleLock {
            thread = nil
            runLoop = nil
            tap = nil
        }
    }

    private func run() {
        autoreleasepool {
            var mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
                | (CGEventMask(1) << CGEventType.keyDown.rawValue)
            // Three-finger swipe Space switches need gesture events; the mask is indexed by raw event value,
            // CGEventType has no named cases.
            for raw in FullscreenIntentEventBridge.gestureEventRawValues {
                mask |= (CGEventMask(1) << CGEventMask(raw))
            }
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: Self.callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                logger.error("event-tap-create-failed")
                finished.signal()
                return
            }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            let currentLoop = CFRunLoopGetCurrent()
            let shouldStop = withLifecycleLock {
                self.tap = tap
                runLoop = currentLoop
                return stopping
            }
            guard !shouldStop else {
                CFMachPortInvalidate(tap)
                finished.signal()
                return
            }
            CFRunLoopAddSource(currentLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            atomicState.setTapEnabled(true)
            CFRunLoopRun()
            atomicState.setTapEnabled(false)
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            finished.signal()
        }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let owner = Unmanaged<FullscreenIntentEventTapThread>.fromOpaque(userInfo).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            owner.handleDisabled(type: type)
        } else {
            owner.bridge.handle(type: type, event: event)
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleDisabled(type: CGEventType) {
        let now = ProcessInfo.processInfo.systemUptime
        let shouldReenable: Bool = withRecoveryLock {
            recoveryPolicy.recordDisable(at: now)
        }
        guard shouldReenable, let tap = withLifecycleLock({ self.tap }) else {
            atomicState.setTapEnabled(false)
            logger.fault("event-tap-fused type=\(type.rawValue, privacy: .public)")
            scheduleFuseRecovery()
            return
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        atomicState.setTapEnabled(true)
        logger.error("event-tap-reenabled type=\(type.rawValue, privacy: .public)")
    }

    /// A fused tap is given another chance after a cool-down instead of staying off for the session.
    private func scheduleFuseRecovery() {
        let delay = FullscreenEventTapRecoveryPolicy.fuseCoolDown
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let rearmed: Bool = self.withRecoveryLock { self.recoveryPolicy.rearmAfterCoolDown() }
            guard rearmed, let tap = self.withLifecycleLock({ self.tap }) else { return }
            CGEvent.tapEnable(tap: tap, enable: true)
            self.atomicState.setTapEnabled(true)
            self.logger.error("event-tap-rearmed-after-cooldown")
        }
    }

    private func withLifecycleLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&lifecycleLock)
        defer { os_unfair_lock_unlock(&lifecycleLock) }
        return body()
    }

    private func withRecoveryLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&recoveryLock)
        defer { os_unfair_lock_unlock(&recoveryLock) }
        return body()
    }
}

@MainActor
final class FullscreenIntentMonitor {
    enum ContextChange {
        case activeApplication(pid_t?)
        case focusedWindow
        case windowDestroyed(CGWindowID?)
    }

    /// `AXUIElement` is an immutable CF handle, safe to pass across threads; `@unchecked` only supplies the
    /// Sendable that ApplicationServices did not declare.
    private struct AXReadResult: @unchecked Sendable {
        let element: AXUIElement
        let pid: pid_t
        let windowID: CGWindowID
        let buttonFrame: CGRect
        let windowFrame: CGRect
        let screenCGFrame: CGRect
        let isFullscreen: Bool
        let buttonEnabled: Bool
    }

    private let logger = Logger(
        subsystem: "no.thilip.nitiadock",
        category: "FullscreenIntent"
    )
    private let atomicState = FullscreenIntentAtomicState()
    private let onIntent: (FullscreenIntentRequest) -> Void
    /// Direction + UUID of the display to hide predictively (Space switches happen per display).
    private let onSpaceSwitchIntent: (SpaceSwitchDirection, _ displayUUID: String) -> Void
    private let onContextChange: (ContextChange) -> Void
    private let spaceSwitchEnabled: Bool
    private lazy var bridge = FullscreenIntentEventBridge(
        state: atomicState,
        logger: logger,
        spaceSwitchEnabled: spaceSwitchEnabled,
        onIntent: { [weak self] request in self?.accept(request) },
        onSpaceSwitchIntent: { [weak self] direction, displayUUID in
            guard let self, self.started else { return }
            self.onSpaceSwitchIntent(direction, displayUUID)
        },
        onGestureSample: { [weak self] event in
            // Touch points are readable only from an NSEvent built on the main thread (see the comment on
            // handleGesture).
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.processGestureSample(event) }
            }
        }
    )
    private lazy var tapThread = FullscreenIntentEventTapThread(
        logger: logger,
        bridge: bridge,
        atomicState: atomicState
    )

    private var workspaceActivationObserver: NSObjectProtocol?
    private var axObserver: AXObserver?
    /// AXObserver add/remove notification calls are cross-process mach round-trips that block until the
    /// observed app answers. Registering on the main thread on an app switch (restoring a minimized
    /// window activates its app) hit the app while it was still finishing the un-minimize and parked
    /// the main thread ~200ms, delaying the taskbar's own rendering (measured 2026-09-13; this monitor was
    /// the second offender after `FrontmostWindowGeometryObserver`). Only the blocking IPC moves here;
    /// observer creation, the run-loop source, and all `@MainActor` bookkeeping stay on main. Serial so
    /// per-observer registration order is preserved. Callbacks still fire on the main run loop.
    nonisolated private static let axRegistrationQueue = DispatchQueue(
        label: "no.thilip.nitiadock.fullscreen-intent-ax-registration"
    )
    private var appElement: AXUIElement?
    private var focusedElement: AXUIElement?
    private var focusedWindowID: CGWindowID?
    private var activePID: pid_t?
    /// CG frames of the displays that have a taskbar (several under ③④). **Cannot be a `Set<CGRect>`**:
    /// `CGRect`'s `Hashable` conformance is macOS 15+ and segfaults at runtime on older systems (project
    /// rule).
    private var panelScreenCGFrames: [CGRect] = []
    private var observationGeneration: UInt64 = 0
    private var cacheGeneration: UInt64 = 0
    private var refreshCoalescer = FullscreenIntentRefreshCoalescer()
    /// Read and written on the main thread only (`processGestureSample`).
    private var swipeTracker = SpaceSwipeTracker()
    private var spaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var started = false

    init(
        spaceSwitchEnabled: Bool = DebugSwitch.spaceIntent.isEnabled(in: ProcessInfo.processInfo.environment),
        onIntent: @escaping (FullscreenIntentRequest) -> Void,
        onSpaceSwitchIntent: @escaping (SpaceSwitchDirection, _ displayUUID: String) -> Void,
        onContextChange: @escaping (ContextChange) -> Void
    ) {
        self.spaceSwitchEnabled = spaceSwitchEnabled
        self.onIntent = onIntent
        self.onSpaceSwitchIntent = onSpaceSwitchIntent
        self.onContextChange = onContextChange
    }

    /// Space layout snapshot: reread only on Space switches / screen parameter changes (about 0.132ms per
    /// display). The event thread only reads the cache and never calls SkyLight in the tap callback. **Read
    /// for all displays** (not just those with a taskbar): Space switches happen per display and prediction
    /// must first locate that display; matched by UUID, not by array order.
    func refreshSpaceLayout() {
        guard started, spaceSwitchEnabled else { return }
        let natural = UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection")
            .map { ($0 as? Bool) ?? true } ?? true
        let entries: [SpaceLayoutDirectory.Entry] = NSScreen.screens.compactMap { screen in
            guard let uuid = ManagedSpaceLayoutReader.displayUUIDString(for: screen),
                  let layout = ManagedSpaceLayoutReader.layout(forDisplayUUID: uuid) else { return nil }
            return SpaceLayoutDirectory.Entry(displayUUID: uuid, appKitFrame: screen.frame, layout: layout)
        }
        atomicState.replaceSpaceLayout(
            entries.isEmpty ? nil : SpaceLayoutDirectory(entries: entries),
            naturalScrolling: natural
        )
    }

    func start() {
        guard !started else { return }
        started = true
        let center = NSWorkspace.shared.notificationCenter
        workspaceActivationObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier
            Task { @MainActor [weak self] in self?.activate(pid: pid) }
        }
        spaceObserver = center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // The Space just switched: the deceleration tail of the same swipe is still delivering
                // gesture events, so clear the state machine and do not let the aftermath form a new
                // sequence.
                self.swipeTracker.reset()
                self.refreshSpaceLayout()
                // A fullscreen Space's position in the Space order takes ~420ms to settle (measured [1 3 4
                // F]->[1 F 3 4]), so the layout read at the moment of the switch can close the gate in both
                // directions. Under fast repeated swipes this shows up as "one failed pair (flicker on entry
                // + late on exit), then self-heals" (measured 2026-08-31). Refresh once more after 0.6s so
                // the dirty snapshot heals before the next swipe. Extra refreshes are harmless (0.132ms each,
                // idempotent).
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    self?.refreshSpaceLayout()
                }
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshSpaceLayout() }
        }
        tapThread.start()
        let initialPID = NSWorkspace.shared.runningApplications.first(where: { $0.isActive })?.processIdentifier
        activate(pid: initialPID)
        refreshSpaceLayout()
    }

    func stop() {
        guard started else { return }
        started = false
        observationGeneration &+= 1
        cacheGeneration &+= 1
        refreshCoalescer.reset()
        atomicState.replaceSnapshot(nil)
        atomicState.replaceSpaceLayout(nil, naturalScrolling: true)
        let center = NSWorkspace.shared.notificationCenter
        if let observer = workspaceActivationObserver {
            center.removeObserver(observer)
            workspaceActivationObserver = nil
        }
        if let observer = spaceObserver {
            center.removeObserver(observer)
            spaceObserver = nil
        }
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
            screenObserver = nil
        }
        stopAXObservation()
        tapThread.stop()
    }

    /// The orchestration layer feeds in all displays with a taskbar after any unit changes display or units
    /// are created/torn down. No-op when unchanged.
    func updatePanelScreens(_ frames: [CGRect]) {
        guard frames != panelScreenCGFrames else { return }
        panelScreenCGFrames = frames
        atomicState.updatePanelScreens(frames)
    }

    private static let mainTraceEnabled =
        DebugSwitch.spaceIntentTrace.isEnabled(in: ProcessInfo.processInfo.environment)
    private var mainTraceSeen: UInt64 = 0
    private var mainTraceCounts: [String: Int] = [:]

    private func mainTrace(_ outcome: String) {
        guard Self.mainTraceEnabled else { return }
        mainTraceSeen &+= 1
        mainTraceCounts[outcome, default: 0] += 1
        guard mainTraceSeen % 60 == 0 else { return }
        let summary = mainTraceCounts.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        logger.notice("[space-main] seen=\(self.mainTraceSeen, privacy: .public) \(summary, privacy: .public)")
    }

    /// Main-thread side of the three-finger decision: build an NSEvent, read the touch points, feed the pure
    /// state machine, pass the adjacent-Space gate. Must be on the main thread; an NSEvent built on the event
    /// thread has no readable touch points (controlled measurement).
    private func processGestureSample(_ event: CGEvent) {
        defer { bridge.finishGestureHop() }
        guard started, spaceSwitchEnabled else { return mainTrace("not-started") }
        guard let context = atomicState.currentSpaceContext() else {
            return mainTrace("no-context")
        }
        guard let ns = NSEvent(cgEvent: event) else { return mainTrace("nsevent-nil") }
        // **`NSTouch.Phase.touching` is a composite value (began|moved|stationary) and must be tested by
        // intersection.** `phase.contains(.touching)` requires a single touch to be in all three states at
        // once, which never holds. Measured 2026-08-09: `allTouches()` clearly returned 3 touches, the filter
        // always left 0, and the feature never triggered. The standalone probe used `touches(matching:)`,
        // which intersects internally, so it did not expose the bug.
        let all = ns.allTouches()
        let touching = all.filter { !$0.phase.intersection(.touching).isEmpty }
        mainTrace("all=\(all.count) touching=\(touching.count)")
        // About a third of gesture events carry no touch data (magnify and the like): just skip them, **do
        // not treat them as "fingers lifted" and reset the state machine**, otherwise a swipe is interrupted
        // over and over. The end of a sequence is left to the time-interval check in `SpaceSwipeTracker`.
        guard !touching.isEmpty else { return }
        let xs = touching.map { $0.normalizedPosition.x }
        let ys = touching.map { $0.normalizedPosition.y }
        guard let direction = swipeTracker.consume(
            touches: touching.count,
            x: xs.reduce(0, +) / Double(xs.count),
            y: ys.reduce(0, +) / Double(ys.count),
            at: ProcessInfo.processInfo.systemUptime,
            naturalScrolling: context.naturalScrolling
        ) else { return }
        // A three-finger swipe acts on the display under the cursor: locate that display's layout first, then
        // check the adjacent Space.
        let mouse = NSEvent.mouseLocation
        guard let entry = context.layouts.entry(containing: mouse) else {
            return mainTrace("no-display-under-mouse")
        }
        var open = entry.layout.neighborIsFullscreen(direction)
        if !open {
            // A closed gate may just be a dirty cache: for ~420ms after a Space switch SkyLight is still
            // reordering Spaces, and the layout cached at the moment of the switch can close the gate wrongly
            // (measured 2026-08-31). Reread the true value once on the spot and decide again: 0.132ms, main
            // thread, at most once per gesture sequence. Still closed means there really is nothing to
            // predict. Tried and reverted: a 250ms deferred recheck that sends a late prediction. Late
            // predictions for noise gestures get sent too, hiding the bar on the desktop for no reason, so
            // flicker went up, not down. Missing the prediction for a gesture that starts inside the dirty
            // window is an accepted limit (not hit at a normal pace).
            refreshSpaceLayout()
            open = atomicState.currentSpaceContext()?.layouts
                .entry(forDisplayUUID: entry.displayUUID)?.layout
                .neighborIsFullscreen(direction) ?? false
        }
        guard open else {
            mainTrace("gate-closed-\(direction.rawValue)")
            return
        }
        logger.notice("space-swipe direction=\(direction.rawValue, privacy: .public)")
        onSpaceSwitchIntent(direction, entry.displayUUID)
    }

    private func accept(_ request: FullscreenIntentRequest) {
        guard FullscreenIntentCacheDecision.isCurrentRequest(
            request,
            snapshot: atomicState.currentSnapshot(),
            activePID: activePID,
            started: started
        ) else {
            return
        }
        onIntent(request)
    }

    private func activate(pid: pid_t?) {
        guard activePID != pid || axObserver == nil else { return }
        activePID = pid
        observationGeneration &+= 1
        cacheGeneration &+= 1
        atomicState.replaceSnapshot(nil)
        stopAXObservation()
        onContextChange(.activeApplication(pid))
        guard let pid else { return }
        // Our own windows are never fullscreen, and AX against our own process is answered
        // in-process on the calling thread: the background reads below would run AppKit off main.
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }

        var observer: AXObserver?
        guard AXObserverCreate(pid, Self.axCallback, &observer) == .success,
              let observer else {
            return
        }
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, 0.1)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Run-loop source on main first (wires callbacks); registration IPC off main (see axRegistrationQueue).
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        Self.axRegistrationQueue.async {
            AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, refcon)
            AXObserverAddNotification(observer, app, kAXWindowCreatedNotification as CFString, refcon)
        }
        axObserver = observer
        appElement = app
        refreshCache()
    }

    private func stopAXObservation() {
        // Dropping the AXObserver removes every notification on it (app-level and focused-element alike),
        // so the synchronous per-element AXObserverRemoveNotification is unnecessary here, and on an app
        // switch it was a main-thread block against the previous, busy app. Kept-observer callers still
        // use unregisterFocusedElement (now itself off main).
        if let observer = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        axObserver = nil
        appElement = nil
        focusedElement = nil
        focusedWindowID = nil
    }

    private func refreshCache() {
        guard let pid = activePID else { return }
        guard let token = refreshCoalescer.request() else { return }
        startCacheRefresh(token: token, pid: pid)
    }

    private func startCacheRefresh(token: UInt64, pid: pid_t) {
        let expectedCache = cacheGeneration
        let expectedObservation = observationGeneration
        let screens = Self.screenFrames()
        Task.detached(priority: .userInitiated) {
            let result = Self.readAXState(pid: pid, screenFrames: screens)
            await MainActor.run { [weak self] in
                self?.finishCacheRefresh(
                    token: token,
                    result: result,
                    pid: pid,
                    expectedCache: expectedCache,
                    expectedObservation: expectedObservation
                )
            }
        }
    }

    private func finishCacheRefresh(
        token: UInt64,
        result: AXReadResult?,
        pid: pid_t,
        expectedCache: UInt64,
        expectedObservation: UInt64
    ) {
        let completion = refreshCoalescer.complete(token: token)
        guard completion != .ignored else { return }

        if FullscreenIntentCacheDecision.shouldApplyRefresh(
            started: started,
            expectedObservation: expectedObservation,
            currentObservation: observationGeneration,
            expectedCache: expectedCache,
            currentCache: cacheGeneration,
            requestedPID: pid,
            activePID: activePID
        ) {
            if let result {
                registerFocusedElement(result.element, windowID: result.windowID)
                atomicState.replaceSnapshot(FullscreenIntentSnapshot(
                    generation: expectedCache,
                    pid: result.pid,
                    focusedWindowID: result.windowID,
                    buttonFrame: result.buttonFrame,
                    windowFrame: result.windowFrame,
                    screenCGFrame: result.screenCGFrame,
                    panelScreenCGFrames: panelScreenCGFrames,
                    isFullscreen: result.isFullscreen,
                    buttonEnabled: result.buttonEnabled
                ))
            } else {
                atomicState.replaceSnapshot(nil)
                unregisterFocusedElement(observer: axObserver)
            }
        }

        if case let .start(nextToken) = completion {
            guard started, let nextPID = activePID else {
                refreshCoalescer.reset()
                return
            }
            startCacheRefresh(token: nextToken, pid: nextPID)
        }
    }

    private func invalidateCache() {
        cacheGeneration &+= 1
        atomicState.replaceSnapshot(nil)
    }

    private func registerFocusedElement(_ element: AXUIElement, windowID: CGWindowID) {
        guard let observer = axObserver else { return }
        if focusedWindowID == windowID { return }
        unregisterFocusedElement(observer: observer)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        Self.axRegistrationQueue.async {
            AXObserverAddNotification(observer, element, kAXWindowMovedNotification as CFString, refcon)
            AXObserverAddNotification(observer, element, kAXWindowResizedNotification as CFString, refcon)
            AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString, refcon)
        }
        focusedElement = element
        focusedWindowID = windowID
    }

    private func unregisterFocusedElement(observer: AXObserver?) {
        guard let observer, let element = focusedElement else {
            focusedElement = nil
            focusedWindowID = nil
            return
        }
        Self.axRegistrationQueue.async {
            AXObserverRemoveNotification(observer, element, kAXWindowMovedNotification as CFString)
            AXObserverRemoveNotification(observer, element, kAXWindowResizedNotification as CFString)
            AXObserverRemoveNotification(observer, element, kAXUIElementDestroyedNotification as CFString)
        }
        focusedElement = nil
        focusedWindowID = nil
    }

    private func handleAXNotification(_ notification: CFString) {
        let name = notification as String
        if name == (kAXFocusedWindowChangedNotification as String) {
            invalidateCache()
            onContextChange(.focusedWindow)
            refreshCache()
        } else if name == (kAXWindowCreatedNotification as String) {
            // The native fullscreen transition itself creates temporary AX elements; that is not evidence
            // that focus left the original window.
            invalidateCache()
            refreshCache()
        } else if name == (kAXWindowMovedNotification as String)
            || name == (kAXWindowResizedNotification as String) {
            invalidateCache()
            refreshCache()
        } else if name == (kAXUIElementDestroyedNotification as String) {
            let windowID = focusedWindowID
            invalidateCache()
            onContextChange(.windowDestroyed(windowID))
            unregisterFocusedElement(observer: axObserver)
            refreshCache()
        }
    }

    private static let axCallback: AXObserverCallback = { _, _, notification, refcon in
        guard let refcon else { return }
        let monitor = Unmanaged<FullscreenIntentMonitor>.fromOpaque(refcon).takeUnretainedValue()
        // The observer source is installed on CFRunLoopGetMain(), so invalidate during the
        // notification turn instead of adding a second main-queue hop.
        MainActor.assumeIsolated {
            monitor.handleAXNotification(notification)
        }
    }

    nonisolated private static func readAXState(
        pid: pid_t,
        screenFrames: [CGRect]
    ) -> AXReadResult? {
        let reader = AXWindowReader()
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, 0.1)
        guard let focused = reader.elementAttribute(
            kAXFocusedWindowAttribute as CFString,
            from: app,
            maxAttempts: 1
        ) else { return nil }
        _ = AXUIElementSetMessagingTimeout(focused, 0.1)
        guard reader.stringAttribute(kAXRoleAttribute as CFString, from: focused, maxAttempts: 1) == kAXWindowRole,
              let windowID = reader.cgWindowID(for: focused, maxAttempts: 1),
              let windowFrame = reader.frame(of: focused, maxAttempts: 1),
              let screenFrame = screenFrames.max(by: {
                  $0.intersection(windowFrame).area < $1.intersection(windowFrame).area
              }),
              screenFrame.intersects(windowFrame),
              let button = reader.elementAttribute(
                  "AXFullScreenButton" as CFString,
                  from: focused,
                  maxAttempts: 1
              ) else { return nil }
        _ = AXUIElementSetMessagingTimeout(button, 0.1)
        guard let buttonFrame = reader.frame(of: button, maxAttempts: 1) else { return nil }
        let isAXFullscreen = reader.boolAttribute(
            "AXFullScreen" as CFString,
            from: focused,
            maxAttempts: 1
        ) ?? false
        let isFullscreen = FullscreenWindowClassifier.isFullscreen(
            role: kAXWindowRole,
            isAXFullscreen: isAXFullscreen,
            windowFrame: windowFrame,
            screenCGFrame: screenFrame
        )
        return AXReadResult(
            element: focused,
            pid: pid,
            windowID: windowID,
            buttonFrame: buttonFrame,
            windowFrame: windowFrame,
            screenCGFrame: screenFrame,
            isFullscreen: isFullscreen,
            buttonEnabled: reader.boolAttribute(
                kAXEnabledAttribute as CFString,
                from: button,
                maxAttempts: 1
            ) ?? false
        )
    }

    private static func screenFrames() -> [CGRect] {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
        return NSScreen.screens.map { screen in
            let frame = screen.frame
            return CGRect(
                x: frame.minX,
                y: primaryHeight - frame.maxY,
                width: frame.width,
                height: frame.height
            )
        }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
