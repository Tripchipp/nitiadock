import Foundation

/// Pure admission decision layer for the rescan (`AppTracker.scanNonAdmittedApps`).
///
/// The rescan picks up apps that did not answer at seed time. It must follow the same two rules as seed, both
/// of which have bitten before:
///
/// 1. **Admission looks at the eligible-filtered set, not the raw AX list**. A non-empty raw list does not
///    mean there is a window fit for the taskbar: transparent panels, extensions and system-internal windows
///    are all in AX. A wrong admission is permanent: `reconcile()` only clears dead processes, **a live
///    `AppEntry` with zero seats is never deleted**, so `rebuildSnapshot` keeps projecting its `app-*`
///    fallback record and the taskbar is left with an app-level card that cannot be removed.
/// 2. **The filtering happens here and its result is handed to the caller as is**. If this type only took
///    an `eligibleCount: Int`, production code passing `snaps.count` by mistake, which is exactly this bug's
///    failure mode, would still leave the unit tests green. So `prepare` runs the filter itself and carries
///    the `eligible` array out, and `AppTracker` feeds it straight to `reconcileSeats(preloadedEligible:)`,
///    which also avoids a second AX read without a timeout.
///
/// The window type is generic: `AXWindowSnapshot` holds a non-optional `AXUIElement` that unit tests cannot
/// construct; with generics the tests cover the filter wiring using a fake window type, and the pure decision
/// layer does not need ApplicationServices.
enum ScanAdmissionDecision {

    /// Process generation identity. Pids are reused: the AX element obtained by a background probe belongs to
    /// the process instance at probe time, so the callback must confirm the pid still maps to the same
    /// instance. `startTime` comes from POSIX `ProcessLiveness.startTime(pid:)` (always present for a live
    /// process).
    struct ProcessIdentity: Equatable {
        let pid: pid_t
        let startTimeSec: Int64?
        let startTimeUsec: Int32?
        let bundleID: String?

        init(pid: pid_t, startTimeSec: Int64?, startTimeUsec: Int32?, bundleID: String?) {
            self.pid = pid
            self.startTimeSec = startTimeSec
            self.startTimeUsec = startTimeUsec
            self.bundleID = bundleID
        }

        /// All three must be equal to count as the same process instance. A missing start time on either side
        /// means no match (conservative): an unreadable start time means the process is gone and should not
        /// be admitted; the next rescan handles it.
        static func matches(probed: Self, current: Self) -> Bool {
            guard probed.pid == current.pid, probed.bundleID == current.bundleID else { return false }
            guard let probedSec = probed.startTimeSec, let currentSec = current.startTimeSec,
                  let probedUsec = probed.startTimeUsec, let currentUsec = current.startTimeUsec
            else { return false }
            return probedSec == currentSec && probedUsec == currentUsec
        }
    }

    /// Filter result of one probe. `eligible` is the set handed to `reconcileSeats` after admission.
    struct Prepared<Window> {
        let eligible: [Window]
        let rawCount: Int
        let readFailed: Bool
    }

    enum Verdict: Equatable {
        case admit
        case skipNotRegular
        case skipTerminated
        case skipAlreadyTracked
        case skipIdentityMismatch
        case skipUnread
        case skipNoEligible
    }

    /// `rawWindows == nil` means this AX read failed (`.unread`), as opposed to reading 0 windows: the former
    /// just did not answer, the latter really has no windows.
    static func prepare<Window>(
        rawWindows: [Window]?,
        isEligible: (Window) -> Bool
    ) -> Prepared<Window> {
        guard let rawWindows else {
            return Prepared(eligible: [], rawCount: 0, readFailed: true)
        }
        return Prepared(
            eligible: rawWindows.filter(isEligible),
            rawCount: rawWindows.count,
            readFailed: false
        )
    }

    /// Decision order: process state, process generation, read result, eligible windows.
    /// The generation comparison is done internally (no `identityMatches: Bool` parameter, which could be
    /// passed wrong just the same).
    static func verdict<Window>(
        _ prepared: Prepared<Window>,
        probedIdentity: ProcessIdentity,
        currentIdentity: ProcessIdentity,
        isRegularNonSelf: Bool,
        isTerminated: Bool,
        alreadyTracked: Bool
    ) -> Verdict {
        if !isRegularNonSelf { return .skipNotRegular }
        if isTerminated { return .skipTerminated }
        if alreadyTracked { return .skipAlreadyTracked }
        if !ProcessIdentity.matches(probed: probedIdentity, current: currentIdentity) {
            return .skipIdentityMismatch
        }
        if prepared.readFailed { return .skipUnread }
        if prepared.eligible.isEmpty { return .skipNoEligible }
        return .admit
    }
}
