import AppKit
import Combine
import XCTest

/// Full convert / roll back / land / cancel matrix of the
/// cross-panel conversion state machine (review 2026-07-11 P2-6).
/// Drives the real DragController with a real store (temporary
/// UserDefaults) + a fixed drop-zone stub (compiled locally into the test
/// target, consistent with the store); geometric triggers (when it enters/leaves a zone) belong to
/// the view layer, here only membership and payload before and after each conversion are verified.
@MainActor
final class DragControllerConversionTests: XCTestCase {

    private var drawer: DrawerStore!
    private var kept: KeptAppStore!
    private var messaging: MessagingAppStore!
    private var membership: AppMembershipController!
    private var controller: DragController!
    /// Fixed drop zone: the hit test looks only at beginDrag's start coordinate.
    private let dropZone = CGRect(x: 0, y: 0, width: 100, height: 100)
    private let insideZone = CGPoint(x: 50, y: 50)
    private let outsideZone = CGPoint(x: 500, y: 500)

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared   // start AppKit before creating an NSPanel in a test bundle with no host app
        let suite = "test-dragconv-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        drawer = DrawerStore(defaults: defaults)
        kept = KeptAppStore(defaults: defaults)
        messaging = MessagingAppStore(defaults: defaults)
        membership = AppMembershipController(keptAppStore: kept, drawerStore: drawer, messagingStore: messaging)
        controller = DragController(
            drawerStore: drawer,
            messagingStore: messaging,
            membershipController: membership,
            dropZonesProvider: { [dropZone] _ in [dropZone] },
            screensProvider: { NSScreen.screens }
        )
    }

    override func tearDown() {
        controller.cancelDrag()   // idempotent cleanup, keeps panels/monitors from leaking into the next case
        super.tearDown()
    }

    private func payload(_ source: DragSource, _ bid: String) -> DragPayload {
        DragPayload(source: source, id: bid, bundleID: bid, item: nil,
                    visualKind: .drawerIcon, canExternalDrop: true)
    }

    /// A drag must start with a carrier bitmap (no capture means no drag, see `DragController.beginDrag`).
    /// These cases verify membership and payload; what the bitmap shows is irrelevant, a 1×1 one will do.
    private func stubSnapshot(side: Int = 1) -> CarrierSnapshot {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 4 * side,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CarrierSnapshot(image: context.makeImage()!,
                               size: CGSize(width: side, height: side),
                               contentSize: CGSize(width: side, height: side),
                               scale: 1)
    }

    private func begin(_ source: DragSource, _ bid: String, at point: CGPoint, surface: String? = nil) {
        controller.beginDrag(payload: payload(source, bid), stripSurfaceID: surface, startScreenLocation: point,
                             grabOffset: .zero, sourceScreenRect: .zero, pose: .resting,
                             snapshot: stubSnapshot())
    }

    /// Wait a short stretch of real time (running the run loop), for
    /// time-based deferrals like `DragLandingPlan.pickUpSettle`.
    private func settle(_ seconds: TimeInterval) {
        let until = Date(timeIntervalSinceNow: seconds)
        while Date() < until {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
    }

    /// Run the run loop until the condition holds (at most `timeout`). Use
    /// it for the time-deferred steps instead of betting on a fixed wait.
    private func waitUntil(_ timeout: TimeInterval = 1, _ condition: () -> Bool) {
        let until = Date(timeIntervalSinceNow: timeout)
        while !condition() && Date() < until {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
    }

    // MARK: - Active strip surface (multi-display ③④: of several taskbars with identical content only one can write back)

    func testStripSurfaceClaimClearsOnCancelAndOnRevert() {
        begin(.strip, "com.example.a", at: outsideZone, surface: "strip-A")
        XCTAssertEqual(controller.activeStripSurfaceID, "strip-A")
        controller.cancelDrag()
        XCTAssertNil(controller.activeStripSurfaceID, "cancel = drag over, the claim must be cleared, otherwise nobody can promote the next drag started from the drawer")

        drawer.add("com.example.b")
        begin(.drawer, "com.example.b", at: outsideZone)
        XCTAssertNil(controller.activeStripSurfaceID, "drawer drag not yet promoted: nobody has claimed, whichever strip contains the pointer may promote")
        controller.claimStripSurface("strip-B")
        controller.convertDrawerToStrip()
        XCTAssertEqual(controller.activeStripSurfaceID, "strip-B")
        controller.revertDrawerToStrip()
        XCTAssertNil(controller.activeStripSurfaceID, "undoing the promotion releases the claim")
        controller.cancelDrag()
    }

    /// A drawer messaging app released into the messaging zone takes another
    /// path (`convertDrawerToMessaging`); claim / release must match:
    /// miss the release and after an undo nobody can release when the pointer enters another
    /// strip's messaging zone; miss the claim and the two strips undo each other every tick.
    func testDrawerToMessagingClaimClearsOnRevert() {
        messaging.mark("chat"); drawer.add("chat")
        begin(.drawer, "chat", at: outsideZone)
        controller.claimStripSurface("strip-B")
        controller.convertDrawerToMessaging()
        XCTAssertEqual(controller.activeStripSurfaceID, "strip-B")
        controller.revertDrawerToMessaging()
        XCTAssertNil(controller.activeStripSurfaceID, "undoing the release releases the claim")
        controller.cancelDrag()
    }

    // MARK: - Close up on drag-out (2026-09-03: card leaves the bar -> gap closes, bar shortens; makes room again on return)

    func testLeavingTheStripCollapsesTheSlotAndEnteringRestoresIt() {
        begin(.strip, "com.example.a", at: outsideZone, surface: "strip-A")
        XCTAssertFalse(controller.stripSlotCollapsed, "still on the bar at drag start")
        controller.noteStripLeft(surfaceID: "strip-A")
        XCTAssertTrue(controller.stripSlotCollapsed)
        controller.noteStripEntered(surfaceID: "strip-A", displayUUID: nil)
        XCTAssertFalse(controller.stripSlotCollapsed)
        controller.cancelDrag()
    }

    /// Only the claiming bar's hit frame counts; the claim is decided by the display the
    /// pointer is on (`claimStripSurface`), entering or leaving a frame does not hand over
    /// (2026-09-03: dragging to display B lands on bar B, without having to press into bar B's frame).
    func testOnlyTheClaimedStripDecidesAndClaimFollowsTheScreenNotTheBox() {
        begin(.strip, "com.example.a", at: outsideZone, surface: "strip-A")
        controller.noteStripLeft(surfaceID: "strip-B")
        XCTAssertFalse(controller.stripSlotCollapsed, "B has not claimed, its frame does not count")
        controller.noteStripLeft(surfaceID: "strip-A")
        XCTAssertTrue(controller.stripSlotCollapsed)
        controller.noteStripEntered(surfaceID: "strip-B", displayUUID: "display-B")
        XCTAssertEqual(controller.activeStripSurfaceID, "strip-A", "entering a frame does not hand over")
        XCTAssertTrue(controller.stripSlotCollapsed, "B has not claimed, entering its frame does not reopen")
        controller.claimStripSurface("strip-B", displayUUID: "display-B")   // pointer reached display B
        controller.noteStripEntered(surfaceID: "strip-B", displayUUID: "display-B")
        XCTAssertFalse(controller.stripSlotCollapsed, "the claiming bar B makes room")
        controller.noteStripLeft(surfaceID: "strip-B")
        XCTAssertEqual(controller.activeStripSurfaceID, "strip-B", "leaving the frame does not hand back either: the pointer is still on display B")
        XCTAssertTrue(controller.stripSlotCollapsed)
        controller.cancelDrag()
    }

    /// Messaging chips do not cross bars: entering another bar does not count as coming back.
    func testMessagingChipOnlyRestoresOnItsOwnStrip() {
        messaging.mark("chat")
        begin(.messaging, "chat", at: outsideZone, surface: "strip-A")
        controller.noteStripLeft(surfaceID: "strip-A")
        XCTAssertTrue(controller.stripSlotCollapsed)
        controller.noteStripEntered(surfaceID: "strip-B", displayUUID: nil)
        XCTAssertTrue(controller.stripSlotCollapsed, "another bar does not count")
        XCTAssertEqual(controller.activeStripSurfaceID, "strip-A", "messaging chips do not hand over")
        controller.noteStripEntered(surfaceID: "strip-A", displayUUID: nil)
        XCTAssertFalse(controller.stripSlotCollapsed)
        controller.cancelDrag()
    }

    /// Converting into the drawer body = leaving the bar; after the conversion
    /// is undone it stays closed up until the bar's hit frame says it is back.
    func testConvertingIntoTheDrawerCollapsesAndRevertKeepsItCollapsed() {
        begin(.strip, "com.example.a", at: outsideZone, surface: "strip-A")
        controller.convertStripToDrawer()
        XCTAssertTrue(controller.stripSlotCollapsed)
        controller.noteStripEntered(surfaceID: "strip-A", displayUUID: nil)
        XCTAssertTrue(controller.stripSlotCollapsed, "the bar's hit frame does not count during a conversion")
        controller.revertStripFromDrawer()
        XCTAssertTrue(controller.stripSlotCollapsed)
        controller.noteStripEntered(surfaceID: "strip-A", displayUUID: nil)
        XCTAssertFalse(controller.stripSlotCollapsed)
        controller.cancelDrag()
    }

    /// Release outside the bar and outside a drop zone: the slot reopens first and the
    /// flight heads for the last known slot (the slot frame cannot be reported yet).
    func testDesktopReleaseReopensTheSlotAndFliesToTheLastKnownSlot() {
        begin(.strip, "com.example.a", at: outsideZone, surface: "strip-A")
        controller.setLandingAnchor(CGRect(x: 400, y: 400, width: 40, height: 54), owner: .strip)
        controller.noteStripLeft(surfaceID: "strip-A")
        controller.setLandingAnchor(nil, owner: .strip)   // after closing up the bar cannot report a slot
        controller.endDrag()
        XCTAssertFalse(controller.stripSlotCollapsed, "release reopens the slot")
        XCTAssertNotNil(controller.landing, "with a last known slot it flies, no teleport")
        XCTAssertEqual(controller.landing?.kind, .returnToSlot)
        controller.cancelDrag()
    }

    /// Release on the drop zone (capsule) = stash: the slot does not
    /// reopen and the bar stays narrow until landing cleanup resets it.
    func testStashReleaseKeepsTheSlotCollapsedUntilLanding() {
        let stashing = makeStashingController()
        defer { stashing.cancelDrag() }
        stashing.beginDrag(payload: payload(.strip, "app"), stripSurfaceID: "strip-A",
                           startScreenLocation: insideZone, grabOffset: .zero, sourceScreenRect: .zero,
                           pose: .resting, snapshot: stubSnapshot())
        waitUntil { stashing.hiddenSlotPayload != nil }
        stashing.noteStripLeft(surfaceID: "strip-A")
        XCTAssertTrue(stashing.stripSlotCollapsed)
        stashing.endDrag()
        XCTAssertTrue(drawer.contains("app"))
        XCTAssertEqual(stashing.landing?.kind, .stash)
        XCTAssertTrue(stashing.stripSlotCollapsed, "the slot does not reopen while being sucked into the capsule")
        stashing.abortLanding()
        XCTAssertFalse(stashing.stripSlotCollapsed, "landing cleanup resets it")
    }

    func testCancelReopensTheSlot() {
        begin(.strip, "com.example.a", at: outsideZone, surface: "strip-A")
        controller.noteStripLeft(surfaceID: "strip-A")
        controller.cancelDrag()
        XCTAssertFalse(controller.stripSlotCollapsed)
    }

    // MARK: - Handover order at drag start / landing (both ends must be "new first, then old")

    /// **On the drag-start frame the card on the bar must not
    /// be hidden first (when no candidate was prepared).**
    ///
    /// The carrier is a freshly captured bitmap whose first frame waits for a texture
    /// upload, measured as always one display frame later than SwiftUI hiding the card
    /// (2026-08-19 recording, frame by frame: three drags in a row each showed one
    /// frame of "slot already empty, carrier not on screen" at the same phase).
    /// So without prewarming, `beginDrag` only places the carrier at the slot's
    /// position that turn, and **two display frames later** (by time, not by
    /// run loop turns: a real machine delivers a mouse event every 1ms, so the next
    /// turn is often still in the same frame) hides the card and lifts together.
    func testSlotStaysFilledUntilTheCarrierHasHadAFrame() {
        begin(.strip, "app", at: outsideZone)
        XCTAssertNotNil(controller.draggingPayload, "the drag itself starts at once")
        XCTAssertNil(controller.hiddenSlotPayload, "but the slot on the bar must not be empty this turn")
        XCTAssertTrue(controller.hoverFrozen, "hover is frozen in place for these frames, the card must not deform")

        // The next run loop turn is not enough: that is exactly why the first version showed one empty frame.
        let nextTurn = expectation(description: "next run loop turn")
        DispatchQueue.main.async { nextTurn.fulfill() }
        wait(for: [nextTurn], timeout: 1)
        XCTAssertNil(controller.hiddenSlotPayload, "still not released on the next run loop turn")

        waitUntil { controller.hiddenSlotPayload != nil }
        XCTAssertEqual(controller.hiddenSlotPayload?.bundleID, "app", "emptied only after two display frames")
        XCTAssertFalse(controller.hoverFrozen)
        XCTAssertTrue(controller.hoverSuppressed, "after the card is hidden, hover switches to suppressed")
    }

    /// **Candidate prepared on press -> released on the drag-start turn**: the texture
    /// is already uploaded, lighting the carrier and hiding the card are one commit.
    func testPreparedCandidateArmsImmediately() {
        let slot = CGRect(x: 100, y: 10, width: 40, height: 54)
        controller.prepareCandidate(payloadID: "app", sourceScreenRect: slot, snapshot: stubSnapshot())
        controller.beginDrag(payload: payload(.strip, "app"), startScreenLocation: outsideZone,
                             grabOffset: .zero, sourceScreenRect: slot, pose: .resting,
                             snapshot: nil)   // with a candidate no new capture should be taken: passing nil here must still start the drag
        XCTAssertNotNil(controller.draggingPayload)
        XCTAssertEqual(controller.hiddenSlotPayload?.bundleID, "app", "card hidden on the same turn")
        XCTAssertFalse(controller.hoverFrozen)
        XCTAssertTrue(controller.hoverSuppressed)
    }

    /// Candidate does not match (a different card was pressed)
    /// -> it must not stand in; take the no-candidate path.
    func testMismatchedCandidateIsIgnored() {
        let slot = CGRect(x: 100, y: 10, width: 40, height: 54)
        controller.prepareCandidate(payloadID: "other", sourceScreenRect: slot, snapshot: stubSnapshot())
        begin(.strip, "app", at: outsideZone)
        XCTAssertNotNil(controller.draggingPayload)
        XCTAssertNil(controller.hiddenSlotPayload, "no matching candidate -> the card must still stay in place first")
    }

    /// Released without a drag -> the candidate is dropped and a later drag will not misuse it.
    func testClearedCandidateDoesNotArmImmediately() {
        let slot = CGRect(x: 100, y: 10, width: 40, height: 54)
        controller.prepareCandidate(payloadID: "app", sourceScreenRect: slot, snapshot: stubSnapshot())
        controller.clearCandidate(payloadID: "app")
        begin(.strip, "app", at: outsideZone)
        XCTAssertNil(controller.hiddenSlotPayload)
    }

    /// The landing end is **the reverse**: as soon as `landing` clears
    /// the card must appear, and the carrier is removed one turn later.
    /// The two ends are asymmetric, so `hiddenSlotPayload` cannot simply equal `carriedPayload`.
    func testLandingSideIsNotGatedTheSameWay() {
        begin(.strip, "app", at: outsideZone)
        waitUntil { controller.hiddenSlotPayload != nil }
        XCTAssertNotNil(controller.hiddenSlotPayload)

        controller.endDrag()
        // No landing anchor -> hold in place waiting for one
        // (`DragLandingPlan.holdingFlight`); if the hold expires with still no anchor
        // -> land directly: `landing` clears, the card appears
        // that turn, the carrier is removed one turn later.
        XCTAssertEqual(controller.landing?.flight.isStationary, true, "no anchor: hold in place first, no instant finish")
        waitUntil(1) { controller.landing == nil }
        XCTAssertNil(controller.landing, "anchor never came -> lands as soon as the hold expires")
        XCTAssertNil(controller.hiddenSlotPayload, "a finish without a flight must also show the card at once")
        XCTAssertTrue(controller.isCarrying, "but the carrier is not removed yet, hover must stay suppressed")
    }

    /// Cross-display window drag (③④): after the claim hands over, **the old bar's slot memory
    /// is void**: a release over empty space on display B must not fly to bar A's old slot
    /// (the carrier panel would switch to display A and the icon vanish from display B,
    /// 2026-09-03). The release first holds in place, and once bar B reports a real anchor
    /// the whole segment is replaced by a flight toward it.
    func testClaimHandoverForgetsTheOldSlotAndWaitsForTheNewStripsAnchor() {
        begin(.strip, "com.example.a", at: outsideZone, surface: "strip-A")
        controller.setLandingAnchor(CGRect(x: 400, y: 400, width: 40, height: 54), owner: .strip)
        controller.noteStripLeft(surfaceID: "strip-A")
        controller.setLandingAnchor(nil, owner: .strip)   // after closing up, A cannot report a slot
        controller.claimStripSurface("strip-B", displayUUID: "display-B")   // pointer reached display B
        controller.endDrag()
        XCTAssertFalse(controller.stripSlotCollapsed, "release reopens the slot (on bar B)")
        guard let held = controller.landing else { return XCTFail("expected a hold-in-place flight") }
        XCTAssertEqual(held.kind, .returnToSlot)
        XCTAssertTrue(held.flight.isStationary, "bar A's old slot is not honored")
        // Bar B's next commit reports a real anchor -> the whole segment is replaced within the hold
        controller.setLandingAnchor(CGRect(x: outsideZone.x + 200, y: outsideZone.y, width: 40, height: 54),
                                    owner: .strip)
        guard let flying = controller.landing else { return XCTFail("must still be flying once the anchor arrives") }
        XCTAssertFalse(flying.flight.isStationary, "replaced by a flight toward the slot on bar B")
        XCTAssertEqual(flying.token, held.token, "the same landing, not a new one")
        controller.cancelDrag()
    }

    /// **After landing, that card's hover must be held** until the pointer really
    /// moves: if hover is re-evaluated the moment the card settles at 1.0,
    /// the quiet level grows it to 1.10 on the spot (2026-08-19, "landing
    /// jitter"). The pointer does not move here, so the hold stays in place.
    ///
    /// The hold applies to **that one card**, not the whole taskbar, see the next case.
    func testHoverStaysHeldAfterLandingUntilThePointerMoves() {
        begin(.strip, "app", at: outsideZone)
        waitUntil { controller.hiddenSlotPayload != nil }
        controller.endDrag()
        // No anchor -> first hold in place waiting for one (34ms), landing
        // only after that hold expires; the hover hold starts at landing.
        waitUntil { controller.landing == nil }
        XCTAssertEqual(controller.hoverHoldPayload?.bundleID, "app")
        XCTAssertEqual(controller.hoverExemptPayload?.bundleID, "app")
        // Still held after the turn in which the carrier is removed
        // (`carrierRetiring` is already false, the hold does it).
        waitUntil { !controller.isCarrying }
        XCTAssertFalse(controller.isCarrying, "the carrier is already removed")
        XCTAssertEqual(controller.hoverExemptPayload?.bundleID, "app", "but the pointer has not moved, so the card itself is still held")
        // Released once the fallback cap is reached (the test cannot really move the pointer).
        waitUntil(DragLandingPlan.hoverHoldMaximum + 1) { controller.hoverHoldPayload == nil }
        XCTAssertNil(controller.hoverHoldPayload)
        XCTAssertNil(controller.hoverExemptPayload)
    }

    /// **Whole-bar suppression only while "something is really in hand"**;
    /// during the return flight after release, other cards hover as usual
    /// (2026-08-19 report: "while the icon flies, moving the mouse over
    /// other icons shows no hover effect until it has fully landed").
    func testOnlyTheFlyingCardIsExemptDuringTheReturnFlight() {
        begin(.strip, "app", at: outsideZone)
        waitUntil { controller.hiddenSlotPayload != nil }
        XCTAssertTrue(controller.hoverSuppressed, "while carrying, the whole bar does not evaluate hover")

        controller.setLandingAnchor(CGRect(x: outsideZone.x + 200, y: outsideZone.y, width: 40, height: 54),
                                    owner: .strip)
        controller.endDrag()
        XCTAssertNotNil(controller.landing, "took off")
        XCTAssertFalse(controller.hoverSuppressed, "no whole-bar suppression during the flight: other cards must be able to hover")
        XCTAssertEqual(controller.hoverExemptPayload?.bundleID, "app", "only the card in flight is exempt")
    }

    // MARK: - Return flight is interruptible (2026-08-19: "native and bestdock can both interrupt")

    private func flyBack(from point: CGPoint) {
        begin(.strip, "app", at: point)
        waitUntil { controller.hiddenSlotPayload != nil }
        // Anchor far enough from the pointer -> release takes off.
        controller.setLandingAnchor(CGRect(x: point.x + 200, y: point.y, width: 40, height: 54), owner: .strip)
        controller.endDrag()
    }

    /// Re-grab mid-flight: the flight ends, it becomes a new drag, and **the
    /// slot stays empty throughout** (`hiddenSlotPayload` never flashes nil).
    func testRegrabDuringLandingContinuesTheDragWithoutAGap() {
        flyBack(from: outsideZone)
        XCTAssertNotNil(controller.landing, "anchor present, enough displacement -> takes off")
        XCTAssertNil(controller.draggingPayload)
        XCTAssertEqual(controller.hiddenSlotPayload?.bundleID, "app", "slot empty during the flight")

        // Point outside the icon -> no grab, the flight continues.
        XCTAssertFalse(controller.regrabLanding(at: CGPoint(x: outsideZone.x - 900, y: outsideZone.y - 900)))
        XCTAssertNotNil(controller.landing)

        // The same card's slot is pressed (hitting the icon is not
        // required) -> the drag continues from the icon's current position.
        XCTAssertTrue(controller.regrabLanding(at: outsideZone, requireHit: false))
        XCTAssertNil(controller.landing, "flight ended")
        XCTAssertEqual(controller.draggingPayload?.bundleID, "app", "became a new drag")
        XCTAssertEqual(controller.hiddenSlotPayload?.bundleID, "app", "slot stays empty throughout")
        XCTAssertTrue(controller.isCarrying)
        XCTAssertFalse(controller.hoverFrozen, "a re-grabbed carrier is already lifted and does not need the drag-start freeze frames")
        XCTAssertTrue(controller.hoverSuppressed)
        XCTAssertNil(controller.hoverHoldPayload)

        // Releasing again finishes as usual.
        controller.endDrag()
        XCTAssertNil(controller.draggingPayload)
    }

    /// Pressing on the empty slot (the SwiftUI gesture started a drag with the same
    /// payload) also re-grabs: no more "instant finish + lift again from the slot".
    func testBeginDragOfTheSameCardDuringLandingRegrabs() {
        flyBack(from: outsideZone)
        XCTAssertNotNil(controller.landing)
        begin(.strip, "app", at: CGPoint(x: outsideZone.x + 30, y: outsideZone.y))
        XCTAssertNil(controller.landing)
        XCTAssertEqual(controller.draggingPayload?.bundleID, "app")
        XCTAssertEqual(controller.hiddenSlotPayload?.bundleID, "app", "empty on the same turn, without the two-frame drag-start gate")
        XCTAssertTrue(controller.carrierArmed)
    }

    /// Another card picked up during a flight -> the flight
    /// is ended as before (a different card, not a re-grab).
    func testBeginDragOfAnotherCardDuringLandingAbortsTheFlight() {
        flyBack(from: outsideZone)
        XCTAssertNotNil(controller.landing)
        begin(.strip, "other", at: outsideZone)
        XCTAssertNil(controller.landing)
        XCTAssertEqual(controller.draggingPayload?.bundleID, "other")
    }

    /// Release after a re-grab without moving = **a click on this card**: the click
    /// is emitted, the icon flies on back to the slot, and no membership changes.
    func testRegrabThenReleaseWithoutMovingIsAClick() {
        var clicks: [DragPayload] = []
        let sub = controller.carrierClicks.sink { clicks.append($0) }
        defer { sub.cancel() }
        flyBack(from: outsideZone)
        XCTAssertTrue(controller.regrabLanding(at: outsideZone, requireHit: false))
        // On a real machine the re-grab's `pointerMoves` makes the taskbar
        // report the slot frame again; here we report it on its behalf.
        controller.setLandingAnchor(CGRect(x: outsideZone.x + 200, y: outsideZone.y, width: 40, height: 54), owner: .strip)
        controller.endDrag()
        XCTAssertEqual(clicks.map(\.bundleID), ["app"])
        XCTAssertNotNil(controller.landing, "after the click the icon flies on back to the slot")
        XCTAssertEqual(controller.landing?.kind, .returnToSlot)
        XCTAssertNil(controller.draggingPayload)
        XCTAssertFalse(drawer.contains("app"), "a click does not stash")
    }

    /// An ordinary release without a re-grab is not a click.
    func testOrdinaryReleaseIsNotAClick() {
        var clicks: [DragPayload] = []
        let sub = controller.carrierClicks.sink { clicks.append($0) }
        defer { sub.cancel() }
        flyBack(from: outsideZone)
        XCTAssertTrue(clicks.isEmpty)
    }

    /// Once the flight is over there is nothing left to grab.
    func testRegrabAfterTheFlightIsRefused() {
        flyBack(from: outsideZone)
        waitUntil(DragLandingPlan.maximumDuration + 1) { controller.landing == nil }
        XCTAssertNil(controller.landing)
        XCTAssertFalse(controller.regrabLanding(at: outsideZone, requireHit: false))
        XCTAssertNil(controller.draggingPayload)
    }

    // MARK: - Release on the capsule to stash = sucked into the capsule (2026-08-19: after stashing the icon drifted toward the taskbar before vanishing)

    private func makeStashingController() -> DragController {
        DragController(drawerStore: drawer, messagingStore: messaging, membershipController: membership,
                       dropZonesProvider: { [dropZone] _ in [dropZone] },
                       screensProvider: { NSScreen.screens },
                       stashTargetProvider: { CGRect(x: 40, y: 40, width: 20, height: 20) })
    }

    func testStripDropOnCapsuleFliesIntoTheCapsuleAndNeverRetargets() {
        let stashing = makeStashingController()
        defer { stashing.cancelDrag() }
        stashing.beginDrag(payload: payload(.strip, "app"), startScreenLocation: insideZone,
                           grabOffset: .zero, sourceScreenRect: .zero, pose: .resting, snapshot: stubSnapshot())
        waitUntil { stashing.hiddenSlotPayload != nil }
        XCTAssertTrue(stashing.isOverDropZone)
        stashing.endDrag()
        XCTAssertTrue(drawer.contains("app"), "stashed as usual")
        guard let landing = stashing.landing else { return XCTFail("expected a flight into the capsule") }
        XCTAssertEqual(landing.kind, .stash)
        XCTAssertEqual(landing.flight.toOpacity, 0)
        XCTAssertEqual(landing.flight.toScale, DragLandingPlan.stashScale)
        let destination = landing.flight.to
        // For a frame or two after stashing the taskbar still reports the old
        // frame of that slot; the flight into the capsule must not be pulled back.
        stashing.setLandingAnchor(CGRect(x: 500, y: 8, width: 40, height: 54), owner: .strip)
        XCTAssertEqual(stashing.landing?.flight.to, destination)
        // It cannot be grabbed or clicked either: the card is no longer on the bar.
        XCTAssertFalse(stashing.regrabLanding(at: insideZone, requireHit: false))
    }

    /// Capsule position unknown (default provider) -> no flight, instant finish;
    /// it must **not** fall back to flying to a slot that no longer exists.
    func testStashWithoutACapsuleFrameDoesNotFlyBackToTheSlot() {
        begin(.strip, "app", at: insideZone)
        waitUntil { controller.hiddenSlotPayload != nil }
        controller.setLandingAnchor(CGRect(x: 500, y: 8, width: 40, height: 54), owner: .strip)
        controller.endDrag()
        XCTAssertTrue(drawer.contains("app"))
        XCTAssertNil(controller.landing)
    }

    // MARK: - Bitmap swap + re-anchor on entering the drawer body (2026-08-19: after entering the drawer the big card overlapped the drawer edge)

    /// `reanchor: true`: the grab offset scales by the ratio of new to old
    /// bitmap size, so the pointer stays at the same relative spot on the icon.
    func testReanchoredSnapshotScalesTheGrabOffset() throws {
        // Re-anchoring waits for the carrier to "lift", and the lift is timed in
        // display frames. GitHub's headless runners have no refreshing display,
        // so `carrierLifted` never becomes true. Runs as usual locally; skipped on CI, assertions unchanged.
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil, "needs a refreshing display; skipped on CI")
        controller.beginDrag(payload: payload(.strip, "app"), startScreenLocation: outsideZone,
                             grabOffset: CGSize(width: 10, height: -6), sourceScreenRect: .zero,
                             pose: .resting, snapshot: stubSnapshot(side: 4))
        waitUntil { controller.hiddenSlotPayload != nil }
        waitUntil { controller.carrierLifted }       // re-anchoring is allowed only after the lift
        XCTAssertTrue(controller.carrierLifted)
        controller.setCarrierSnapshot(stubSnapshot(side: 2), reanchor: true)
        XCTAssertEqual(controller.grabOffset.width, 5, accuracy: 0.0001)
        XCTAssertEqual(controller.grabOffset.height, -3, accuracy: 0.0001)
        // Swapping back to the drag-start bitmap (nil) also restores proportionally.
        controller.setCarrierSnapshot(nil, reanchor: true)
        XCTAssertEqual(controller.grabOffset.width, 10, accuracy: 0.0001)
        XCTAssertEqual(controller.grabOffset.height, -6, accuracy: 0.0001)
        // A swap without re-anchoring leaves the offset alone (the
        // direction where a drawer icon is promoted into the taskbar).
        controller.setCarrierSnapshot(stubSnapshot(side: 8))
        XCTAssertEqual(controller.grabOffset.width, 10, accuracy: 0.0001)
    }

    // MARK: - Messaging zone chip -> drawer (stash preview)

    func testMessagingToDrawerConvertFlipsPayloadAndAddsMember() {
        messaging.mark("chat")
        begin(.messaging, "chat", at: outsideZone)
        controller.convertMessagingToDrawer()
        XCTAssertTrue(drawer.contains("chat"))
        XCTAssertEqual(controller.draggingPayload?.source, .drawer)
        XCTAssertTrue(controller.isConvertedFromMessaging)
        XCTAssertTrue(messaging.contains("chat"), "stashing does not clear the messaging flag")
    }

    func testMessagingToDrawerRevertRestoresOriginal() {
        messaging.mark("chat")
        begin(.messaging, "chat", at: outsideZone)
        controller.convertMessagingToDrawer()
        controller.revertMessagingFromDrawer()
        XCTAssertFalse(drawer.contains("chat"))
        XCTAssertEqual(controller.draggingPayload?.source, .messaging)
        XCTAssertFalse(controller.isConvertedFromMessaging)
    }

    func testMessagingToDrawerDropInsideDrawerCommits() {
        messaging.mark("chat")
        begin(.messaging, "chat", at: outsideZone)
        controller.convertMessagingToDrawer()
        controller.endDrag()   // release inside the drawer body (not in an external drop zone)
        XCTAssertTrue(drawer.contains("chat"), "still a drawer member after landing")
        XCTAssertNil(controller.draggingPayload)
        XCTAssertFalse(controller.isConvertedFromMessaging, "commit clears the conversion state")
    }

    func testMessagingToDrawerCancelRollsBack() {
        messaging.mark("chat")
        begin(.messaging, "chat", at: outsideZone)
        controller.convertMessagingToDrawer()
        controller.cancelDrag()
        XCTAssertFalse(drawer.contains("chat"), "cancel restores the original membership")
        XCTAssertNil(controller.draggingPayload)
    }

    /// Not in the drawer body, released on the capsule drop zone
    /// -> stash (same as a taskbar card landing on the capsule).
    func testMessagingChipDropOnCapsuleStashes() {
        messaging.mark("chat")
        begin(.messaging, "chat", at: insideZone)
        controller.endDrag()
        XCTAssertTrue(drawer.contains("chat"))
    }

    /// Released on desktop / folder zone / live zone (not a drop zone) -> stays put.
    func testMessagingChipDropOutsideDoesNothing() {
        messaging.mark("chat")
        begin(.messaging, "chat", at: outsideZone)
        controller.endDrag()
        XCTAssertFalse(drawer.contains("chat"))
        XCTAssertTrue(messaging.contains("chat"))
    }

    // MARK: - Messaging app in the drawer -> messaging zone (temporary release)

    func testDrawerToMessagingReleaseRemovesMemberAndFlipsPayload() {
        messaging.mark("chat"); drawer.add("chat")
        begin(.drawer, "chat", at: outsideZone)
        controller.convertDrawerToMessaging()
        XCTAssertFalse(drawer.contains("chat"))
        XCTAssertEqual(controller.draggingPayload?.source, .messaging)
        XCTAssertTrue(controller.isReleasedToMessaging)
    }

    func testDrawerToMessagingRevertRestoresDrawer() {
        messaging.mark("chat"); drawer.add("chat")
        begin(.drawer, "chat", at: outsideZone)
        controller.convertDrawerToMessaging()
        controller.revertDrawerToMessaging()
        XCTAssertTrue(drawer.contains("chat"))
        XCTAssertEqual(controller.draggingPayload?.source, .drawer)
        XCTAssertFalse(controller.isReleasedToMessaging)
    }

    func testDrawerToMessagingDropCommits() {
        messaging.mark("chat"); drawer.add("chat")
        begin(.drawer, "chat", at: outsideZone)
        controller.convertDrawerToMessaging()
        controller.endDrag()   // release inside the messaging zone (not a drop zone)
        XCTAssertFalse(drawer.contains("chat"), "landed: has left the drawer")
        XCTAssertTrue(messaging.contains("chat"), "messaging flag unchanged")
        XCTAssertNil(controller.draggingPayload)
    }

    func testDrawerToMessagingCancelRollsBack() {
        messaging.mark("chat"); drawer.add("chat")
        begin(.drawer, "chat", at: outsideZone)
        controller.convertDrawerToMessaging()
        controller.cancelDrag()
        XCTAssertTrue(drawer.contains("chat"), "cancel returns it to the drawer")
    }

    /// A messaging member's drawer icon released on the taskbar (outside the
    /// messaging zone) -> no downgrade unstash, stays in the drawer (review P1-3).
    func testMessagingMemberDrawerDragNeverFallbackUnstashes() {
        messaging.mark("chat"); drawer.add("chat")
        begin(.drawer, "chat", at: insideZone)   // inside the drop zone (taskbar panel)
        controller.endDrag()
        XCTAssertTrue(drawer.contains("chat"))
    }

    /// Non-messaging members keep the existing downgrade path:
    /// release on the taskbar -> removed from the drawer.
    func testNonMessagingDrawerDragFallbackUnstashes() {
        drawer.add("plain")
        begin(.drawer, "plain", at: insideZone)
        controller.endDrag()
        XCTAssertFalse(drawer.contains("plain"))
    }

    // MARK: - Regression for the two existing directions (behavior unchanged after conversion state was folded into CrossPanelConversion)

    func testStripToDrawerConvertRevertPreservesKept() {
        kept.add("app")
        begin(.strip, "app", at: outsideZone)
        controller.convertStripToDrawer()
        XCTAssertTrue(drawer.contains("app"))
        XCTAssertTrue(kept.contains("app"))
        XCTAssertTrue(controller.isConvertedFromStrip)
        controller.revertStripFromDrawer()
        XCTAssertFalse(drawer.contains("app"))
        XCTAssertTrue(kept.contains("app"), "neither conversion nor undo modifies kept")
        XCTAssertEqual(controller.draggingPayload?.source, .strip)
    }

    func testDrawerToStripConvertAndRevertPreservesKept() {
        drawer.add("app"); kept.add("app")
        begin(.drawer, "app", at: outsideZone)
        controller.convertDrawerToStrip()
        XCTAssertFalse(drawer.contains("app"))
        XCTAssertEqual(controller.convertedDrawerBundleID, "app")
        XCTAssertTrue(kept.contains("app"))
        controller.revertDrawerToStrip()
        XCTAssertTrue(drawer.contains("app"))
        XCTAssertTrue(kept.contains("app"), "a placement rollback does not modify kept")
        XCTAssertNil(controller.convertedDrawerBundleID)
    }

    func testUncheckedPlacementConversionsRemainUnchecked() {
        drawer.add("app")
        begin(.drawer, "app", at: outsideZone)
        controller.convertDrawerToStrip()
        XCTAssertFalse(kept.contains("app"))
        controller.revertDrawerToStrip()
        XCTAssertFalse(kept.contains("app"))
    }

    func testCancelFromDrawerToStripFiresCancelCallback() {
        drawer.add("app")
        var cancelled = false
        controller.onDrawerToStripCancelled = { cancelled = true }
        begin(.drawer, "app", at: outsideZone)
        controller.convertDrawerToStrip()
        controller.cancelDrag()
        XCTAssertTrue(cancelled)
        XCTAssertTrue(drawer.contains("app"))
    }

    // MARK: - Landing a drag into the drawer -> kept turned on automatically (2026-08-06)

    /// Entry 1/4: taskbar card dragged into the drawer body, released in the drawer.
    func testStripCardDroppedInsideDrawerEnablesKept() {
        begin(.strip, "app", at: outsideZone)
        controller.convertStripToDrawer()
        controller.endDrag()
        XCTAssertTrue(drawer.contains("app"))
        XCTAssertTrue(kept.contains("app"))
    }

    /// Entry 2/4: taskbar card never enters the drawer body and lands directly on the capsule.
    func testStripCardDroppedOnCapsuleEnablesKept() {
        begin(.strip, "app", at: insideZone)
        controller.endDrag()
        XCTAssertTrue(drawer.contains("app"))
        XCTAssertTrue(kept.contains("app"))
    }

    /// Entry 3/4: messaging zone chip dragged into the drawer body. Messaging identity is unaffected.
    func testMessagingChipDroppedInsideDrawerEnablesKept() {
        messaging.mark("chat")
        begin(.messaging, "chat", at: outsideZone)
        controller.convertMessagingToDrawer()
        controller.endDrag()
        XCTAssertTrue(drawer.contains("chat"))
        XCTAssertTrue(kept.contains("chat"))
        XCTAssertTrue(messaging.contains("chat"))
    }

    /// Entry 4/4: messaging zone chip lands on the capsule.
    func testMessagingChipDroppedOnCapsuleEnablesKept() {
        messaging.mark("chat")
        begin(.messaging, "chat", at: insideZone)
        controller.endDrag()
        XCTAssertTrue(drawer.contains("chat"))
        XCTAssertTrue(kept.contains("chat"))
    }

    /// Negative case: a reorder inside the drawer lands. No new member joined, so kept must not be turned on.
    func testDrawerInternalReorderDoesNotEnableKept() {
        drawer.add("app")
        begin(.drawer, "app", at: outsideZone)
        controller.endDrag()
        XCTAssertTrue(drawer.contains("app"))
        XCTAssertFalse(kept.contains("app"), "a reorder inside the drawer is not a 'drag in'")
    }

    /// Negative case: dragged into the drawer body and back out (undo)
    /// -> not in the drawer at landing, kept must not be turned on.
    func testStripCardRevertedOutOfDrawerDoesNotEnableKept() {
        begin(.strip, "app", at: outsideZone)
        controller.convertStripToDrawer()
        controller.revertStripFromDrawer()
        controller.endDrag()
        XCTAssertFalse(drawer.contains("app"))
        XCTAssertFalse(kept.contains("app"))
    }

    /// Negative case: a drawer icon promoted into the taskbar and then
    /// withdrawn. The drag source is `.drawer`, so it was already in the drawer,
    /// not brought in by this drag, so kept must not be turned on.
    func testDrawerToStripRevertedDoesNotEnableKept() {
        drawer.add("app")
        begin(.drawer, "app", at: outsideZone)
        controller.convertDrawerToStrip()
        controller.revertDrawerToStrip()
        controller.endDrag()
        XCTAssertTrue(drawer.contains("app"))
        XCTAssertFalse(kept.contains("app"))
    }

    /// Negative case: promoted into the taskbar and landed. No longer in the drawer after landing.
    func testCommittedDrawerToStripDoesNotEnableKept() {
        drawer.add("app")
        begin(.drawer, "app", at: outsideZone)
        controller.convertDrawerToStrip()
        controller.endDrag()
        XCTAssertFalse(drawer.contains("app"))
        XCTAssertFalse(kept.contains("app"))
    }

    /// **Semantics lock** (2026-08-06): after unchecking by hand, dragging it in again checks it **again**.
    /// This is not a bug: every drag-in restates "I want it to live
    /// here long term". Changing this needs a product decision first.
    func testDraggingInAgainReEnablesKeptAfterManualUncheck() {
        begin(.strip, "app", at: insideZone)
        controller.endDrag()
        XCTAssertTrue(kept.contains("app"))

        // Drag back to the taskbar (kept unchanged), then uncheck by hand.
        begin(.drawer, "app", at: outsideZone)
        controller.convertDrawerToStrip()
        controller.endDrag()
        XCTAssertTrue(kept.contains("app"), "dragging out of the drawer does not turn kept off")
        kept.remove("app")

        begin(.strip, "app", at: insideZone)
        controller.endDrag()
        XCTAssertTrue(kept.contains("app"), "dragging in again turns kept back on")
    }

    /// 2026-08-20: Finder can be dragged into the drawer too, and
    /// landing also checks keep (same treatment as ordinary apps).
    func testFinderEntersKeptThroughDrop() {
        kept.remove(FinderTaskbarPolicy.bundleID)   // cancels the one-time seeding done at store init
        begin(.strip, FinderTaskbarPolicy.bundleID, at: insideZone)
        controller.endDrag()
        XCTAssertTrue(kept.contains(FinderTaskbarPolicy.bundleID))
    }
}
