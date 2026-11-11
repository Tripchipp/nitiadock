import CoreGraphics
import Foundation

/// Per-candidate probe gate for `scanNonAdmittedApps()`. Before this change every background regular app that
/// would never be admitted took a 100ms-timeout AX probe every 5 seconds, forever; this gate uses two free
/// criteria to bring steady-state probing down to zero:
/// - **CG presence**: the candidate has no window in this tick's full CG table (layer 0, including
///   minimized/hidden/other Spaces), so there is nothing to admit (creating a seat needs a resolvable
///   cgWindowID): skip.
/// - **Memory**: the last probe concluded "no eligible windows", the process generation is unchanged and
///   the CG window set is unchanged, so the conclusion still holds: skip. `.unread` (hung app) is **never
///   remembered** and keeps the original 5s retry.
/// Three forced-probe fallbacks take priority over any skip: CG capture failure (failure and empty set are
/// indistinguishable, hard constraint), the 60s slow full scan coming due (closes any gate hole),
/// and a workspace launch notification marking dirty.
/// The four rescans at 0.5/1/2/4s after launch bypass this gate entirely (not passing a tick snapshot is the
/// bypass).
enum ScanProbeGateDecision {
    static let defaultFullScanInterval: TimeInterval = 60

    struct Memo: Equatable {
        var identity: ScanAdmissionDecision.ProcessIdentity
        var lastCGIDs: Set<CGWindowID>
        var verdictWasNoEligible: Bool
    }

    struct Input {
        var captureFailed: Bool
        var cgWindowIDs: Set<CGWindowID>
        var memo: Memo?
        var currentIdentity: ScanAdmissionDecision.ProcessIdentity
        var workspaceDirty: Bool
        var slowFullScanDue: Bool
    }

    enum Reason: String, Equatable {
        case captureFailed
        case fullScanDue
        case workspaceDirty
        case noMemo
        case identityChanged
        case cgSetChanged
        case memoNotConclusive
    }

    enum Verdict: Equatable {
        case probe(Reason)
        case skipNoCGWindows
        case skipMemoized
    }

    static func verdict(_ input: Input) -> Verdict {
        if input.captureFailed { return .probe(.captureFailed) }
        if input.slowFullScanDue { return .probe(.fullScanDue) }
        if input.workspaceDirty { return .probe(.workspaceDirty) }
        if input.cgWindowIDs.isEmpty { return .skipNoCGWindows }
        guard let memo = input.memo else { return .probe(.noMemo) }
        guard ScanAdmissionDecision.ProcessIdentity.matches(
            probed: memo.identity,
            current: input.currentIdentity
        ) else { return .probe(.identityChanged) }
        if memo.lastCGIDs != input.cgWindowIDs { return .probe(.cgSetChanged) }
        guard memo.verdictWasNoEligible else { return .probe(.memoNotConclusive) }
        return .skipMemoized
    }
}
