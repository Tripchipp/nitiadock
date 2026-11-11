import Foundation
import os

@MainActor
final class IntentPipeline {
    private let actionPlanning: LifecycleActionPlanner
    private(set) var feedbackState = IntentFeedbackState()
    private let logger = Logger(subsystem: "no.thilip.nitiadock", category: "intent-pipeline")

    init(actionPlanning: LifecycleActionPlanner) {
        self.actionPlanning = actionPlanning
    }

    func plan(
        intent: UserIntent,
        snapshot: DockSnapshot,
        optimisticStates: [String: OptimisticWindowState] = [:]
    ) -> PlatformActionRequest {
        actionPlanning.plan(intent: intent, snapshot: snapshot, optimisticStates: optimisticStates)
    }

    func canBegin(intent: UserIntent) -> Bool {
        feedbackState.canBegin(windowID: intent.windowID.rawValue)
    }

    func registerPending(intent: UserIntent, request: PlatformActionRequest) {
        feedbackState.begin(
            windowID: intent.windowID.rawValue,
            action: feedbackAction(for: request, fallback: intent.action),
            at: Date()
        )
    }

    func registerExecutionResult(intent: UserIntent, request: PlatformActionRequest, success: Bool) {
        let action = feedbackAction(for: request, fallback: intent.action)
        if success {
            feedbackState.markSucceededImmediatelyIfNeeded(
                windowID: intent.windowID.rawValue,
                action: action,
                at: Date()
            )
        } else {
            feedbackState.markFailed(windowID: intent.windowID.rawValue, action: action, at: Date())
        }
    }

    func reconcile(with snapshot: DockSnapshot) {
        let before = feedbackState.entriesByWindowID
        feedbackState.reconcile(snapshot: snapshot, now: Date())
        for (windowID, entry) in feedbackState.entriesByWindowID {
            if let old = before[windowID], old.phase == .pending, entry.phase != .pending {
                logger.info("[B-pending-cleared] t=\(CFAbsoluteTimeGetCurrent(), privacy: .public) windowID=\(windowID, privacy: .public) action=\(entry.action.rawValue, privacy: .public) → \(entry.phase.rawValue, privacy: .public)")
            }
        }
    }

    private func feedbackAction(
        for request: PlatformActionRequest,
        fallback: UserIntentAction
    ) -> UserIntentAction {
        switch request.kind {
        case .activateWindow:
            return .activate
        case .minimizeWindow:
            return .minimize
        case .hideApp:
            return .hide
        case .closeWindow:
            return .close
        case .quitApp:
            return .quit
        case .newWindow:
            return .newWindow
        }
    }
}

/// Pure check for whether the feedback timer should run.
///
/// Why it is extracted: `AppRuntime` constructs `AppTracker` / `PermissionService` itself (both
/// touch AX / CG) and cannot be brought up in unit tests, so this truth table can only be pinned
/// on a pure type. The rule is short, but one clause is load-bearing: **always false once the
/// runtime has stopped**. The detached execution callback of `AppRuntime.trigger()` returns to
/// the main thread and writes feedback state only after `stop()`; without this clause it would
/// revive the stopped timer, leaving the runtime stopped and the timer spinning every 0.5s.
enum FeedbackTickPolicy {
    /// - Parameters:
    ///   - isRunning: whether the runtime is running (`AppRuntime` feeds `snapshotSubscription != nil`).
    ///   - hasFeedbackEntries: whether `IntentFeedbackState` still has entries to reconcile.
    ///   - hasOptimisticStates: whether the optimistic overlay still has
    ///     entries waiting to be fulfilled or to time out and bounce back.
    static func shouldTick(
        isRunning: Bool,
        hasFeedbackEntries: Bool,
        hasOptimisticStates: Bool
    ) -> Bool {
        guard isRunning else { return false }
        return hasFeedbackEntries || hasOptimisticStates
    }
}

struct IntentFeedbackState {
    private(set) var entriesByWindowID: [String: Entry] = [:]

    func canBegin(windowID: String) -> Bool {
        guard let entry = entriesByWindowID[windowID] else { return true }
        return entry.phase != .pending
    }

