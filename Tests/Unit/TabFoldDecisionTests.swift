import CoreGraphics
import XCTest

/// Pass B "minimize folding" pure decision layer (TabFoldDecision).
/// Background: when Ghostty minimizes a multi-tab window it exposes every tab as an AX window with min=true;
/// background tabs are order-out windows whose AX geometry stays stale after a move/resize. Four decision
/// levels: membership → shadow tab pool → exact frame match → size fallback. Shadow pool = ids that were "in
/// CG but not in AX" last round (the order-out tab signature, immune to dock restarts).
final class TabFoldDecisionTests: XCTestCase {

    // Test key with the same structure as AppTracker.frameKey (a fixed pid is enough)
    private func fk(_ b: CGRect?) -> String? {
        guard let b else { return nil }
        return "\(Int(b.origin.x.rounded())):\(Int(b.origin.y.rounded())):\(Int(b.size.width.rounded())):\(Int(b.size.height.rounded()))"
    }

    private func seat(
        cg: CGWindowID, bounds: CGRect?, min: Bool = true, former: Set<CGWindowID> = []
    ) -> TabFoldDecision.PlacedSeat {
        TabFoldDecision.PlacedSeat(activeCgID: cg, bounds: bounds, isMinimized: min, formerCgIDs: former)
    }

    private func verdict(
        cg: CGWindowID, bounds: CGRect?, min: Bool = true, onScreen: Bool = false,
        shadow: Bool = false, placed: [TabFoldDecision.PlacedSeat]
    ) -> TabFoldDecision.Verdict {
        TabFoldDecision.verdict(
            candidateCgID: cg, candidateBounds: bounds,
            candidateIsMinimized: min, candidateIsOnScreen: onScreen,
            candidateIsKnownShadow: shadow, placedSeats: placed, frameKey: fk
        )
    }

    private let frame = CGRect(x: 172, y: 87, width: 1191, height: 831)

    // MARK: - Locking existing behavior

    func testSameFrameBackgroundTabFolds() {
        // Window never moved: background tab and seat have the pixel-identical frame → exact-match fold
        let v = verdict(cg: 240522, bounds: frame, placed: [seat(cg: 249469, bounds: frame)])
        XCTAssertEqual(v, .fold(ownerActiveCgID: 249469, reason: .exactFrame))
    }

    func testMovedWindowFoldsBySizeFallback() {
        // Window moved: background tab coordinates are stale (old position), size unchanged → size-fallback
        // fold (6412015 behavior)
        let moved = frame.offsetBy(dx: 300, dy: -60)
        let v = verdict(cg: 240522, bounds: frame, placed: [seat(cg: 249469, bounds: moved)])
        XCTAssertEqual(v, .fold(ownerActiveCgID: 249469, reason: .sameSize))
    }

    func testNonMinimizedOverlappingWindowGetsNewSeat() {
        // A non-min window with the same frame = the legal case of two separate overlapping windows → new
        // seat as usual
        let v = verdict(cg: 240522, bounds: frame, min: false, onScreen: true,
                        placed: [seat(cg: 249469, bounds: frame, min: false)])
        XCTAssertEqual(v, .newSeat)
    }

    func testOnScreenCandidateDoesNotSizeMatch() {
        // An on-screen window is not a background tab: no size fallback even at the same size (a separate
        // window gets its own seat)
        let moved = frame.offsetBy(dx: 300, dy: 0)
        let v = verdict(cg: 240522, bounds: frame, onScreen: true,
                        placed: [seat(cg: 249469, bounds: moved)])
        XCTAssertEqual(v, .newSeat)
    }

    // MARK: - Hole 1: geometry fully stale after resize → membership covers it

    func testResizedWindowSplitsWithoutMembership() {
        // Resized window: background tab coordinates and size are both stale → exact match and size fallback
        // both fail. No membership and not in the shadow pool (e.g. first round after a dock restart) → can
        // only create a new seat (locks that this gap exists).
        let resized = CGRect(x: 172, y: 87, width: 900, height: 600)
        let v = verdict(cg: 240522, bounds: frame, placed: [seat(cg: 249469, bounds: resized)])
        XCTAssertEqual(v, .newSeat)
    }

