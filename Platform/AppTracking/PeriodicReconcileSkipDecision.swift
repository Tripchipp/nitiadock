import CoreGraphics
import Foundation

/// Per-pid skip gate of the periodic reconcile (5s tick). The AX read of a pid may be skipped **only when
/// every condition holds**; any one failing forces a full read. A skipped round follows the existing
/// `.unread` semantics (seats, absence clock, shadow pool and phantom state all stay unadvanced). Conditions
/// and reasons (guardrails, change with care):
/// - `captureFailed`: this round's CG capture failed -> "nothing changed" cannot be established, force a full
///   read (hard constraint).
/// - `neverRead`: this pid has never had a successful full read.
/// - `refreshDue`: ≥ `maxSkipInterval` since the last successful full read (monotonic clock), the fallback
///   for silent drift with no events and an unchanged CG (the only known real case is native tab switching,
///   which happens only in the foreground and is covered by the 2Hz frontmost poll).
/// - `observerInactive`: this pid's AXObserver was never created (AXObserverCreate can fail); without event
///   coverage it is never skipped.
/// - `lastReadUnread`: the last read hung and must be retried.
/// - `dirtyEvents`: there were AX / workspace events for this pid since the last successful full read.
/// - `cgSetChanged`: this pid's CG layer-0 window id set changed (a real close / new window / tab switch
///   always changes the CG set).
/// - `absenceClockRunning`: a seat has its absence clock running (minAbsentSince). Phantom evidence must be
///   sampled at the original 5s cadence; skipping would slow self-heal.
/// - `phantomCandidate`: a seat with everSeenVisible == false exists. It may start an absence episode without
///   any event, so forcing the read keeps phantom self-heal latency exactly as before the change (≤ 10s grace
///   plus 5s tick).
/// - `lastRoundChanged`: the previous round's landing changed the seat signature or shadow pool ->
///   convergence is not done, keep reading.
enum PeriodicReconcileSkipDecision {
    static let defaultMaxSkipInterval: TimeInterval = 30

    struct Input {
        var captureFailed: Bool
        var currentCGIDs: Set<CGWindowID>
        /// The pid's CG window id set at the last successful full read; nil = not read yet.
        var lastObservedCGIDs: Set<CGWindowID>?
        var dirtySinceLastRead: Bool
        var hasAbsenceClock: Bool
        var hasPhantomCandidate: Bool
        var lastReadWasUnread: Bool
        var lastRoundChanged: Bool
        var observerActive: Bool
        var uptimeSinceLastFullRead: TimeInterval
        var maxSkipInterval: TimeInterval = PeriodicReconcileSkipDecision.defaultMaxSkipInterval
    }

    enum Reason: String, Equatable {
        case captureFailed
        case neverRead
        case refreshDue
        case observerInactive
        case lastReadUnread
        case dirtyEvents
        case cgSetChanged
        case absenceClockRunning
        case phantomCandidate
        case lastRoundChanged
    }

    enum Verdict: Equatable {
        case fullRead(Reason)
        case skip
    }

    static func verdict(_ input: Input) -> Verdict {
        if input.captureFailed { return .fullRead(.captureFailed) }
        guard let lastObserved = input.lastObservedCGIDs else { return .fullRead(.neverRead) }
        if input.uptimeSinceLastFullRead >= input.maxSkipInterval { return .fullRead(.refreshDue) }
        if !input.observerActive { return .fullRead(.observerInactive) }
        if input.lastReadWasUnread { return .fullRead(.lastReadUnread) }
        if input.dirtySinceLastRead { return .fullRead(.dirtyEvents) }
        if input.currentCGIDs != lastObserved { return .fullRead(.cgSetChanged) }
        if input.hasAbsenceClock { return .fullRead(.absenceClockRunning) }
        if input.hasPhantomCandidate { return .fullRead(.phantomCandidate) }
        if input.lastRoundChanged { return .fullRead(.lastRoundChanged) }
        return .skip
    }
}
