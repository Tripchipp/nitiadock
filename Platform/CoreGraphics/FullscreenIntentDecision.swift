import CoreGraphics
import Foundation
import os.lock

enum FullscreenIntentSource: String, Equatable {
    case greenButton
    case keyboardShortcut
}

struct FullscreenIntentSnapshot: Equatable {
    let generation: UInt64
    let pid: pid_t
    let focusedWindowID: CGWindowID
    let buttonFrame: CGRect
    let windowFrame: CGRect
    let screenCGFrame: CGRect
    /// Displays that have a taskbar (several under ③④). If the focused window's display is not among them
    /// there is no bar to hide and no request is sent. **Cannot be a `Set<CGRect>`**: `CGRect`'s `Hashable`
    /// conformance is macOS 15+ (project rule).
    let panelScreenCGFrames: [CGRect]
    let isFullscreen: Bool
    let buttonEnabled: Bool
}

struct FullscreenIntentRequest: Equatable {
    let source: FullscreenIntentSource
    let cacheGeneration: UInt64
    let pid: pid_t
    let focusedWindowID: CGWindowID
    let screenCGFrame: CGRect
}

enum FullscreenIntentDecision {
    static let ansiFKeyCode = CGKeyCode(3)

    private static let intentModifiers: CGEventFlags = [
        .maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn, .maskHelp,
        .maskNumericPad
    ]

    static func normalizedModifiers(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection(intentModifiers)
    }

    static func greenButtonRequest(
        location: CGPoint,
        flags: CGEventFlags,
        snapshot: FullscreenIntentSnapshot?
    ) -> FullscreenIntentRequest? {
        guard let snapshot,
              snapshot.buttonEnabled,
              !snapshot.isFullscreen,
              snapshot.panelScreenCGFrames.contains(snapshot.screenCGFrame),
              normalizedModifiers(flags).isEmpty,
              snapshot.buttonFrame.contains(location) else {
            return nil
        }
        return request(source: .greenButton, snapshot: snapshot)
    }

    static func shortcutRequest(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        isRepeat: Bool,
        snapshot: FullscreenIntentSnapshot?
    ) -> FullscreenIntentRequest? {
        guard let snapshot,
              snapshot.buttonEnabled,
              !snapshot.isFullscreen,
              snapshot.panelScreenCGFrames.contains(snapshot.screenCGFrame),
              !isRepeat,
              keyCode == ansiFKeyCode,
              normalizedModifiers(flags) == [.maskCommand, .maskControl] else {
            return nil
        }
        return request(source: .keyboardShortcut, snapshot: snapshot)
    }

    static func isEnabled(
        settingEnabled: Bool,
        environment: [String: String]
    ) -> Bool {
        settingEnabled && DebugSwitch.fullscreenIntent.isEnabled(in: environment)
    }

    private static func request(
        source: FullscreenIntentSource,
        snapshot: FullscreenIntentSnapshot
    ) -> FullscreenIntentRequest {
        FullscreenIntentRequest(
            source: source,
            cacheGeneration: snapshot.generation,
            pid: snapshot.pid,
            focusedWindowID: snapshot.focusedWindowID,
            screenCGFrame: snapshot.screenCGFrame
        )
    }
}

enum SpaceSwitchDirection: String, Equatable {
    case left
    case right
}

/// Snapshot of the Space layout on one display (plain-data projection of SkyLight
/// `SLSCopyManagedDisplaySpaces`).
struct SpaceLayoutSnapshot: Equatable {
    /// Space ids in Mission Control's left-to-right order.
    let orderedSpaceIDs: [Int]
    /// Ids of the fullscreen Spaces (`type == 4`).
    let fullscreenSpaceIDs: Set<Int>
    let currentSpaceID: Int

    static let fullscreenSpaceType = 4