    func testResizedWindowFoldsByMembership() {
        // Same as above, but the candidate was once the seat's active tab → membership fold, independent of
        // geometry (hole 1 fixed at the root)
        let resized = CGRect(x: 172, y: 87, width: 900, height: 600)
        let v = verdict(cg: 240522, bounds: frame,
                        placed: [seat(cg: 249469, bounds: resized, former: [240522])])
        XCTAssertEqual(v, .fold(ownerActiveCgID: 249469, reason: .membership))
    }

    // MARK: - Hole 2: min lag race → membership ignores the min flag

    func testMinLagRaceFoldsByMembership() {
        // At the moment of minimizing: background tabs are already exposed (min=true), but the active seat's
        // min has not flipped to true yet (AX lag), and the window has moved (exact match already failed).
        // The size fallback is blocked by the min requirement → the old logic split; membership fold ignores
        // the seat's min flag → folds (hole 2 fixed at the root)
        let moved = frame.offsetBy(dx: 300, dy: -60)
        let v = verdict(cg: 240522, bounds: frame,
                        placed: [seat(cg: 249469, bounds: moved, min: false, former: [240522])])
        XCTAssertEqual(v, .fold(ownerActiveCgID: 249469, reason: .membership))
    }

    func testMinLagRaceWithoutMembershipStillSplits() {
        // Same race, no membership, not in the shadow pool: size fallback still requires the seat to be
        // marked min (conservative, avoids merging separate windows) → new seat
        let moved = frame.offsetBy(dx: 300, dy: -60)
        let v = verdict(cg: 240522, bounds: frame,
                        placed: [seat(cg: 249469, bounds: moved, min: false)])
        XCTAssertEqual(v, .newSeat)
    }

    // MARK: - Shadow tab pool (restart-safe layer once a dock restart wipes membership history)

    func testShadowPoolFoldsDespiteStaleGeometryAndMinLag() {
        // Core of gap A: empty history after a dock restart + window moved and resized (both geometry
        // checks fail) + min lag race (seat min not yet true). The candidate was in CG but not in AX
        // last round (shadow tab signature) → pool fold, attribution to the only seat + learning.
        let resized = CGRect(x: 500, y: 300, width: 900, height: 600)
        let v = verdict(cg: 240522, bounds: frame, shadow: true,
                        placed: [seat(cg: 249469, bounds: resized, min: false)])
        XCTAssertEqual(v, .fold(ownerActiveCgID: 249469, reason: .shadowPool))
    }

    func testShadowPoolRequiresMinimizedCandidate() {
        // A torn-out tab becomes visible: it was a shadow last round (order-out), now min=false → must get
        // its own card, the pool does not block
        let v = verdict(cg: 240522, bounds: frame.offsetBy(dx: 400, dy: 0), min: false,
                        onScreen: true, shadow: true,
                        placed: [seat(cg: 249469, bounds: frame, min: false)])
        XCTAssertEqual(v, .newSeat)
    }

    func testShadowPoolWithNoPlacedSeatsCreatesSeat() {
        // With zero placed seats the pool does not fold, otherwise a truly minimized window group could not
        // even build one representative card
        let v = verdict(cg: 240522, bounds: frame, shadow: true, placed: [])
        XCTAssertEqual(v, .newSeat)
    }

    func testShadowPoolMultiSeatFoldsWithoutLearning() {
        // Ambiguous attribution across several seats: still fold (no card split), but attribution nil = no
        // learning (better to learn less than record wrongly)
        let v = verdict(cg: 240522, bounds: CGRect(x: 1, y: 2, width: 300, height: 200), shadow: true,
                        placed: [seat(cg: 249469, bounds: frame),
                                 seat(cg: 253982, bounds: frame.offsetBy(dx: 40, dy: 40))])
        XCTAssertEqual(v, .fold(ownerActiveCgID: nil, reason: .shadowPool))
    }

