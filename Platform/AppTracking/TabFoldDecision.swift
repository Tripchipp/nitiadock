import CoreGraphics
import Foundation

/// Pure decision layer for Pass B "minimized fold": is an unclaimed eligible window that AX reports as
/// minimized a background tab of an already seated physical window (fold, no new seat), or a truly
/// independent window (new seat)?
///
/// Background: when a multi-tab window is minimized, Ghostty exposes all of its tabs as AX windows at once,
/// all reporting min=true. Background tabs are order-out windows and get no moved/resized notifications, so
/// after the window has been moved or resized their AX position and size are stale and pure geometry matching
/// fails (one card split off per tab).
///
/// Four decision levels, strongest first:
/// 1. **Membership**: the candidate cgID was once the activeCgID of a placed seat (a tab becomes the
///    active tab on creation, so every background tab has been in its seat's history). Independent of
///    geometry and the min flag, so it covers both fold failures: stale AX geometry after move/resize and the
///    min-lag race. The history is **session state** (cleared on dock restart).
/// 2. **Shadow tab pool**: in the previous reconcile the candidate cgID was in the full CG list but not in
///    AXWindows. That signature is unique to order-out background tabs (a real window is always in AXWindows
///    whether visible, minimized, hidden or on another Space). The pool is rebuilt from live signals every
///    round, so it is **immune to dock restarts** and is the restart-safe layer once membership history is
///    cleared. Only applies when a seat is already placed: with zero seats nothing folds (the representative
///    tab of a truly minimized window group must be able to get a seat).
/// 3. **Exact frame match**: a background tab has the same frame as its window, pixel for pixel (holds
///    while the window has not moved).
/// 4. **Size fallback**: same width/height ±3 + offscreen + the matching seat is marked minimized (holds
///    when the window was moved but not resized).
/// All four fail: new seat (a potential split point for min=true candidates, the caller logs a diagnostic).
enum TabFoldDecision {

    /// Fold-view summary of the seats placed in this reconcile. `activeCgID` is only a write-back index
    /// (membership learning), not an identity.
    struct PlacedSeat {
        let activeCgID: CGWindowID
        let bounds: CGRect?
        let isMinimized: Bool
        let formerCgIDs: Set<CGWindowID>
    }

    enum Reason: String {
        case membership   // was once this seat's active tab
        case shadowPool   // in CG but not in AX last round (order-out background tab signature)
        case exactFrame   // frame matches pixel for pixel
        case sameSize     // same size + offscreen fallback
    }

    enum Verdict: Equatable {
        /// Fold into an existing seat, no new one. `ownerActiveCgID` non-nil = ownership is unambiguous and
        /// the caller may record the candidate cgID in that seat's history (membership learning: the next
        /// fold no longer depends on geometry); nil = ownership is ambiguous, fold without learning.
        case fold(ownerActiveCgID: CGWindowID?, reason: Reason)
        case newSeat
    }

    static func verdict(
        candidateCgID: CGWindowID,
        candidateBounds: CGRect?,
        candidateIsMinimized: Bool,
        candidateIsOnScreen: Bool,
        candidateIsKnownShadow: Bool,
        placedSeats: [PlacedSeat],
        frameKey: (CGRect?) -> String?
    ) -> Verdict {
        // An unclaimed non-min window is a legitimate new window (including "two independent windows
        // overlapping" and "a torn-out tab becoming visible"), so it gets a new seat as usual. The shadow
        // pool never applies to min=false candidates.
        guard candidateIsMinimized else { return .newSeat }

        // 1. Membership
        let owners = placedSeats.filter { $0.formerCgIDs.contains(candidateCgID) }
        if owners.count == 1 { return .fold(ownerActiveCgID: owners[0].activeCgID, reason: .membership) }
        if owners.count > 1 { return .fold(ownerActiveCgID: nil, reason: .membership) }

        // 2. Shadow tab pool: single seat = ownership + learning; several seats = fold without learning
        // (better to learn less than record wrongly). Zero seats do not fold, otherwise a truly minimized
        // window group could not get even one card.
        if candidateIsKnownShadow, !placedSeats.isEmpty {
            if placedSeats.count == 1 { return .fold(ownerActiveCgID: placedSeats[0].activeCgID, reason: .shadowPool) }
            return .fold(ownerActiveCgID: nil, reason: .shadowPool)
        }

        // 3. Exact frame match
        if let key = frameKey(candidateBounds) {
            let matches = placedSeats.filter { frameKey($0.bounds) == key }
            if matches.count == 1 { return .fold(ownerActiveCgID: matches[0].activeCgID, reason: .exactFrame) }
            if matches.count > 1 { return .fold(ownerActiveCgID: nil, reason: .exactFrame) }
        }

        // 4. Size fallback: offscreen (inactive tab) + same width/height as a placed minimized seat
        if !candidateIsOnScreen, let sb = candidateBounds {
            let matches = placedSeats.filter { seat in
                guard seat.isMinimized, let pb = seat.bounds else { return false }
                return abs(pb.size.width - sb.size.width) < 3 &&
                       abs(pb.size.height - sb.size.height) < 3
            }
            if matches.count == 1 { return .fold(ownerActiveCgID: matches[0].activeCgID, reason: .sameSize) }
            if matches.count > 1 { return .fold(ownerActiveCgID: nil, reason: .sameSize) }
        }

        return .newSeat
    }
}