    /// Whether the adjacent Space in the target direction is a fullscreen Space. **This gate is the
    /// precondition for all predictive hiding**: without it, switching between two normal desktops would also
    /// hide the taskbar briefly, where there was no problem to begin with. The "not currently in a fullscreen
    /// Space" precondition was added 2026-08-31: fullscreen to fullscreen has nothing to hide (the bar is
    /// already hidden) and is left to the existing hold mechanism.
    ///
    /// **The reverse (predictive reveal for fullscreen to desktop) was built and reverted** (2026-08-31,
    /// decision: stability first): it relies on guessing the gesture, and in a fullscreen Space three-finger
    /// gestures mean far more than "swipe back to the desktop". A wrong guess makes the bar pop up over
    /// fullscreen content, and it can get stuck there when an AX read fails. Swiping back to the desktop =
    /// stable fade-in after arrival once the hold check settles (~0.5s), no prediction. Revisit if the system
    /// provides an **advance notification** of Space switches (a real signal, not a guessed gesture).
    func neighborIsFullscreen(_ direction: SpaceSwitchDirection) -> Bool {
        guard !fullscreenSpaceIDs.contains(currentSpaceID),
              let index = orderedSpaceIDs.firstIndex(of: currentSpaceID) else { return false }
        let neighbor = direction == .right ? index + 1 : index - 1
        guard orderedSpaceIDs.indices.contains(neighbor) else { return false }
        return fullscreenSpaceIDs.contains(orderedSpaceIDs[neighbor])
    }

    var hasAnyFullscreenNeighbor: Bool {
        neighborIsFullscreen(.left) || neighborIsFullscreen(.right)
    }
}

/// Space layout directory for all displays (multi-display taskbar, 2026-09-02). Space switches happen per
/// display: a three-finger swipe acts on the display under the cursor, Control+Left/Right on the display with
/// keyboard focus; predictive hiding must first locate that display.
struct SpaceLayoutDirectory: Equatable {
    struct Entry: Equatable {
        let displayUUID: String
        /// AppKit coordinates (`NSScreen.frame`), used to locate the display from `NSEvent.mouseLocation`.
        let appKitFrame: CGRect
        let layout: SpaceLayoutSnapshot
    }

    let entries: [Entry]

    /// Fast path on the event thread: only worth continuing if some display has a fullscreen Space on either
    /// side.
    var hasAnyFullscreenNeighbor: Bool {
        entries.contains { $0.layout.hasAnyFullscreenNeighbor }
    }

    func entry(containing point: CGPoint) -> Entry? {
        entries.first { $0.appKitFrame.contains(point) }
    }

    func entry(forDisplayUUID uuid: String) -> Entry? {
        entries.first { $0.displayUUID == uuid }
    }

    /// Displays whose adjacent Space in the target direction is fullscreen (candidates for the
    /// Control+Left/Right path).
    func displays(withFullscreenNeighbor direction: SpaceSwitchDirection) -> [Entry] {
        entries.filter { $0.layout.neighborIsFullscreen(direction) }
    }

    /// Which display Control+Left/Right lands on: a single candidate is it; with several, take the one under
    /// the mouse (the keyboard-focus display cannot be read, the mouse is the best approximation); if none
    /// contains the mouse take the first; no candidates: nil (gate closed).
    func arrowTarget(_ direction: SpaceSwitchDirection, mouseLocation: CGPoint) -> Entry? {
        let candidates = displays(withFullscreenNeighbor: direction)
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates[0] }
        return candidates.first { $0.appKitFrame.contains(mouseLocation) } ?? candidates[0]
    }
}

/// Pure state machine for the three-finger horizontal swipe. Fed once per gesture event in the stream, it
/// emits a direction once the conditions are met.
///
/// Criteria from 2026-08-09 measurements (samples in the diagnostics archive): **≥3 fingers + horizontal
/// travel > threshold + horizontal travel exceeding vertical travel**.
/// - "Horizontal > threshold" alone falsely matches three-finger vertical swipes (1 in 10); adding
///   "horizontal > vertical" excludes all 10/10.
/// - Thresholds of 0.03 / 0.05 / 0.08 give identical results: the signal itself separates cleanly, it is
///   not a tuning artifact.
/// - Everyday two-finger scrolling / clicking / cursor movement (about 45 seconds of samples) never
///   triggers: they never reach three fingers.
struct SpaceSwipeTracker: Equatable {
    static let minimumTouches = 3
    static let horizontalThreshold = 0.05
    /// Re-anchor when no valid sample arrives within this interval. **Required**: about a third of gesture
    /// events (magnify and the like) carry no touch data at all, and "this event has no data" must not be
    /// read as "fingers lifted", otherwise a swipe is interrupted over and over, the anchor keeps resetting,
    /// and the criteria never hold.
    static let burstGap: TimeInterval = 0.4

