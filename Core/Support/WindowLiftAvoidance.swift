import CoreGraphics
import Darwin
import Foundation

struct WindowLiftAvoidanceContext: Equatable {
    /// AppKit global geometry used to calculate the lifted target frame.
    let geometry: WindowLiftAvoidance.Geometry
    /// CG/Quartz global geometry used by the front-to-back window scan.
    let screenCGFrame: CGRect
    let visibleCGFrame: CGRect
    /// Flip reference between CG/AX top-left and AppKit bottom-left coordinates.
    let primaryScreenHeight: CGFloat
}

/// Pure geometry, cadence and session decisions for "maximized windows avoid the taskbar".
///
/// The geometry API uses AppKit global coordinates throughout (bottom-left origin); CGWindow/AX window frames
/// are converted before entering here via `appKitFrame(fromQuartz:primaryScreenHeight:)`.
enum WindowLiftAvoidance {
    static let detectionTolerance: CGFloat = 12
    static let verificationTolerance: CGFloat = 2
    static let clearance: CGFloat = 2
    static let animationDuration: TimeInterval = 0.5
    static let animationFramesPerSecond: Double = 30
    static let globalDetectionInterval: TimeInterval = 0.2
    static let trackedSessionProbeInterval: TimeInterval = 0.05
    static let maximumReliftCount = 1
    /// Re-asserting apps take back the full fill within ~450ms; a fill that reappears after this
    /// window is treated as a user action. This is the cure for the L↔M zoom-memory deadlock: once zoom
    /// memory is polluted the window only bounces between native↔target and never produces an external frame,
    /// so the time scale is the only reliable "app vs user" discriminator. It is ~450ms with a 2.2x margin;
    /// it is also the wait before an abandoned session reopens on timeout, so raising it directly amplifies
    /// the "after repeated zooms it takes seconds to lift" impression (feedback 2026-07-16).
    static let appReassertWindow: TimeInterval = 1.0
    /// Cap on consecutive standoff rounds: how many times an abandoned session reopens on timeout. Once
    /// reached it drops to slow retries at `standoffLockBackoff`, so a truly stubborn app does not turn into
    /// a slow-motion tug of war with one round per second.
    static let maximumStandoffRounds = 2
    /// Slow reopen interval once the standoff rounds reach the cap. Not a permanent lock: a window with
    /// polluted zoom memory may never get an external frame, and a permanent lock = it never lifts again
    /// unless the user's hand is slow enough.
    static let standoffLockBackoff: TimeInterval = 3.0

    enum PollCadence {
        static let idleInterval: TimeInterval = 1.0

        static func interval(
            hasSessions: Bool,
            hasSuppressedFrames: Bool,
            isRestoring: Bool
        ) -> TimeInterval {
            hasSessions || hasSuppressedFrames || isRestoring
                ? globalDetectionInterval
                : idleInterval
        }
    }

    struct EventPollCoalescer: Equatable {
        enum Action: Equatable {
            case none
            case start
            case schedule(after: TimeInterval)
        }

        private(set) var pending = false
        private(set) var lastStartedAt: TimeInterval?

        mutating func request(at now: TimeInterval, scanInFlight: Bool) -> Action {
            pending = true
            return drain(at: now, scanInFlight: scanInFlight)
        }

        mutating func scanCompleted(at now: TimeInterval) -> Action {
            guard pending else { return .none }
            return drain(at: now, scanInFlight: false)
        }

        mutating func cooldownFired(at now: TimeInterval, scanInFlight: Bool) -> Action {
            guard pending else { return .none }
            return drain(at: now, scanInFlight: scanInFlight)
        }

        mutating func reset() {
            pending = false
            lastStartedAt = nil
        }

        private mutating func drain(at now: TimeInterval, scanInFlight: Bool) -> Action {
            guard !scanInFlight else { return .none }
            if let lastStartedAt {
                let remaining = globalDetectionInterval - (now - lastStartedAt)
                if remaining > 0.000_001 { return .schedule(after: remaining) }
            }
            pending = false
            lastStartedAt = now
            return .start
        }
    }

    /// cgWindowID is used only within the current session while the window is alive; the controller must
    /// prune periodically against the full CG list.
    struct WindowKey: Hashable {
        let pid: pid_t
        let cgWindowID: CGWindowID
    }