    func testMembershipWinsOverShadowPool() {
        // Membership beats the shadow pool: with several seats the pool can only fold, not attribute;
        // membership attributes exactly → check membership first
        let v = verdict(cg: 240522, bounds: frame, shadow: true,
                        placed: [seat(cg: 249469, bounds: frame.offsetBy(dx: 500, dy: 0), former: [240522]),
                                 seat(cg: 253982, bounds: frame)])
        XCTAssertEqual(v, .fold(ownerActiveCgID: 249469, reason: .membership))
    }

    func testRealMinimizedWindowNotInShadowPoolGetsSeat() {
        // A separate window truly minimized at seed: min=true but in AX from the start (not a shadow),
        // geometry not matching any existing seat → new seat as usual (must not be folded away)
        let v = verdict(cg: 240522, bounds: CGRect(x: 50, y: 50, width: 400, height: 300),
                        placed: [seat(cg: 249469, bounds: frame)])
        XCTAssertEqual(v, .newSeat)
    }

    // MARK: - Mis-merge guard / ambiguity

    func testReusedCgIDAfterPurgeDoesNotFold() {
        // cgID reuse protection at the decision level: after destruction the history/shadow pool is purged
        // (purgeFromSeatHistories/CG intersection), so a reused cgID is in no seat history → geometry only;
        // no geometry match means a new seat, no wrong absorption
        let v = verdict(cg: 240522, bounds: CGRect(x: 50, y: 50, width: 400, height: 300),
                        placed: [seat(cg: 249469, bounds: frame)])
        XCTAssertEqual(v, .newSeat)
    }

    func testAmbiguousMembershipFoldsWithoutLearning() {
        // Two seat histories both claim the same cgID (abnormal residue) → still fold (no card split), but
        // attribution nil = no learning
        let v = verdict(cg: 240522, bounds: frame,
                        placed: [seat(cg: 249469, bounds: frame, former: [240522]),
                                 seat(cg: 253982, bounds: frame.offsetBy(dx: 40, dy: 40), former: [240522])])
        XCTAssertEqual(v, .fold(ownerActiveCgID: nil, reason: .membership))
    }

    func testAmbiguousFrameMatchFoldsWithoutLearning() {
        // Two seats share a frame (overlapping windows) → fold without learning (better to learn less than
        // record a wrong attribution)
        let v = verdict(cg: 240522, bounds: frame,
                        placed: [seat(cg: 249469, bounds: frame), seat(cg: 253982, bounds: frame)])
        XCTAssertEqual(v, .fold(ownerActiveCgID: nil, reason: .exactFrame))
    }

    func testMembershipWinsOverGeometry() {
        // Membership beats exact match: the candidate is in seat A's history but shares a frame with seat B →
        // goes to A
        let v = verdict(cg: 240522, bounds: frame,
                        placed: [seat(cg: 249469, bounds: frame.offsetBy(dx: 500, dy: 0), former: [240522]),
                                 seat(cg: 253982, bounds: frame)])
        XCTAssertEqual(v, .fold(ownerActiveCgID: 249469, reason: .membership))
    }
}

/// Pure decision for phantom seat self-healing (PhantomSeatDecision): release only when all five gates pass;
/// better not to heal than to delete wrongly. Phantom seat = an extra seat split off from a min=true burst
/// candidate when folding misses (typical: the window is already minimized at dock launch, and seed has no
/// history and no shadow pool); after the window is restored it leaves AX, stays in CG, and is held forever
/// by the min retention rule.
final class PhantomSeatDecisionTests: XCTestCase {

    private func release(
        everSeenVisible: Bool = false,
        axAbsentFor: TimeInterval = 12,
        cgStillPresent: Bool = true,
        axReadSawWindows: Bool = true,
        siblings: Int = 1
    ) -> Bool {
        PhantomSeatDecision.shouldRelease(
            everSeenVisible: everSeenVisible, axAbsentFor: axAbsentFor, threshold: 10,
            cgStillPresent: cgStillPresent, axReadSawWindows: axReadSawWindows,
            axPresentSiblingCount: siblings
        )
    }

    func testReleasesWhenAllGatesPass() {
        XCTAssertTrue(release())
    }