    private var anchorX: Double?
    private var anchorY: Double?
    private var lastSampleAt: TimeInterval?
    private var firedInThisBurst = false

    mutating func reset() {
        anchorX = nil
        anchorY = nil
        lastSampleAt = nil
        firedInThisBurst = false
    }

    /// - Parameter naturalScrolling: the system "natural scrolling" setting. Measured (14/14 consistent):
    ///   with natural scrolling **swiping fingers left goes to the Space on the right**, direction opposite
    ///   to the sign of the travel; with it off the signs match.
    mutating func consume(
        touches: Int,
        x: Double,
        y: Double,
        at now: TimeInterval,
        naturalScrolling: Bool
    ) -> SpaceSwitchDirection? {
        if let last = lastSampleAt, now - last > Self.burstGap { reset() }
        guard touches >= Self.minimumTouches else {
            reset()
            return nil
        }
        lastSampleAt = now
        guard let ax = anchorX, let ay = anchorY else {
            anchorX = x
            anchorY = y
            return nil
        }
        guard !firedInThisBurst else { return nil }
        let dx = x - ax
        let dy = y - ay
        guard abs(dx) > Self.horizontalThreshold, abs(dx) > abs(dy) else { return nil }
        firedInThisBurst = true
        let movesRight = naturalScrolling ? (dx < 0) : (dx > 0)
        return movesRight ? .right : .left
    }
}

/// Predictive hiding for Control+Left/Right Space switches. **Shipped and on by default**, disable with
/// `DOCK_SPACE_INTENT=0`
/// (decided by `spaceSwitchEnabled` in `FullscreenIntentMonitor`).
///
/// ⚠️ This section long read "experiment, `DOCK_SPACE_INTENT_EXPERIMENT=1`, off by default, does not check
/// the adjacent Space". That was the description when the work started on 2026-08-09 and is **long
/// obsolete**: no code in the repo reads that env var, and the adjacent-Space gate has since been added as a
/// hard condition. Corrected 2026-08-19: a comment this stale leads the next person investigating "fullscreen
/// switch flicker" straight to the wrong conclusion that the feature is not enabled at all.
///
/// The question at the start: the arrow key press precedes the actual Space switch by about `548–575ms`
/// (measured and archived); is that lead enough to remove the flicker for "normal desktop to fullscreen
/// Space"? Two approaches measured as dead ends are managed-space prediction (only about 30ms early) and fast
/// AX probing (0.2–1ms after the Space notification), both later than WindowServer's transition snapshot.
///
/// **The adjacent-Space gate is a hard condition**: predict only when the adjacent Space in the target
/// direction really is fullscreen, otherwise pressing an arrow key between two normal desktops hides the bar
/// for nothing. The gate is already applied in `FullscreenIntentMonitor` (`SLSCopyManagedDisplaySpaces`,
/// matched by display UUID, not by array order).
enum FullscreenSpaceSwitchDecision {
    static let leftArrowKeyCode = CGKeyCode(123)
    static let rightArrowKeyCode = CGKeyCode(124)

    /// **Physical arrow keys inherently carry the three flags `Fn + numeric pad + nonCoalesced`** (measured
    /// and archived 2026-08-09), even when the user presses no extra key. So the normalization from
    /// `FullscreenIntentDecision` cannot be reused here (it counts Fn / numeric pad as user modifiers): it
    /// would never match, giving a false negative that "triggers nothing" and is very easily misread as "the
    /// lead is not enough, this approach is a dead end".
    private static let userModifiers: CGEventFlags = [
        .maskCommand, .maskControl, .maskAlternate, .maskShift, .maskHelp
    ]

    static func normalizedModifiers(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection(userModifiers)
    }