    mutating func begin(windowID: String, action: UserIntentAction, at timestamp: Date) {
        let entry = Entry(
            windowID: windowID,
            action: action,
            phase: .pending,
            updatedAt: timestamp
        )
        entriesByWindowID[windowID] = entry
    }

    mutating func markSucceededImmediatelyIfNeeded(
        windowID: String,
        action: UserIntentAction,
        at timestamp: Date
    ) {
        // newWindow opens a *new* window (a different windowID), so it can never be
        // confirmed by reconciling this chip's snapshot status. Treat a successful
        // executor return as immediate success, same as activate.
        if action == .activate || action == .newWindow {
            update(windowID: windowID, phase: .success, at: timestamp)
        }
    }

    mutating func markFailed(windowID: String, action: UserIntentAction, at timestamp: Date) {
        update(windowID: windowID, phase: .failure, at: timestamp)
    }

    mutating func reconcile(snapshot: DockSnapshot, now: Date) {
        for (windowID, entry) in entriesByWindowID {
            if entry.phase == .pending,
               now.timeIntervalSince(entry.updatedAt) > entry.phase.retention {
                update(windowID: windowID, phase: .failure, at: now)
                continue
            }

            guard let typedWindowID = snapshot.orderedWindowIDs.first(where: { $0.rawValue == windowID }) ?? snapshot.windows.keys.first(where: { $0.rawValue == windowID }) else {
                if entry.action == .close {
                    update(windowID: windowID, phase: .success, at: now)
                }
                continue
            }

            guard let record = snapshot.windows[typedWindowID] else { continue }

            switch entry.action {
            case .toggle:
                break
            case .activate:
                if record.status == .active {
                    update(windowID: windowID, phase: .success, at: now)
                }
            case .minimize:
                if record.status == .minimized || record.status == .disappeared {
                    update(windowID: windowID, phase: .success, at: now)
                }
            case .hide:
                if record.status == .hidden || record.status == .disappeared {
                    update(windowID: windowID, phase: .success, at: now)
                }
            case .close:
                if record.status == .closedPending {
                    update(windowID: windowID, phase: .success, at: now)
                }
            case .quit:
                if record.status == .disappeared {
                    update(windowID: windowID, phase: .success, at: now)
                }
            case .newWindow:
                // Success was marked immediately on executor return; nothing to
                // reconcile here (the new window is a separate windowID).
                break
            }
        }

        entriesByWindowID = entriesByWindowID.filter { _, entry in
            now.timeIntervalSince(entry.updatedAt) <= entry.phase.retention
        }
    }

    /// Writes only when **the phase actually changed**.
    ///
    /// Why this gate exists: `reconcile` re-runs the check on fulfilled entries every round. While
    /// the window stays in the target state (minimized / hidden / activated), `updatedAt` used to be
    /// overwritten with now every round, so that success never reached its 1.5s expiry and the entry
    /// dictionary never emptied. The old always-on timer hid this (it ran anyway); with on-demand
    /// running it would keep the timer from ever stopping and defeat the whole optimization.
    ///
    /// But only "same-phase repeated refresh" may be frozen; terminal states must **not** all be
    /// skipped. An AX action may have taken effect while the immediate read-back still returns false
    /// (`AccessibilitySource.minimize` reads `kAXMinimizedAttribute` right after pressing the button;
    /// minimizing is animated, so that read often lags). It is then recorded as failure first and
    /// corrected to success by a later real snapshot. The `failure → success` upgrade path must stay.
    private mutating func update(windowID: String, phase: FeedbackPhase, at timestamp: Date) {
        guard var entry = entriesByWindowID[windowID], entry.phase != phase else { return }
        entry.phase = phase
        entry.updatedAt = timestamp
        entriesByWindowID[windowID] = entry
    }

    struct Entry: Hashable {
        let windowID: String
        let action: UserIntentAction
        var phase: FeedbackPhase
        var updatedAt: Date
    }

    enum FeedbackPhase: String, Hashable {
        case pending
        case success
        case failure

        var retention: TimeInterval {
            switch self {
            case .pending:
                return 4.0
            case .success, .failure:
                return 1.5
            }
        }
    }
}