    struct Geometry: Equatable {
        /// AppKit global coordinates (bottom-left origin).
        let screenFrame: CGRect
        let visibleFrame: CGRect
        let taskbarTop: CGFloat

        func fillsVisibleFrame(
            _ frame: CGRect,
            tolerance: CGFloat = WindowLiftAvoidance.detectionTolerance
        ) -> Bool {
            guard mostlyBelongsToScreen(frame) else { return false }
            return WindowLiftAvoidance.fillsVisibleFrame(
                frame,
                visible: visibleFrame,
                tolerance: tolerance
            )
        }

        /// Keeps the window's top, left and width; only pulls the bottom edge above the system reserved area
        /// and the NitiaDock taskbar.
        func adjustedFrame(
            for maximizedFrame: CGRect,
            clearance: CGFloat = WindowLiftAvoidance.clearance
        ) -> CGRect? {
            guard fillsVisibleFrame(maximizedFrame),
                  clearance.isFinite,
                  clearance >= 0,
                  taskbarTop.isFinite else {
                return nil
            }

            let targetBottom = max(
                maximizedFrame.minY,
                visibleFrame.minY,
                taskbarTop + clearance
            )
            return WindowLiftAvoidance.adjustedFrame(
                for: maximizedFrame,
                targetBottom: targetBottom
            )
        }

        private func mostlyBelongsToScreen(_ frame: CGRect) -> Bool {
            guard WindowLiftAvoidance.isValid(frame: frame),
                  WindowLiftAvoidance.isValid(frame: screenFrame) else {
                return false
            }
            let overlap = frame.intersection(screenFrame)
            guard !overlap.isNull, !overlap.isEmpty else { return false }
            return overlap.width * overlap.height >= frame.width * frame.height * 0.5
        }
    }

    static func fillsVisibleFrame(
        _ frame: CGRect,
        visible: CGRect,
        tolerance: CGFloat = detectionTolerance
    ) -> Bool {
        guard isValid(frame: frame),
              isValid(frame: visible),
              tolerance.isFinite,
              tolerance >= 0 else {
            return false
        }
        return abs(frame.minX - visible.minX) <= tolerance
            && abs(frame.maxX - visible.maxX) <= tolerance
            && abs(frame.minY - visible.minY) <= tolerance
            && abs(frame.maxY - visible.maxY) <= tolerance
    }

    /// Low-level geometry helper; the caller is responsible for the maximized check first.
    static func adjustedFrame(
        for frame: CGRect,
        taskbarTopY: CGFloat,
        clearance: CGFloat = clearance
    ) -> CGRect? {
        guard taskbarTopY.isFinite,
              clearance.isFinite,
              clearance >= 0 else {
            return nil
        }
        return adjustedFrame(
            for: frame,
            targetBottom: max(frame.minY, taskbarTopY + clearance)
        )
    }