    func testEverSeenVisibleProtectsRealWindow() {
        // A real Safari-style window: once visible → never self-heals even if it leaves AX entirely after
        // minimizing (minimizing never loses a card is a hard guardrail)
        XCTAssertFalse(release(everSeenVisible: true))
    }

    func testUnderThresholdDoesNotRelease() {
        // An occasional AX miss for a round or two is not a phantom
        XCTAssertFalse(release(axAbsentFor: 9.9))
    }

    func testHungAppDoesNotRelease() {
        // AX read no windows at all this round (app hung) → do nothing
        XCTAssertFalse(release(axReadSawWindows: false))
    }

    func testLoneSeatNeverReleases() {
        // A lone seat never self-heals: an app's only card must not be deleted by self-healing
        XCTAssertFalse(release(siblings: 0))
    }

    func testCgGoneIsNotHealingBusiness() {
        // Leaving CG is a real close and takes the existing delete path; self-healing stays out
        XCTAssertFalse(release(cgStillPresent: false))
    }

    func testEvaluationExportsAllFailedGates() {
        let evaluation = PhantomSeatDecision.evaluate(
            everSeenVisible: true,
            axAbsentFor: 9.9,
            threshold: 10,
            cgStillPresent: false,
            axReadSawWindows: false,
            axPresentSiblingCount: 0
        )

        XCTAssertFalse(evaluation.shouldRelease)
        XCTAssertEqual(evaluation.holdReasons, [
            .everSeenVisible,
            .absenceGraceNotElapsed,
            .cgMissing,
            .noEligibleWindows,
            .noAXPresentSibling,
        ])
    }

    func testEvaluationExportsEachFailedGate() {
        let cases: [(PhantomSeatDecision.HoldReason, PhantomSeatDecision.Evaluation)] = [
            (.everSeenVisible, PhantomSeatDecision.evaluate(
                everSeenVisible: true, axAbsentFor: 10, threshold: 10,
                cgStillPresent: true, axReadSawWindows: true, axPresentSiblingCount: 1
            )),
            (.absenceGraceNotElapsed, PhantomSeatDecision.evaluate(
                everSeenVisible: false, axAbsentFor: 9.9, threshold: 10,
                cgStillPresent: true, axReadSawWindows: true, axPresentSiblingCount: 1
            )),
            (.cgMissing, PhantomSeatDecision.evaluate(
                everSeenVisible: false, axAbsentFor: 10, threshold: 10,
                cgStillPresent: false, axReadSawWindows: true, axPresentSiblingCount: 1
            )),
            (.noEligibleWindows, PhantomSeatDecision.evaluate(
                everSeenVisible: false, axAbsentFor: 10, threshold: 10,
                cgStillPresent: true, axReadSawWindows: false, axPresentSiblingCount: 1
            )),
            (.noAXPresentSibling, PhantomSeatDecision.evaluate(
                everSeenVisible: false, axAbsentFor: 10, threshold: 10,
                cgStillPresent: true, axReadSawWindows: true, axPresentSiblingCount: 0
            )),
        ]

        for (reason, evaluation) in cases {
            XCTAssertFalse(evaluation.shouldRelease)
            XCTAssertEqual(evaluation.holdReasons, [reason])
        }
    }

    func testEvaluationHasNoHoldReasonsWhenAllGatesPass() {
        let evaluation = PhantomSeatDecision.evaluate(
            everSeenVisible: false,
            axAbsentFor: 10,
            threshold: 10,
            cgStillPresent: true,
            axReadSawWindows: true,
            axPresentSiblingCount: 1
        )

        XCTAssertTrue(evaluation.shouldRelease)
        XCTAssertTrue(evaluation.holdReasons.isEmpty)
    }
}

/// Pass A "merge into tab" pure decision layer (TabMergeDecision).
/// Background (measured on Finder 2026-09-12): after "Merge All Windows" / dragging a tab into another
/// window, the original window becomes an order-out background tab: gone from AX, still in CG,
/// onscreen=false, CG bounds changed to the owning window's frame. The old path kept the seat unconditionally
/// → one window, two cards; then two old seats with the same frame broke tab-switch takeover, splitting off
/// another card on every switch.
final class TabMergeDecisionTests: XCTestCase {