/// Pure decision layer for Pass A "merged into a tab": a placed seat, **not minimized and app not hidden**,
/// whose activeCgID left AX this round but is still in CG with no destroy tombstone. Was it merged into
/// another window ("Merge All Windows" / dragging the tab into another window's tab bar), or is it just a
/// missed AX read?
///
/// Native tabs = N real NSWindows; after a merge the original window becomes an order-out background tab:
/// gone from AX, still in CG, `onscreen=false`, and its CG bounds changed by the system to the owning
/// window's frame. This path used to keep the seat unconditionally ("absence from AX does not prove the
/// window closed"), giving one window two cards; then two old seats shared the same frame, the tab-switch
/// takeover rule refused to take over, and every switch split off another card (measured 2026-09-12).
///
/// Release conditions (all required): the candidate is **not on screen** in CG (when a truly visible window
/// is misread, CG says onscreen=true and nothing is released); the candidate's **CG bounds** (not the stale
/// AX frame in the seat) match, pixel for pixel, the frame of at least one sibling seat that is **present in
/// AX with min=false**. When ownership is unique the owner is returned and the caller records the candidate
/// in its history (the next minimize burst folds instantly by membership).
enum TabMergeDecision {

    /// Summary of sibling seats present in AX this round (activeCgID still in eligible); `bounds` is the
    /// frame from this round's AX snapshot.
    struct AXPresentSeat {
        let activeCgID: CGWindowID
        let bounds: CGRect?
        let isMinimized: Bool
    }

    enum Verdict: Equatable {
        /// Merged into a tab: release the seat. `ownerActiveCgID` non-nil = unique ownership, the caller does
        /// membership learning.
        case release(ownerActiveCgID: CGWindowID?)
        case retain
    }

    static func verdict(
        candidateIsOnScreen: Bool,
        candidateCGBounds: CGRect?,
        candidateSeatBounds: CGRect?,
        axPresentSeats: [AXPresentSeat],
        frameKey: (CGRect?) -> String?
    ) -> Verdict {
        guard !candidateIsOnScreen else { return .retain }
        guard let key = frameKey(candidateCGBounds ?? candidateSeatBounds) else { return .retain }
        let owners = axPresentSeats.filter { !$0.isMinimized && frameKey($0.bounds) == key }
        if owners.count == 1 { return .release(ownerActiveCgID: owners[0].activeCgID) }
        if owners.count > 1 { return .release(ownerActiveCgID: nil) }
        return .retain
    }
}

/// Pure decision layer for phantom seat self-healing.
///
/// Phantom seat = an extra seat split off from a min=true burst candidate when the fold decision misses
/// (typical case: the window was already minimized at dock launch, and seed has no history and no shadow
/// pool). It is marked min=true and held forever by the "minimizing does not release the seat" retention
/// rule: after the window is restored its cgID merely leaves AX while staying in CG, so the card stays split.
///
/// Five self-healing gates (release only if all hold; better not to heal than to delete wrongly):
/// - `everSeenVisible == false`: the seat's activeCgID has never appeared in AX with min=false in this
///   session. A real window has almost certainly been visible; this gate protects Safari-style real windows
///   that leave AX entirely once minimized.
/// - Absent from AX for ≥ threshold consecutive rounds: not just a missed read or two.
/// - cgID still in CG: if not, it is a real close and takes the existing delete path, not self-healing.
/// - This round's AX read returned windows for the app: do nothing when the app hangs or the AX read fails.
/// - At least one seat of the same pid is currently in AX: a lone seat never self-heals (avoids deleting an
///   app's only card).
enum PhantomSeatDecision {
    enum HoldReason: String, Codable, Hashable {
        case everSeenVisible
        case absenceGraceNotElapsed
        case cgMissing
        case noEligibleWindows
        case noAXPresentSibling
    }

    struct Evaluation: Equatable {
        let shouldRelease: Bool
        let holdReasons: Set<HoldReason>
    }

    static func evaluate(
        everSeenVisible: Bool,
        axAbsentFor: TimeInterval,
        threshold: TimeInterval,
        cgStillPresent: Bool,
        axReadSawWindows: Bool,
        axPresentSiblingCount: Int
    ) -> Evaluation {
        var reasons: Set<HoldReason> = []
        if everSeenVisible { reasons.insert(.everSeenVisible) }
        if axAbsentFor < threshold { reasons.insert(.absenceGraceNotElapsed) }
        if !cgStillPresent { reasons.insert(.cgMissing) }
        if !axReadSawWindows { reasons.insert(.noEligibleWindows) }
        if axPresentSiblingCount < 1 { reasons.insert(.noAXPresentSibling) }
        return Evaluation(shouldRelease: reasons.isEmpty, holdReasons: reasons)
    }

    static func shouldRelease(
        everSeenVisible: Bool,
        axAbsentFor: TimeInterval,
        threshold: TimeInterval,
        cgStillPresent: Bool,
        axReadSawWindows: Bool,
        axPresentSiblingCount: Int
    ) -> Bool {
        evaluate(
            everSeenVisible: everSeenVisible,
            axAbsentFor: axAbsentFor,
            threshold: threshold,
            cgStillPresent: cgStillPresent,
            axReadSawWindows: axReadSawWindows,
            axPresentSiblingCount: axPresentSiblingCount
        ).shouldRelease
    }
}