    static func framesMatch(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = verificationTolerance
    ) -> Bool {
        guard isValid(frame: lhs),
              isValid(frame: rhs),
              tolerance.isFinite,
              tolerance >= 0 else {
            return false
        }
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    enum FrameClassification: Equatable {
        case target
        case native
        case managedTrajectory
        case external
    }

    /// Classifies an observed frame in fixed priority order. The order matters near either endpoint.
    static func frameClassification(
        of frame: CGRect,
        nativeFrame: CGRect,
        targetFrame: CGRect,
        tolerance: CGFloat = verificationTolerance
    ) -> FrameClassification {
        guard isValid(frame: frame),
              isValid(frame: nativeFrame),
              isValid(frame: targetFrame),
              tolerance.isFinite,
              tolerance >= 0 else {
            return .external
        }
        if framesMatch(frame, targetFrame, tolerance: tolerance) { return .target }
        if framesMatch(frame, nativeFrame, tolerance: tolerance) { return .native }

        let lowerBottom = min(nativeFrame.minY, targetFrame.minY)
        let upperBottom = max(nativeFrame.minY, targetFrame.minY)
        let followsFixedEdges = abs(frame.minX - nativeFrame.minX) <= tolerance
            && abs(frame.width - nativeFrame.width) <= tolerance
            && abs(frame.maxY - nativeFrame.maxY) <= tolerance
        if followsFixedEdges,
           frame.minY >= lowerBottom,
           frame.minY <= upperBottom {
            return .managedTrajectory
        }
        return .external
    }

    /// Used by the bounded 0/100/250ms confirmation pass before an AX write begins.
    static func samplesAreStable(
        _ sample: CGRect,
        comparedTo reference: CGRect,
        tolerance: CGFloat = verificationTolerance
    ) -> Bool {
        framesMatch(sample, reference, tolerance: tolerance)
    }

    /// Requires the detected CG frame, the delayed CG confirmation, and AX's frame to agree
    /// without allowing pairwise drift to accumulate beyond the verification tolerance.
    static func samplesAreStable(
        initialCGFrame: CGRect,
        confirmedCGFrame: CGRect,
        confirmedAXFrame: CGRect,
        tolerance: CGFloat = verificationTolerance
    ) -> Bool {
        framesMatch(initialCGFrame, confirmedCGFrame, tolerance: tolerance)
            && framesMatch(initialCGFrame, confirmedAXFrame, tolerance: tolerance)
            && framesMatch(confirmedCGFrame, confirmedAXFrame, tolerance: tolerance)
    }

    // MARK: - AX synchronization retry schedule

    struct PollSchedule: Equatable {
        /// Absolute deadlines relative to CG detection; zero means the first AX attempt is immediate.
        let deadlines: [TimeInterval]

        static let standard = PollSchedule(deadlines: [0, 0.1, 0.25])

        var incrementalDelays: [TimeInterval] {
            var previous: TimeInterval = 0
            return deadlines.map { deadline in
                defer { previous = deadline }
                return max(0, deadline - previous)
            }
        }

        func remainingDelay(for index: Int, elapsed: TimeInterval) -> TimeInterval? {
            guard deadlines.indices.contains(index), elapsed.isFinite else { return nil }
            return max(0, deadlines[index] - max(0, elapsed))
        }
    }

    // MARK: - Lift session

    struct WriteAttempt: Equatable {
        /// Detached AX operation generation; write completion must match this value exactly.
        let generation: UInt64
        /// Newest CG observation consumed while the detached writer is still active.
        let latestObservationGeneration: UInt64
        let nativeFrame: CGRect
        let targetFrame: CGRect
        /// Number of application frame takeovers already answered in this maximize session.
        let reliftCount: Int
        /// Accumulated rounds of abandoned-timeout reopens, carried with the session (reset with the state
        /// when external clears the session).
        let standoffRounds: Int

        var isRelift: Bool { reliftCount > 0 }
    }

    struct LiftedSession: Equatable {
        /// Latest accepted observation generation, not a persistent window identity.
        let generation: UInt64
        let nativeFrame: CGRect
        /// Intended write target (not the actual landing): the actual landing drifts within the ±2pt
        /// tolerance, and if the actual value were stored, a session reopened on timeout would target the
        /// previous landing, the error would compound round by round and the bottom edge would creep higher.
        let adjustedFrame: CGRect
        let reliftCount: Int
        /// When the lift write finished (the `at` of writeFinished); a fill reappearance is compared against
        /// it to tell re-assertion from user action.
        let settledAt: TimeInterval
        let standoffRounds: Int
    }

    enum AbandonReason: Equatable {
        case reliftLimitReached
        case writeFailed
    }

    struct AbandonedSession: Equatable {
        let generation: UInt64
        let nativeFrame: CGRect
        let adjustedFrame: CGRect
        let reliftCount: Int
        let reason: AbandonReason
        /// When the abandoned state was entered. Later observations must not refresh it, or the abandoned
        /// state never expires.
        let abandonedAt: TimeInterval
        let standoffRounds: Int
    }

    enum SessionState: Equatable {
        case idle
        case writing(WriteAttempt)
        case lifted(LiftedSession)
        case abandoned(AbandonedSession)
    }

    /// `at` is always on the `ProcessInfo.systemUptime` timeline; reduce stays a pure function and time only
    /// enters through events.
    enum Event: Equatable {
        case maximizedDetected(generation: UInt64, at: TimeInterval, nativeFrame: CGRect, targetFrame: CGRect)
        case writeFinished(generation: UInt64, at: TimeInterval, actualFrame: CGRect, reliftCount: Int)
        case writeFailed(generation: UInt64, at: TimeInterval, reliftCount: Int)
        case reliftLimitReached(generation: UInt64, at: TimeInterval, reliftCount: Int)
        /// The controller sends this only for a live frame that no longer fills visibleFrame.
        case nonMaximizedObserved(generation: UInt64, at: TimeInterval, frame: CGRect)
        case windowUnavailable(generation: UInt64)
    }

    enum Action: Equatable {
        case none
        case write(targetFrame: CGRect, rollbackFrame: CGRect, generation: UInt64, isRelift: Bool)
        case abandon(AbandonReason)
        case clear
    }

    struct Transition: Equatable {
        let state: SessionState
        let action: Action
    }

    /// Write once on the first fill; write once more after the app takes the fill back; give up if it takes
    /// it back again. Time-scale rule: a fill reappearing within `appReassertWindow` of the write / abandon =
    /// app re-assertion (extra lift / give up); later = user action (fresh session). A window with polluted
    /// zoom memory only bounces between native↔target and never produces an external frame, so the timeout
    /// reopen is its only exit; `maximumStandoffRounds` caps it against a slow-motion tug of war.
    static func reduce(state: SessionState, event: Event) -> Transition {
        switch event {
        case let .maximizedDetected(generation, at, nativeFrame, targetFrame):
            guard isValid(frame: nativeFrame), isValid(frame: targetFrame) else {
                return Transition(state: state, action: .none)
            }

            switch state {
            case .idle:
                return beginWrite(
                    generation: generation,
                    nativeFrame: nativeFrame,
                    targetFrame: targetFrame,
                    reliftCount: 0,
                    standoffRounds: 0
                )

            case let .writing(attempt):
                // The detached writer owns trajectory recovery and relift while this attempt is active.
                guard generation > attempt.latestObservationGeneration else {
                    return Transition(state: state, action: .none)
                }
                return Transition(
                    state: writingAttempt(attempt, observing: generation),
                    action: .none
                )

            case let .lifted(session):
                guard generation > session.generation else {
                    return Transition(state: state, action: .none)
                }
                guard at - session.settledAt <= appReassertWindow else {
                    // The user re-maximized long after the write: fresh session, extra-lift budget and
                    // standoff rounds reset.
                    return beginWrite(
                        generation: generation,
                        nativeFrame: nativeFrame,
                        targetFrame: targetFrame,
                        reliftCount: 0,
                        standoffRounds: 0
                    )
                }
                return beginReliftOrAbandon(
                    generation: generation,
                    at: at,
                    nativeFrame: nativeFrame,
                    targetFrame: targetFrame,
                    reliftCount: session.reliftCount,
                    standoffRounds: session.standoffRounds
                )

            case let .abandoned(session):
                guard generation >= session.generation else {
                    return Transition(state: state, action: .none)
                }
                if at - session.abandonedAt > abandonedReopenDelay(for: session) {
                    // The standoff window has passed: reopen on timeout as a user action and count one
                    // standoff round (slow retries once the cap is reached).
                    return beginWrite(
                        generation: generation,
                        nativeFrame: nativeFrame,
                        targetFrame: targetFrame,
                        reliftCount: 0,
                        standoffRounds: min(session.standoffRounds + 1, maximumStandoffRounds)
                    )
                }
                return Transition(
                    state: .abandoned(AbandonedSession(
                        generation: generation,
                        nativeFrame: nativeFrame,
                        adjustedFrame: targetFrame,
                        reliftCount: session.reliftCount,
                        reason: session.reason,
                        abandonedAt: session.abandonedAt,
                        standoffRounds: session.standoffRounds
                    )),
                    action: .none
                )
            }

        case let .writeFinished(generation, at, actualFrame, reliftCount):
            guard case let .writing(attempt) = state,
                  attempt.generation == generation else {
                return Transition(state: state, action: .none)
            }
            guard reliftCount >= attempt.reliftCount,
                  reliftCount <= maximumReliftCount,
                  framesMatch(actualFrame, attempt.targetFrame) else {
                let abandoned = AbandonedSession(
                    generation: max(generation, attempt.latestObservationGeneration),
                    nativeFrame: attempt.nativeFrame,
                    adjustedFrame: attempt.targetFrame,
                    reliftCount: max(attempt.reliftCount, reliftCount),
                    reason: .writeFailed,
                    abandonedAt: at,
                    standoffRounds: attempt.standoffRounds
                )
                return Transition(state: .abandoned(abandoned), action: .abandon(.writeFailed))
            }
            return Transition(
                state: .lifted(LiftedSession(
                    generation: max(generation, attempt.latestObservationGeneration),
                    nativeFrame: attempt.nativeFrame,
                    adjustedFrame: attempt.targetFrame,
                    reliftCount: reliftCount,
                    settledAt: at,
                    standoffRounds: attempt.standoffRounds
                )),
                action: .none
            )

        case let .writeFailed(generation, at, reliftCount):
            return abandonWritingAttempt(
                state: state,
                generation: generation,
                at: at,
                reliftCount: reliftCount,
                reason: .writeFailed
            )

        case let .reliftLimitReached(generation, at, reliftCount):
            return abandonWritingAttempt(
                state: state,
                generation: generation,
                at: at,
                reliftCount: reliftCount,
                reason: .reliftLimitReached
            )

        case let .nonMaximizedObserved(generation, at, frame):
            guard isValid(frame: frame) else {
                return Transition(state: state, action: .none)
            }
            switch state {
            case .idle:
                return Transition(state: state, action: .none)

            case let .writing(attempt):
                guard generation >= attempt.latestObservationGeneration else {
                    return Transition(state: state, action: .none)
                }
                switch frameClassification(
                    of: frame,
                    nativeFrame: attempt.nativeFrame,
                    targetFrame: attempt.targetFrame
                ) {
                case .target, .managedTrajectory:
                    return Transition(
                        state: writingAttempt(attempt, observing: generation),
                        action: .none
                    )
                case .native:
                    // The detached writer classifies and consumes a native snap serially.
                    return Transition(
                        state: writingAttempt(attempt, observing: generation),
                        action: .none
                    )
                case .external:
                    return Transition(state: .idle, action: .clear)
                }

            case let .lifted(session):
                guard generation >= session.generation else {
                    return Transition(state: state, action: .none)
                }
                switch frameClassification(
                    of: frame,
                    nativeFrame: session.nativeFrame,
                    targetFrame: session.adjustedFrame
                ) {
                case .external:
                    return Transition(state: .idle, action: .clear)
                case .native:
                    guard generation > session.generation else {
                        return Transition(state: state, action: .none)
                    }
                    guard at - session.settledAt <= appReassertWindow else {
                        // The user zoomed the window back to full fill (no external frame when zoom memory is
                        // polluted): fresh session.
                        return beginWrite(
                            generation: generation,
                            nativeFrame: session.nativeFrame,
                            targetFrame: session.adjustedFrame,
                            reliftCount: 0,
                            standoffRounds: 0
                        )
                    }
                    return beginReliftOrAbandon(
                        generation: generation,
                        at: at,
                        nativeFrame: session.nativeFrame,
                        targetFrame: session.adjustedFrame,
                        reliftCount: session.reliftCount,
                        standoffRounds: session.standoffRounds
                    )
                case .target, .managedTrajectory:
                    // Settled for longer than the standoff window after a lift = this tug of war is over,
                    // standoff rounds reset to zero.
                    let healedRounds = at - session.settledAt > appReassertWindow
                        ? 0 : session.standoffRounds
                    return Transition(
                        state: .lifted(LiftedSession(
                            generation: generation,
                            nativeFrame: session.nativeFrame,
                            adjustedFrame: session.adjustedFrame,
                            reliftCount: session.reliftCount,
                            settledAt: session.settledAt,
                            standoffRounds: healedRounds
                        )),
                        action: .none
                    )
                }

            case let .abandoned(session):
                guard generation >= session.generation else {
                    return Transition(state: state, action: .none)
                }
                switch frameClassification(
                    of: frame,
                    nativeFrame: session.nativeFrame,
                    targetFrame: session.adjustedFrame
                ) {
                case .external:
                    return Transition(state: .idle, action: .clear)
                case .native:
                    if at - session.abandonedAt > abandonedReopenDelay(for: session) {
                        return beginWrite(
                            generation: generation,
                            nativeFrame: session.nativeFrame,
                            targetFrame: session.adjustedFrame,
                            reliftCount: 0,
                            standoffRounds: min(session.standoffRounds + 1, maximumStandoffRounds)
                        )
                    }
                    return Transition(
                        state: .abandoned(refreshedAbandoned(session, observing: generation)),
                        action: .none
                    )
                case .target, .managedTrajectory:
                    return Transition(
                        state: .abandoned(refreshedAbandoned(session, observing: generation)),
                        action: .none
                    )
                }
            }

        case let .windowUnavailable(generation):
            guard let stateGeneration = stateGeneration(of: state), generation >= stateGeneration else {
                return Transition(state: state, action: .none)
            }
            return Transition(state: .idle, action: .clear)
        }
    }

    // MARK: - Animation

    static func easeInOutCubic(_ progress: Double) -> Double {
        guard progress.isFinite else { return 0 }
        let t = min(1, max(0, progress))
        if t < 0.5 {
            return 4 * t * t * t
        }
        let inverse = -2 * t + 2
        return 1 - inverse * inverse * inverse / 2
    }

    static func interpolatedFrame(from start: CGRect, to end: CGRect, progress: Double) -> CGRect {
        let amount = CGFloat(easeInOutCubic(progress))
        func interpolate(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
            lhs + (rhs - lhs) * amount
        }
        return CGRect(
            x: interpolate(start.minX, end.minX),
            y: interpolate(start.minY, end.minY),
            width: interpolate(start.width, end.width),
            height: interpolate(start.height, end.height)
        )
    }

    /// Maps the remaining portion of one hard-deadline animation back onto 0...1 after a rebase.
    static func rebasedAnimationProgress(
        _ overallProgress: Double,
        startingAt segmentStart: Double
    ) -> Double {
        guard overallProgress.isFinite, segmentStart.isFinite else { return 0 }
        let overall = min(1, max(0, overallProgress))
        let start = min(1, max(0, segmentStart))
        guard start < 1 else { return 1 }
        return min(1, max(0, (overall - start) / (1 - start)))
    }

    // MARK: - Failure recovery and dead-window pruning

    enum RollbackDecision: Equatable {
        case notNeeded
        case restore(CGRect)
        /// Frame disappeared or no longer matches our attempted write; preserve possible user input.
        case preserveCurrent
    }

    static func rollbackDecision(
        originalFrame: CGRect,
        attemptedFrame: CGRect,
        currentFrame: CGRect?
    ) -> RollbackDecision {
        guard let currentFrame else { return .preserveCurrent }
        if framesMatch(currentFrame, originalFrame) { return .notNeeded }
        if framesMatch(currentFrame, attemptedFrame) { return .restore(originalFrame) }
        return .preserveCurrent
    }

    /// AX-specific failure values are mapped into these two pure categories by the controller.
    enum AnimationWriteFailure: Equatable {
        case initialFrameMismatch(actualFrame: CGRect)
        case terminalWriteFailure
    }

    enum AnimationWriteFailureDecision: Equatable {
        case complete(actualFrame: CGRect)
        case continueFromActual(actualFrame: CGRect)
        case clearSession(preservingFrame: CGRect)
        case restartFromNative(nativeFrame: CGRect, nextReliftCount: Int)
        case reliftLimitReached(actualFrame: CGRect, reliftCount: Int)
        case abandonWriteFailed
    }

    /// Decides whether an interrupted serial animation still owns the observed frame.
    /// The actual frame remains attached to every recoverable decision so MainActor never has
    /// to reconstruct information discarded by the detached AX writer.
    ///
    /// `lastAcknowledgedFrame`: the window position last confirmed by the write loop. A read-back still equal
    /// to it = the window has not caught up with this frame's write (slow apps / late apps on a 1x external
    /// display): treat it as "continue" instead of giving up or lifting again. The first easing step is only
    /// ~2pt, so any rounding / delay hits the 2pt verify tolerance.
    static func animationWriteFailureDecision(
        _ failure: AnimationWriteFailure,
        nativeFrame: CGRect,
        targetFrame: CGRect,
        reliftCount: Int,
        lastAcknowledgedFrame: CGRect? = nil
    ) -> AnimationWriteFailureDecision {
        guard reliftCount >= 0 else { return .abandonWriteFailed }

        switch failure {
        case .terminalWriteFailure:
            return .abandonWriteFailed

        case let .initialFrameMismatch(actualFrame):
            guard isValid(frame: actualFrame),
                  isValid(frame: nativeFrame),
                  isValid(frame: targetFrame) else {
                return .abandonWriteFailed
            }
            if framesMatch(actualFrame, targetFrame) {
                return .complete(actualFrame: actualFrame)
            }
            // The stall check must come before native: on the first frame lastAcknowledged == native, and
            // classifying an unmoved window as native would burn the extra-lift budget for nothing.
            if let lastAcknowledgedFrame,
               isValid(frame: lastAcknowledgedFrame),
               framesMatch(actualFrame, lastAcknowledgedFrame) {
                return .continueFromActual(actualFrame: actualFrame)
            }
            switch frameClassification(
                of: actualFrame,
                nativeFrame: nativeFrame,
                targetFrame: targetFrame
            ) {
            case .target:
                return .complete(actualFrame: actualFrame)
            case .native:
                guard reliftCount < maximumReliftCount else {
                    return .reliftLimitReached(
                        actualFrame: actualFrame,
                        reliftCount: reliftCount
                    )
                }
                return .restartFromNative(
                    nativeFrame: actualFrame,
                    nextReliftCount: reliftCount + 1
                )
            case .managedTrajectory:
                return .continueFromActual(actualFrame: actualFrame)
            case .external:
                return .clearSession(preservingFrame: actualFrame)
            }
        }
    }

    static func deadWindowKeys(
        tracked: Set<WindowKey>,
        live: Set<WindowKey>
    ) -> Set<WindowKey> {
        tracked.subtracting(live)
    }

    /// A slower full-list snapshot must not erase a session already confirmed alive by a newer
    /// tracked-window observation. A later global pass can still prune it if it remains absent.
    static func prunableDeadWindowKeys(
        tracked: Set<WindowKey>,
        live: Set<WindowKey>,
        observationGeneration: UInt64,
        observationWatermarks: [WindowKey: UInt64]
    ) -> Set<WindowKey> {
        deadWindowKeys(tracked: tracked, live: live).filter {
            observationGeneration > (observationWatermarks[$0] ?? 0)
        }
    }

    static func prunedStates<Value>(
        _ states: [WindowKey: Value],
        liveWindowKeys: Set<WindowKey>
    ) -> [WindowKey: Value] {
        states.filter { liveWindowKeys.contains($0.key) }
    }

    // MARK: - Coordinate conversion

    static func appKitFrame(fromQuartz frame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: frame.minX,
            y: primaryScreenHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    static func quartzFrame(fromAppKit frame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: frame.minX,
            y: primaryScreenHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private static func adjustedFrame(for frame: CGRect, targetBottom: CGFloat) -> CGRect? {
        guard isValid(frame: frame), targetBottom.isFinite,
              targetBottom > frame.minY + verificationTolerance,
              targetBottom < frame.maxY - verificationTolerance else {
            return nil
        }
        return CGRect(
            x: frame.minX,
            y: targetBottom,
            width: frame.width,
            height: frame.maxY - targetBottom
        )
    }

    private static func beginWrite(
        generation: UInt64,
        nativeFrame: CGRect,
        targetFrame: CGRect,
        reliftCount: Int,
        standoffRounds: Int
    ) -> Transition {
        let attempt = WriteAttempt(
            generation: generation,
            latestObservationGeneration: generation,
            nativeFrame: nativeFrame,
            targetFrame: targetFrame,
            reliftCount: reliftCount,
            standoffRounds: standoffRounds
        )
        return Transition(
            state: .writing(attempt),
            action: .write(
                targetFrame: targetFrame,
                rollbackFrame: nativeFrame,
                generation: generation,
                isRelift: attempt.isRelift
            )
        )
    }

    private static func beginReliftOrAbandon(
        generation: UInt64,
        at: TimeInterval,
        nativeFrame: CGRect,
        targetFrame: CGRect,
        reliftCount: Int,
        standoffRounds: Int
    ) -> Transition {
        guard reliftCount < maximumReliftCount else {
            let abandoned = AbandonedSession(
                generation: generation,
                nativeFrame: nativeFrame,
                adjustedFrame: targetFrame,
                reliftCount: reliftCount,
                reason: .reliftLimitReached,
                abandonedAt: at,
                standoffRounds: standoffRounds
            )
            return Transition(
                state: .abandoned(abandoned),
                action: .abandon(.reliftLimitReached)
            )
        }
        return beginWrite(
            generation: generation,
            nativeFrame: nativeFrame,
            targetFrame: targetFrame,
            reliftCount: reliftCount + 1,
            standoffRounds: standoffRounds
        )
    }

    private static func abandonWritingAttempt(
        state: SessionState,
        generation: UInt64,
        at: TimeInterval,
        reliftCount: Int,
        reason: AbandonReason
    ) -> Transition {
        guard case let .writing(attempt) = state,
              attempt.generation == generation else {
            return Transition(state: state, action: .none)
        }
        let finalReliftCount = max(attempt.reliftCount, reliftCount)
        let abandoned = AbandonedSession(
            generation: max(generation, attempt.latestObservationGeneration),
            nativeFrame: attempt.nativeFrame,
            adjustedFrame: attempt.targetFrame,
            reliftCount: finalReliftCount,
            reason: reason,
            abandonedAt: at,
            standoffRounds: attempt.standoffRounds
        )
        return Transition(state: .abandoned(abandoned), action: .abandon(reason))
    }

    /// Below the standoff cap the normal reopen window applies; at the cap it drops to slow retries (no
    /// permanent lock).
    private static func abandonedReopenDelay(for session: AbandonedSession) -> TimeInterval {
        session.standoffRounds < maximumStandoffRounds ? appReassertWindow : standoffLockBackoff
    }

    /// Refreshes only the observation generation; abandonedAt/rounds/reason/frames stay as is, so the
    /// abandoned state expires on time.
    private static func refreshedAbandoned(
        _ session: AbandonedSession,
        observing generation: UInt64
    ) -> AbandonedSession {
        AbandonedSession(
            generation: generation,
            nativeFrame: session.nativeFrame,
            adjustedFrame: session.adjustedFrame,
            reliftCount: session.reliftCount,
            reason: session.reason,
            abandonedAt: session.abandonedAt,
            standoffRounds: session.standoffRounds
        )
    }

    private static func stateGeneration(of state: SessionState) -> UInt64? {
        switch state {
        case .idle:
            return nil
        case let .writing(attempt):
            return attempt.latestObservationGeneration
        case let .lifted(session):
            return session.generation
        case let .abandoned(session):
            return session.generation
        }
    }

    /// Which display a candidate window belongs to under multi-display (③④): the one holding more than half
    /// the area; else the largest overlap; no overlap -> nil. A window spanning displays therefore belongs to
    /// one display only and is not lifted by both displays' avoidance. **Same area rule as
    /// `Geometry.mostlyBelongsToScreen`, deliberately not shared** (that one is this type's private
    /// criterion; `PanelVisibilityState` has a third copy, each in its own rule file).
    static func owningContextIndex(for quartzFrame: CGRect, screenCGFrames: [CGRect]) -> Int? {
        guard isValid(frame: quartzFrame) else { return nil }
        let area = quartzFrame.width * quartzFrame.height
        var best: (index: Int, overlap: CGFloat)?
        for (index, screen) in screenCGFrames.enumerated() {
            guard isValid(frame: screen) else { continue }
            let overlap = quartzFrame.intersection(screen)
            guard !overlap.isNull, !overlap.isEmpty else { continue }
            let overlapArea = overlap.width * overlap.height
            if overlapArea >= area * 0.5 { return index }
            if best == nil || overlapArea > best!.overlap { best = (index, overlapArea) }
        }
        return best?.index
    }

    private static func isValid(frame: CGRect) -> Bool {
        frame.minX.isFinite
            && frame.minY.isFinite
            && frame.width.isFinite
            && frame.height.isFinite
            && frame.width > 0
            && frame.height > 0
    }

    private static func writingAttempt(
        _ attempt: WriteAttempt,
        observing generation: UInt64
    ) -> SessionState {
        .writing(WriteAttempt(
            generation: attempt.generation,
            latestObservationGeneration: max(generation, attempt.latestObservationGeneration),
            nativeFrame: attempt.nativeFrame,
            targetFrame: attempt.targetFrame,
            reliftCount: attempt.reliftCount,
            standoffRounds: attempt.standoffRounds
        ))
    }
}
