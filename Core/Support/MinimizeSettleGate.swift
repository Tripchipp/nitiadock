import Foundation

/// Settle decision for rapid "minimize -> activate" clicks on the same window (v2, 2026-08-25).
///
/// v1 (time gate: 0.65s settle floor + 1.0s cap) was rejected in real use: (1) the floor ruined
/// the "reverse the genie mid-way" feel; (2) one Finder restore measured 887ms, so after the
/// 1.0s anchor expired the click ran unprotected and siblings were still brought out.
///
/// v2 semantics: **release on confirmation, safety does not rely on waiting**. Snapshot confirming
/// `.minimized` = the minimize write has landed in the target app (a write-order proof against the
/// minimize still executing concurrently) -> release immediately; the execution layer, holding the
/// `dispatchPrior` prior, forces the restore branch (07-05 v3 order, measured safe 5/5; writing
/// unminimize to a non-minimized window is a harmless no-op), skips earlyFocus and seals the app-level
/// fallback. All three promotion paths of "switch to foreground first while the window is off screen"
/// are blocked, and an unminimize landing mid-genie reverses the animation (the source of the feel).
enum MinimizeSettleGate {
    enum Verdict: Equatable {
        case dispatchNow
        case hold(until: Date)
    }

    /// Hold cap while unconfirmed: if the minimize really failed, the second click is stuck
    /// at most this long, then released anyway (the execution layer still carries the prior).
    static let maxHold: TimeInterval = 1.0
    /// Prior window (the anchor's second lifetime): any activate within this long after the minimize
    /// dispatch carries the "force knownMinimized + skip earlyFocus + seal the app fallback" prior.
    /// 2.0s ≈ worst measured animation (Finder 887ms) × 2 + margin for the snapshot to come back;
    /// the prior costs nothing (safe in both worlds), so it can be much wider than the hold cap.
    /// Tunable constant, calibrated against the Finder storm acceptance test.
    static let priorWindow: TimeInterval = 2.0

    static func verdict(
        requestKind: PlatformActionRequest.ActionKind,
        minimizeDispatchedAt: Date?,
        snapshotConfirmsMinimized: Bool,
        now: Date,
        maxHold: TimeInterval = Self.maxHold
    ) -> Verdict {
        guard requestKind == .activateWindow, let anchor = minimizeDispatchedAt else {
            return .dispatchNow
        }
        let elapsed = now.timeIntervalSince(anchor)
        // Clock anomaly (anchor in the future): release conservatively, back to the old rapid-click behavior.
        if elapsed < 0 { return .dispatchNow }
        if elapsed >= maxHold { return .dispatchNow }
        // v2 core: release on confirmation. The snapshot flipping is the proof the write landed; the
        // dangerous branches during the animation are sealed by the prior, no longer blocked by time.
        if snapshotConfirmsMinimized { return .dispatchNow }
        return .hold(until: anchor.addingTimeInterval(maxHold))
    }

    /// The "force knownMinimized + skip earlyFocus + seal the app
    /// fallback" prior: holds while the anchor is within the prior window.
    /// A clock anomaly (negative elapsed) gives no prior and falls back to the old behavior entirely.
    static func dispatchPrior(
        minimizeDispatchedAt: Date?,
        now: Date,
        priorWindow: TimeInterval = Self.priorWindow
    ) -> Bool {
        guard let anchor = minimizeDispatchedAt else { return false }
        let elapsed = now.timeIntervalSince(anchor)
        return elapsed >= 0 && elapsed < priorWindow
    }
}