    static func arrowDirection(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        isRepeat: Bool
    ) -> SpaceSwitchDirection? {
        guard !isRepeat, normalizedModifiers(flags) == [.maskControl] else { return nil }
        switch keyCode {
        case leftArrowKeyCode: return .left
        case rightArrowKeyCode: return .right
        default: return nil
        }
    }

    static func isSpaceSwitchArrow(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        isRepeat: Bool
    ) -> Bool {
        arrowDirection(keyCode: keyCode, flags: flags, isRepeat: isRepeat) != nil
    }
}

struct FullscreenIntentRefreshCoalescer: Equatable {
    enum Completion: Equatable {
        case ignored
        case idle
        case start(UInt64)
    }

    private(set) var activeToken: UInt64?
    private(set) var needsTrailingRefresh = false
    private var nextToken: UInt64 = 0

    mutating func request() -> UInt64? {
        guard activeToken == nil else {
            needsTrailingRefresh = true
            return nil
        }
        return begin()
    }

    mutating func complete(token: UInt64) -> Completion {
        guard activeToken == token else { return .ignored }
        if needsTrailingRefresh {
            needsTrailingRefresh = false
            let trailingToken = begin()
            return .start(trailingToken)
        }
        activeToken = nil
        return .idle
    }

    mutating func reset() {
        activeToken = nil
        needsTrailingRefresh = false
    }

    private mutating func begin() -> UInt64 {
        nextToken &+= 1
        activeToken = nextToken
        return nextToken
    }
}

enum FullscreenIntentCacheDecision {
    static func shouldApplyRefresh(
        started: Bool,
        expectedObservation: UInt64,
        currentObservation: UInt64,
        expectedCache: UInt64,
        currentCache: UInt64,
        requestedPID: pid_t,
        activePID: pid_t?
    ) -> Bool {
        started
            && expectedObservation == currentObservation
            && expectedCache == currentCache
            && requestedPID == activePID
    }

    static func isCurrentRequest(
        _ request: FullscreenIntentRequest,
        snapshot: FullscreenIntentSnapshot?,
        activePID: pid_t?,
        started: Bool
    ) -> Bool {
        guard started, activePID == request.pid, let snapshot else { return false }
        return snapshot.generation == request.cacheGeneration
            && snapshot.pid == request.pid
            && snapshot.focusedWindowID == request.focusedWindowID
            && snapshot.screenCGFrame == request.screenCGFrame
    }
}

struct FullscreenEventTapRecoveryPolicy: Equatable {
    static let window: TimeInterval = 60
    static let maximumReenables = 3

    private(set) var disableTimes: [TimeInterval] = []
    private(set) var isFused = false

    /// How long a fused tap stays off before it gets another chance. Without this one bad minute
    /// (a busy system timing the tap out four times) switched fullscreen prediction off until the
    /// app was restarted.
    static let fuseCoolDown: TimeInterval = 300

    /// Clears the fuse after the cool-down. Returns whether the tap may be enabled again.
    mutating func rearmAfterCoolDown() -> Bool {
        guard isFused else { return false }
        isFused = false
        disableTimes.removeAll()
        return true
    }

    mutating func recordDisable(at now: TimeInterval) -> Bool {
        guard !isFused else { return false }
        disableTimes.removeAll { now - $0 > Self.window }
        guard disableTimes.count < Self.maximumReenables else {
            isFused = true
            return false
        }
        disableTimes.append(now)
        return true
    }
}

final class FullscreenIntentHandoffGate {
    enum State: Equatable {
        case pending
        case executing
        case completed
        case cancelled
    }

    private var lock = os_unfair_lock_s()
    private var state: State = .pending

    func beginExecution() -> Bool {
        withLock {
            guard state == .pending else { return false }
            state = .executing
            return true
        }
    }

    func complete() {
        withLock {
            guard state == .executing else { return }
            state = .completed
        }
    }

    @discardableResult
    func cancelIfPending() -> Bool {
        withLock {
            guard state == .pending else { return false }
            state = .cancelled
            return true
        }
    }

    var currentState: State { withLock { state } }

    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return body()
    }
}
