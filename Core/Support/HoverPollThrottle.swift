import Foundation

/// Coalescing throttle for mouse-move events (pure decision). Global/local `.mouseMoved` monitors
/// call back over a hundred times a second while moving, and the consumers (multi-screen hover
/// switching needs a 350ms dwell, edge wake hot-zone checks) cannot tell a 33ms granularity apart.
/// Semantics = leading + trailing: a due event runs immediately; an event inside the window schedules
/// **one** trailing run (when movement stops inside the throttle window the last position must not be
/// lost, since hot-zone enter/exit depends on it); if a trailing run is already scheduled it is dropped.
struct HoverPollThrottle {
    let minInterval: TimeInterval
    private(set) var lastRunAt: TimeInterval = -.infinity
    private(set) var trailingScheduled = false

    enum Verdict: Equatable {
        case run
        case scheduleTrailing(after: TimeInterval)
        case drop
    }

    mutating func eventArrived(now: TimeInterval) -> Verdict {
        let elapsed = now - lastRunAt
        if elapsed >= minInterval {
            lastRunAt = now
            return .run
        }
        if trailingScheduled { return .drop }
        trailingScheduled = true
        return .scheduleTrailing(after: minInterval - elapsed)
    }

    mutating func trailingFired(now: TimeInterval) {
        trailingScheduled = false
        lastRunAt = now
    }

    /// Reset when the monitor is removed/reinstalled, so the
    /// previous run's pending state does not leak into the next.
    mutating func reset() {
        lastRunAt = -.infinity
        trailingScheduled = false
    }
}