    private func fk(_ b: CGRect?) -> String? {
        guard let b else { return nil }
        return "\(Int(b.origin.x.rounded())):\(Int(b.origin.y.rounded())):\(Int(b.size.width.rounded())):\(Int(b.size.height.rounded()))"
    }

    private func sibling(cg: CGWindowID, bounds: CGRect?, min: Bool = false) -> TabMergeDecision.AXPresentSeat {
        TabMergeDecision.AXPresentSeat(activeCgID: cg, bounds: bounds, isMinimized: min)
    }

    private let mergedFrame = CGRect(x: 297, y: 340, width: 1227, height: 504)
    private let oldFrame = CGRect(x: 268, y: 311, width: 1227, height: 504)

    func testMergedTabReleasesAndLearnsOwner() {
        // Measured shape: the seat's stored AX frame is still the old window position, CG bounds already
        // follow the owning window; a sibling seat is present in AX with the same frame.
        let v = TabMergeDecision.verdict(
            candidateIsOnScreen: false, candidateCGBounds: mergedFrame, candidateSeatBounds: oldFrame,
            axPresentSeats: [sibling(cg: 21637, bounds: mergedFrame)], frameKey: fk
        )
        XCTAssertEqual(v, .release(ownerActiveCgID: 21637))
    }

    func testOnScreenCandidateIsNeverReleased() {
        // One AX miss on a truly visible window: CG says it is on screen → keep the seat, even with a
        // same-frame sibling (two overlapping windows are legal).
        let v = TabMergeDecision.verdict(
            candidateIsOnScreen: true, candidateCGBounds: mergedFrame, candidateSeatBounds: mergedFrame,
            axPresentSeats: [sibling(cg: 21637, bounds: mergedFrame)], frameKey: fk
        )
        XCTAssertEqual(v, .retain)
    }

    func testNoCoFramedVisibleSiblingRetains() {
        // Off screen + no visible same-frame sibling: may be lingering in CG after close (tombstone path) or
        // something else; not decided here.
        let v = TabMergeDecision.verdict(
            candidateIsOnScreen: false, candidateCGBounds: oldFrame, candidateSeatBounds: oldFrame,
            axPresentSeats: [sibling(cg: 21637, bounds: mergedFrame)], frameKey: fk
        )
        XCTAssertEqual(v, .retain)
    }

    func testMinimizedSiblingDoesNotOwn() {
        // The same-frame sibling is itself min=true (a tab in a minimize burst) → not a visible owner, keep
        // the seat conservatively.
        let v = TabMergeDecision.verdict(
            candidateIsOnScreen: false, candidateCGBounds: mergedFrame, candidateSeatBounds: mergedFrame,
            axPresentSeats: [sibling(cg: 21637, bounds: mergedFrame, min: true)], frameKey: fk
        )
        XCTAssertEqual(v, .retain)
    }

    func testAmbiguousOwnersReleaseWithoutLearning() {
        let v = TabMergeDecision.verdict(
            candidateIsOnScreen: false, candidateCGBounds: mergedFrame, candidateSeatBounds: nil,
            axPresentSeats: [sibling(cg: 1, bounds: mergedFrame), sibling(cg: 2, bounds: mergedFrame)], frameKey: fk
        )
        XCTAssertEqual(v, .release(ownerActiveCgID: nil))
    }

    func testFallsBackToSeatBoundsWhenCGHasNoRect() {
        let v = TabMergeDecision.verdict(
            candidateIsOnScreen: false, candidateCGBounds: nil, candidateSeatBounds: mergedFrame,
            axPresentSeats: [sibling(cg: 21637, bounds: mergedFrame)], frameKey: fk
        )
        XCTAssertEqual(v, .release(ownerActiveCgID: 21637))
    }

    func testNoBoundsAtAllRetains() {
        let v = TabMergeDecision.verdict(
            candidateIsOnScreen: false, candidateCGBounds: nil, candidateSeatBounds: nil,
            axPresentSeats: [sibling(cg: 21637, bounds: mergedFrame)], frameKey: fk
        )
        XCTAssertEqual(v, .retain)
    }
}
