import AppKit
import Combine
import SwiftUI

// `DragSource` is defined in Core/Support/DragConversionPlan.swift (pure decision layer, compiled locally
// into the test target).

/// Container for the carrier panel. A plain transparent `NSView` whose layer hosts the `CALayer` holding the
/// carrier bitmap.
///
/// An `NSHostingView` cannot be used directly as `contentView` (project rule), and since 2026-08-18 the
/// carrier is not SwiftUI at all. It is a **non-flipped view**, so sublayer coordinates have a bottom-left
/// origin with y up, the same direction as screen coordinates, and conversion is only a translation (see
/// `DragCarrierGeometry`).
private final class CarrierContainerView: NSView {
    /// Non-nil **only during the return flight**: returns the icon's current (presentation) frame in this
    /// view's coordinates. The panel normally has `ignoresMouseEvents = true` and never reaches `hitTest`;
    /// only while the pointer is over the icon during the flight does the controller switch the panel to
    /// accept events (`DragController.refreshLandingGrabState`), and this guards once more by the icon's
    /// current frame: anything outside the icon returns `nil`.
    var grabRegion: (@MainActor () -> CGRect?)?
    /// Pressing on the flying icon -> continue the drag from where it is now
    /// (`DragController.regrabLanding`).
    var onGrab: (@MainActor (CGPoint) -> Void)?

    /// The carrier panel is never the key window, so the first press must be accepted too (same reason as
    /// `MenuActionButton`).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let region = grabRegion?(), region.contains(convert(point, from: superview)) else { return nil }
        return self
    }
    override func mouseDown(with event: NSEvent) { onGrab?(NSEvent.mouseLocation) }
}

/// What the carrier (the floating copy) is drawn as.
enum DragVisualKind { case stripChip, drawerIcon, folderChip, keptAppIcon, messagingIcon }

/// Generic drag payload. Taskbar cards have a `StripItem`; many drawer icons (running without windows /
/// stashed and not running / pinned only) have only a bundleID and no `StripItem`, so `item` is optional and
/// the primary key is always `bundleID`. `id` is for the source panel's own ordering (strip = the chip
/// identity token `item.id`, drawer = bundleID), so the source panel does not have to guess from the payload.
struct DragPayload {
    let source: DragSource
    let id: String          // strip = item.id (chip token); drawer = bundleID
    let bundleID: String
    let item: StripItem?     // Only taskbar window cards have one
    let visualKind: DragVisualKind
    /// Whether it can be dropped on "the other panel" to trigger stash / move back. strip = `canStash`;
    /// drawer = a real stashed item (`drawerStore.contains`). Pinned-only items = false: they can only be
    /// reordered inside the drawer, and dragging onto the taskbar neither highlights nor acts.
    let canExternalDrop: Bool
}

/// The single authority for cross-panel drags (drag a card into the drawer, route C / drag from the drawer
/// back to the taskbar, 2026-06-20/21).
///
/// Symmetric in both directions: a taskbar card dragged onto the capsule = stash; a drawer icon dragged onto
/// the taskbar = move back. One mechanism, a full-screen self-drawn carrier + a local monitor, is reused in
/// reverse (verified with a mechanism probe on 2026-06-20: after a drag starts from mouse-down, the implicit
/// grab lets the local monitor receive every event including the release). Everything lives here: carrier
/// panel lifecycle, monitors, drop target decisions, idempotent cleanup. Source panels only call `beginDrag`
/// and read `draggingPayload` (hide the original position) / `isOverDropZone` (reordering inside the drop
/// zone).
@MainActor
final class DragController: ObservableObject {
    @Published private(set) var draggingPayload: DragPayload?
    @Published private(set) var isOverDropZone = false

    /// Pointer position during the drag (screen coordinates). **Deliberately not `@Published`.**
    ///
    /// Measured 2026-08-18 (`DOCK_HOVER_TRACE`): it used to be `@Published`, and `DockStripView` subscribes
    /// to this object via `@EnvironmentObject`, so **every mouse move invalidated and recomputed the whole
    /// taskbar**. One second of dragging measured **46 full body recomputations** (each rebuilding the whole
    /// projection: snapshot to cards, membership projection, order reconciliation). With the main thread
    /// saturated by these, carrier position updates arrived late and frames were even dropped in fast drags.
    /// That is the reported "drag start lags" and "the icon briefly disappears when dragged fast".
    ///
    /// Now the value itself is a plain property and changes are broadcast through `pointerMoves`.
    /// - The carrier's **position** no longer goes through SwiftUI at all: `update()` sets the `position` of
    ///   the layer holding the bitmap directly (see `moveCarrier`).
    /// - Anything that needs to **run side effects every frame** (in-bar reordering, cross-panel conversion)
    ///   uses `.onReceive(pointerMoves)`: the closure still runs but creates no view dependency, so a redraw
    ///   happens only when the side effect actually changed something.
    private(set) var globalLocation: CGPoint = .zero
    private let pointerSubject = CurrentValueSubject<CGPoint, Never>(.zero)
    /// The card was "clicked" during the flight (regrabbed and released without moving past
    /// `regrabClickSlop`). The action is dispatched by the panel that owns the card (`.onReceive` in
    /// `DockStripView` / `DrawerView`); the controller does not know what a click on each kind of card should
    /// do.
    let carrierClicks: AnyPublisher<DragPayload, Never>
    private let carrierClickSubject = PassthroughSubject<DragPayload, Never>()
    /// **Stored as a `let`, don't erase on every call**: SwiftUI's `onReceive` resubscribes when the
    /// publisher instance changes, and `CurrentValueSubject` replays the current value on subscription, so
    /// every body pass would run the side effect for nothing.
    let pointerMoves: AnyPublisher<CGPoint, Never>
    /// Cross-display drop (multi-display ③④, 2026-09-02): on release a taskbar card is claimed by **another**
    /// strip (which took over while the pointer hovered over it, see `DockStripView.updateCrossStripHover`)
    /// -> window card: the window moves to that strip's display; windowless fallback card / kept placeholder:
    /// that app's "display the windowless icon lives on" becomes that display. The orchestration layer wires
    /// this to `AppRuntime.handleCrossStripDrop`.
    var onCrossStripDrop: ((DragPayload, String) -> Void)?

    private(set) var grabOffset: CGSize = .zero
    private(set) var carrierScreenFrame: CGRect = .zero

    // MARK: - Return flight after release

    /// The 0.26 seconds after release and before the carrier actually disappears: the floating copy flies
    /// from the pointer back to the slot. See `DragLandingPlan`. `nil` = no flight in progress (covers both
    /// switched off and no landing point available).
    struct Landing: Equatable {
        /// Fly back to the slot (correctable, regrabbable, clickable) / get pulled into the capsule (stash:
        /// fixed point, fixed duration, none of those).
        enum Kind { case returnToSlot, stash }
        /// A new token per flight: the carrier-retiring timer and the animation completion callback both
        /// claim by it, so two consecutive drags do not finish each other.
        let token: Int
        let payload: DragPayload
        let kind: Kind
        /// **The end point can change mid-flight** (`var`, not `let`). At release the slot is often still
        /// running its make-room animation and the measured position is an interpolated one; correcting once
        /// more after it settles keeps the icon from jumping at the very end.
        var flight: DragLandingFlight

        static func == (lhs: Landing, rhs: Landing) -> Bool {
            lhs.token == rhs.token && lhs.kind == rhs.kind && lhs.flight == rhs.flight
        }
    }
    @Published private(set) var landing: Landing?

    /// **Views always use this to decide "which cell stays empty".** The original position must stay empty
    /// during the return flight, otherwise the card appears while the carrier is still flying = two shadows
    /// again.
    ///
    /// The drag-start side **no longer has a gate**: the carrier is a bitmap, and `beginDrag` places it
    /// synchronously in the same run loop turn at the slot's position, same size, pixel for pixel over the
    /// card, so "when the card is hidden" can never expose a gap. Overlapping for a frame or two is
    /// invisible. The old `carrierReady` / `onAppear` report / 50ms fallback timer refereed a race between
    /// two renderers and was removed together with the switch to a bitmap carrier.
    var carriedPayload: DragPayload? { draggingPayload ?? landing?.payload }

    /// **Views use this to decide "which cell stays empty", not `carriedPayload`.** The drag-start side waits
    /// for `carrierArmed` (see that property for why); the landing side should appear as soon as `landing` is
    /// cleared, so the two ends are asymmetric.
    var hiddenSlotPayload: DragPayload? {
        if draggingPayload != nil { return carrierArmed ? draggingPayload : nil }
        return landing?.payload
    }

    /// The carrier has arrived and the card on the bar is visible, but the bitmap stays for one more run loop
    /// turn before it is removed (see `finishLanding`). Hover must stay suppressed during that turn.
    @Published private(set) var carrierRetiring = false

    /// **The moment the cell on the bar really becomes empty**, and the moment the lift animation starts. The
    /// two are tied together.
    ///
    /// At drag start the carrier bitmap is a brand-new `CGImage` whose first frame waits for a texture
    /// upload. Measured, it is **always** a full display frame later than SwiftUI hiding the card
    /// (2026-08-19, frame-by-frame comparison of recordings of three consecutive drags: frames 46 / 137 / 228
    /// each showed one frame of "slot already empty, carrier not on screen yet", and keeping the panel up
    /// without `orderOut` changed nothing, so it is not `orderFront` latency).
    ///
    /// Two paths, depending on whether there is a **prepared candidate** (see `prepareCandidate`):
    /// - The bitmap was already attached to the layer at mouse down and its texture warmed up at an opacity
    ///   invisible to the eye -> released in the drag-start turn: lighting the carrier and hiding the card
    ///   happen in the same turn and the same commit, and `liftCarrier` runs in that turn too.
    /// - No candidate (the caller did not prepare one, or it does not match) -> first let the carrier appear
    ///   at the slot's position, same size, pixel for pixel, and "hide the card + lift" only **after two
    ///   display frames** (`DragLandingPlan.pickUpSettle`). The first version deferred by "one run loop
    ///   turn": synthetic drags step every 16ms, so the next turn fell exactly on the next frame and nothing
    ///   showed; a real mouse sends an event every 1–8ms, so the next turn is often still in the same frame,
    ///   the card is hidden and the bitmap is not on screen = a one-frame gap, the "sometimes disappears"
    ///   reported on 2026-08-19. Deferring by time rather than by turns is what lines up with display frames.
    /// Overlapping for a frame or two is harmless; a one-frame gap is a visible flash.
    @Published private(set) var carrierArmed = false

    /// "Holding something" (including the return flight after release and the final overlap turn). **Must
    /// stay true until the carrier is really gone**, otherwise the card is already in hover state on the
    /// overlap frame (the quiet level also scales it to 1.10) and differs visibly from the carrier's last
    /// frame.
    var isCarrying: Bool { carriedPayload != nil || carrierRetiring }

    /// The period when hover evaluation must be **frozen in place**: the carrier already sits over the slot
    /// and the card is not hidden yet.
    ///
    /// During these frames the carrier's pose follows the slot's current combined "hover × press" shape
    /// (`DragCarrierGeometry.pickUpPose`). If the card lost its hover at this point because "a drag started"
    /// and began its 0.12s fall-back, the two would no longer match; the first version exposed the "vertical
    /// ghosting" exactly this way. So at drag start **touch nothing**: `hoveredEntryID` stays as is.
    var hoverFrozen: Bool { draggingPayload != nil && !carrierArmed }

    /// The period when **the whole taskbar evaluates no hover**: only while "really holding something".
    ///
    /// Lighting up whatever the pointer passes during a drag, with a name bubble, was never right: other
    /// icons don't light up while dragging in the native Dock either.
    ///
    /// **The return flight is not included** (reported 2026-08-19: "no hover effect when passing over other
    /// icons while the icon is flying"): after release the mouse is free, and natively other icons still show
    /// their name when passed over. During the flight only **the one that is flying** is exempted, see
    /// `hoverExemptPayload`.
    var hoverSuppressed: Bool { draggingPayload != nil && carrierArmed }

    /// The one card that is **individually exempted**: the one flying back / the one that just landed and has
    /// not seen the pointer move yet. Other cards hover as usual.
    ///
    /// Both reasons concern only this one card, not the others:
    /// - During the flight its slot is empty; if hover were assigned to it then, it would already be in hover
    ///   state when it lands and appears (the quiet level also scales it to 1.10), while the carrier's last
    ///   frame draws the **non-hover** state, and the handover frame would pop;
    /// - After landing the pointer is necessarily over it, and re-evaluating hover right after the card
    ///   settles at 1.0 would make it grow on the spot: the "landing jitter" reported on 2026-08-19. AppKit
    ///   itself also sends mouseEntered after a drop only once the mouse moves (the hold period is handled by
    ///   `hoverHoldPayload` and released as soon as the pointer moves).
    ///
    /// The carrier-retiring turn (card visible, bitmap not yet removed) needs no separate handling:
    /// `finishLanding` and the no-flight branch of `teardown` both call `beginHoverHold(for:)` **before**
    /// `retireCarrierAfterHandoff()`, so that turn is covered by the hold.
    var hoverExemptPayload: DragPayload? { landing?.payload ?? hoverHoldPayload }

    /// Combined value of the hover gate. Views use it to trigger re-evaluation: looking at `hoverSuppressed`
    /// alone, "the exempted target changed" would trigger none (and the end of the flight is exactly such a
    /// change).
    var hoverGate: HoverGate {
        HoverGate(suppressed: hoverSuppressed, exemptID: hoverExemptPayload?.id,
                  exemptSource: hoverExemptPayload?.source)
    }
    struct HoverGate: Equatable {
        let suppressed: Bool
        let exemptID: String?
        let exemptSource: DragSource?
    }

    /// The card that just landed while the pointer has not moved yet. While non-nil, hover is fully
    /// suppressed; cleared as soon as the pointer moves (or by the 3-second fallback). The drawer side uses
    /// it to suppress `LauncherChip`'s hover feedback; the taskbar side goes through `hoverSuppressed`.
    @Published private(set) var hoverHoldPayload: DragPayload?
    private var hoverHoldTimer: Timer?
    private var hoverHoldOrigin: CGPoint = .zero
    private var hoverHoldStartedAt: CFTimeInterval = 0

    /// Scale while being held. The carrier and the flight start share this one expression: written separately
    /// they drifted.
    ///
    /// Shrinking to `dropZoneScale` expresses "releasing now stashes it into the drawer", so it **applies
    /// only to sources taken off the bar**. Drawer sources do not shrink (2026-08-20): their "drop zone" is
    /// the whole taskbar, so shrinking would make them smaller as soon as they enter the bar, while in-bar
    /// drags never shrink on the bar; in the normal case they would also shrink to 0.82 and be converted and
    /// bounce back to 1.0 in the same turn, two 0.12s animations fighting; and in the `.reject` /
    /// `.releaseToMessaging` modes they would stay shrunk throughout.
    var carriedScale: CGFloat {
        guard let source = draggingPayload?.source, source != .drawer else {
            return DragLandingPlan.carriedScale
        }
        return isOverDropZone && !isConvertedToStrip
            ? DragLandingPlan.dropZoneScale : DragLandingPlan.carriedScale
    }

    /// The scale the carrier should have right now. A folder chip dragged out of the taskbar's visible range
    /// gets an extra enlargement on top (`.folder` always has `canExternalDrop == false`, so the
    /// `carriedScale` branch is always the normal value and the two don't conflict).
    private var carrierVisualScale: CGFloat {
        guard draggingPayload?.source == .folder, folderDragZone == .outsideStrip else { return carriedScale }
        return carriedScale * DragLandingPlan.folderRemovalScale
    }

    /// The opacity the carrier should have right now. Only "a folder chip dragged out of the taskbar's
    /// visible range" fades.
    private var carrierVisualOpacity: Float {
        draggingPayload?.source == .folder && folderDragZone == .outsideStrip
            ? DragLandingPlan.folderRemovalOpacity : 1
    }

    /// Landing anchor (screen coordinates). **Each of the two views writes its own, on every pointer
    /// update**, tagged with an owner: the taskbar side handles `.strip` / `.messaging` payloads, the drawer
    /// side handles `.drawer` payloads. Without the owner tag, after a drawer icon is converted into the
    /// taskbar the stale anchor written by the drawer would remain, and the icon would fly into the already
    /// closed drawer.
    enum LandingAnchorOwner { case strip, drawer }
    private var landingAnchor: (owner: LandingAnchorOwner, rect: CGRect)?
    private var landingTimer: Timer?
    /// Whether the CA animation for this return flight has been issued. False during the hold period
    /// (`DragLandingPlan.landingSettle`), where a correction only changes the end point without reissuing;
    /// true after takeoff, where a correction really reissues the animation.
    private var landingLaunched = false
    private var landingLaunchTask: DispatchWorkItem?
    /// +1 each time the flight animation is (re)issued. CA's completion callback also fires when an animation
    /// is **replaced**, which `landing.token` alone cannot detect (a correction does not change the token),
    /// so a separate generation is kept.
    private var landingAnimation = 0
    private var dragBeganAt: CFTimeInterval = 0
    private var landingToken = 0
    /// A correction can push the flight later, but not indefinitely. This cap is fixed when the flight
    /// starts.
    private var landingDeadline: CFTimeInterval = 0

    func setLandingAnchor(_ rect: CGRect?, owner: LandingAnchorOwner) {
        if let rect {
            landingAnchor = (owner, rect)
            if owner == .strip { lastKnownSlotAnchor = rect }
        } else if landingAnchor?.owner == owner {
            landingAnchor = nil
        }
        if landing != nil {
            HoverTrace.landingAnchor(owner: "\(owner)", rect: landingAnchor?.rect)
        }
        retargetLandingIfNeeded()
    }

    /// **Mid-flight correction** during the flight.
    ///
    /// At release the slot is most likely still running a make-room animation (the 0.28s spring in the bar /
    /// the 0.22s grid reflow in the drawer), and `GeometryReader` reports an interpolated intermediate value.
    /// Flying to it means that when the carrier is removed the card has settled somewhere else, and that gap
    /// of ten-odd pt is the observed "still jittering after landing". The anchor keeps updating during the
    /// flight (the view side now reports per-frame changes, see `updateLandingAnchor`), the end point follows
    /// here, and SwiftUI continues smoothly from the current position.
    ///
    /// Threshold 0.5pt: sub-pixel jitter is not worth a reissue (`DockStripView` observes this object, and
    /// every publish recomputes the whole body).
    private func retargetLandingIfNeeded() {
        guard var current = landing,
              DragLandingPlan.allowsRetarget(
                remainingBeforeDeadline: landingDeadline - CACurrentMediaTime(),
                flightDuration: current.flight.duration)
        else { return }
        // **The two flights follow two different end points and must never be mixed.** `.returnToSlot`
        // follows the slot anchor; `.stash` follows the **capsule** (fetching `stashTargetProvider` again).
        // `.stash` used to be excluded from correction entirely, the comment's reason being "for a frame or
        // two after stashing the taskbar still reports that cell's old frame, and following it would pull the
        // icon back onto the bar". That was about the slot anchor, not the capsule, so splitting by end point
        // source is enough. The cost of excluding it was the 2026-08-20 report "dragged onto the capsule, the
        // icon occasionally flies outside the drawer": the end point is computed at release and
        // `drawerStore.add` comes after; once the card leaves the bar, the bar narrows and recenters, the
        // capsule slides left for 0.22s, and the flight still heads for the capsule's old position.
        let updatedFlight: DragLandingFlight?
        switch current.kind {
        case .returnToSlot:
            var from = current.flight.from
            // Not yet airborne but the anchor is on another display (after a cross-display window drag is
            // released, the anchor is reported one turn later by the other strip): switch the carrier panel
            // first and recompute the start from the new panel's origin, the same way as `plannedLanding`. No
            // display switch after takeoff.
            if !landingLaunched, let rect = landingAnchor?.rect,
               !carrierScreenFrame.contains(CGPoint(x: rect.midX, y: rect.midY)) {
                followScreenIfNeeded(CGPoint(x: rect.midX, y: rect.midY))
                placeCarrierUnderPointer()
                from = DragCarrierGeometry.topLeftCarriedCenter(pointer: globalLocation,
                                                                grabOffset: grabOffset,
                                                                panelFrame: carrierScreenFrame)
            }
            updatedFlight = DragLandingPlan.flight(from: from,
                                                   fromScale: current.flight.fromScale,
                                                   anchorScreenRect: landingAnchor?.rect,
                                                   carrierScreenFrame: carrierScreenFrame)
        case .stash:
            updatedFlight = DragLandingPlan.stashFlight(from: current.flight.from,
                                                        fromScale: current.flight.fromScale,
                                                        targetScreenRect: stashTargetProvider(),
                                                        carrierScreenFrame: carrierScreenFrame)
        }
        guard let updated = updatedFlight,
              hypot(updated.to.x - current.flight.to.x, updated.to.y - current.flight.to.y) > 0.5
        else { return }
        HoverTrace.landingRetarget(from: updated.from, to: updated.to, previous: current.flight.to)
        // Still in the hold period (`DragLandingPlan.landingSettle`): only change the end point, don't take
        // off. This change is most likely "the grid moved one cell after the drop was committed", and taking
        // off right away would mean flying toward the old cell and then being pulled back, the very kinked
        // path this is meant to cure. Before takeoff the whole flight (including duration and curve computed
        // from the new distance) can be replaced.
        guard landingLaunched else {
            current.flight = updated
            landing = current
            return
        }
        // Already flying: **only slide the end point along the original timeline, don't issue a new curve.**
        // The old approach reissued a whole segment with `flyCarrier(along: updated)`, each time starting
        // again from the current position and easing to a stop; with the anchor drifting frame by frame for
        // 0.22s it reissued about ten times, the "landing moves in jerks" reported on 2026-09-03. A finished
        // flight is not changed any more (left to finish).
        guard let timeline = flightTimeline,
              CACurrentMediaTime() - timeline.beganAt < timeline.duration else { return }
        let slid = current.flight.sliding(to: updated.to, toScale: updated.toScale)
        current.flight = slid
        landing = current
        slideLanding(to: slid, token: current.token)
    }

    /// Implementation of the mid-flight correction: the translation / scale animations are reattached **with
    /// the original `beginTime`, duration and curve**, only the end value replaced by the new end point. CA
    /// continues from the current progress on the same curve, the carrier slides along one continuous path to
    /// the new cell, and the time the carrier is retired does not change (the fallback timer is not
    /// rescheduled). The completion callback checks the generation: the callback of the replaced animation
    /// pair fires immediately and must not end the flight (same as `flyCarrier`).
    private func slideLanding(to flight: DragLandingFlight, token: Int) {
        guard let layer = carrierLayer, let timeline = flightTimeline else { return }
        let destination = alignedCenter(
            DragCarrierGeometry.panelPoint(fromTopLeft: flight.to, panelFrame: carrierScreenFrame), on: layer)
        let toTransform = Self.scaleTransform(flight.toScale)
        landingAnimation &+= 1
        let generation = landingAnimation
        let c = timeline.curve
        let timing = CAMediaTimingFunction(controlPoints: Float(c.c0x), Float(c.c0y), Float(c.c1x), Float(c.c1y))
        let beginTime = layer.convertTime(timeline.beganAt, from: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // Model values go straight to the target; the two explicit animations below handle the animation
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                guard let self, self.landingAnimation == generation else { return }
                self.finishLanding(token: token)
            }
        }
        let tracks: [(String, Any, Any)] = [
            ("position", NSValue(point: timeline.start.position), NSValue(point: destination)),
            ("transform", NSValue(caTransform3D: Self.scaleTransform(timeline.start.scale)),
                          NSValue(caTransform3D: toTransform))
        ]
        for (keyPath, from, to) in tracks {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.beginTime = beginTime
            animation.duration = timeline.duration
            animation.timingFunction = timing
            layer.add(animation, forKey: keyPath)
        }
        layer.position = destination
        layer.transform = toTransform
        CATransaction.commit()
        flightTimeline = FlightTimeline(beganAt: timeline.beganAt, start: timeline.start,
                                        destination: LayerPose(position: destination, scale: flight.toScale),
                                        duration: timeline.duration, curve: timeline.curve)
    }

    /// Arrived at the end point. **Let the card on the bar appear first, and remove the carrier one run loop
    /// turn later**; both ends are "new first, old second". The card is already on screen, the carrier's last
    /// frame has the same pixels and position, so the overlap frame is invisible; removing the carrier first
    /// would necessarily expose one empty frame (the other side of the "landing ghost" reported on
    /// 2026-08-18). Idempotent.
    func finishLanding(token: Int) {
        guard let current = landing, current.token == token else { return }
        landingTimer?.invalidate(); landingTimer = nil
        landingLaunchTask?.cancel(); landingLaunchTask = nil
        landingAnimation &+= 1
        endLandingGrabWatch()
        flightTimeline = nil
        recordLandingDelta()
        beginHoverHold(for: current.payload)   // Hold hover first, then let the card appear; the reverse order causes a jitter
        landing = nil            // ← the bar / drawer lets the card appear in this turn's SwiftUI commit
        convertedChipID = nil    // The converted card's empty slot is held until here and released in the same turn as `landing`
        clearStripClaims()
        setStripSlotCollapsed(false)   // The one pulled into the capsule is a drawer member by now and no longer on the bar anyway
        lastKnownSlotAnchor = nil
        hideCarrierInSlotRevealCommit()
        retireCarrierAfterHandoff()
    }

    /// The copy disappearing and the card appearing must land in **the same** CA commit.
    ///
    /// The card's appearance is committed by SwiftUI with the implicit transaction at the end of this run
    /// loop turn; if the carrier were retired a turn later (`retireCarrierAfterHandoff`), a single vsync
    /// between the two commits is enough to show one frame of "card visible, still holding one". The
    /// appearing frame used to re-decode the icon (`AppIconResolver`'s cache kept missing) and was slow by
    /// itself, so the card often was not drawn yet when the copy went away; after the cache was fixed on
    /// 2026-09-04 the appearance got faster, while the next turn was often held up 25~30ms by a full-bar
    /// recomputation, so this frame went from occasional to common (reported that day: "dragging from the
    /// drawer into the taskbar sometimes ghosts").
    ///
    /// So the assignment here **deliberately uses the implicit transaction**: it goes out in the same
    /// end-of-turn commit as SwiftUI's appearance. It cannot be wrapped in `instantly`: without an enclosing
    /// implicit transaction an explicit transaction is sent at once, the copy disappears before the card, and
    /// the gap is reversed. Landing is a timer callback with no event flood, so the implicit transaction is
    /// always flushed in this turn (the rule "carrier changes must use explicit transactions" is about the
    /// drag in progress). `carrierActionGate` turns implicit actions off only for this one assignment,
    /// otherwise opacity would take the default 0.25s fade.
    private func hideCarrierInSlotRevealCommit() {
        guard let layer = carrierLayer else { return }
        carrierActionGate.suppressesImplicitActions = true
        layer.opacity = 0
        carrierActionGate.suppressesImplicitActions = false
    }

    /// Retires the carrier one run loop turn later and keeps hover suppressed during that turn
    /// (`carrierRetiring`).
    private func retireCarrierAfterHandoff() {
        carrierRetiring = true
        let generation = carrierGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Generation mismatch = a new drag already started in the next turn and the carrier belongs to
            // it; but this flag was set by this turn and must be cleared by this turn. Left set it would
            // suppress the new drag's hover as well (in the first version this stayed hidden only because
            // `abortLanding()` in `beginDrag` happened to clear it).
            defer { self.carrierRetiring = false }
            guard self.carrierGeneration == generation else { return }
            self.retireCarrier()
        }
    }

    // MARK: - Interruptible return flight (2026-08-19: native and bestdock allow it, ours was hard to grab)

    /// Pressing the icon during the flight -> continue the drag from its position **right now**; the slot
    /// stays empty throughout, no flash.
    ///
    /// The carrier is a bitmap on another panel and normally takes no events; without this, a press on the
    /// flying icon falls through to what is below: either its own empty slot (`beginDrag` -> `abortLanding`
    /// -> the icon jumps from mid-air back to the slot and lifts again), or a neighbor (the neighbor is
    /// picked up), or the desktop. The native Dock flies the icon itself, so any press hits it.
    ///
    /// - Parameter requireHit: `true` = the point must fall inside the icon's current frame (a press received
    ///   by the carrier panel itself); `false` = the same card's slot is pressed (a SwiftUI gesture started a
    ///   drag with the same payload), and the icon continues however far it is from the pointer, the grab
    ///   offset being its current position relative to the pointer. As in the native Dock, the icon does not
    ///   jump under the pointer.
    @discardableResult
    func regrabLanding(at screenPoint: CGPoint, requireHit: Bool = true) -> Bool {
        guard let current = landing, current.kind == .returnToSlot,
              let layer = carrierLayer, carrierScreenFrame.width > 0 else { return false }
        if requireHit {
            guard let iconFrame = landingIconScreenFrame(), iconFrame.contains(screenPoint) else { return false }
        }
        // Freeze at the current position **computed from the timeline** (not `presentation()`, see
        // `FlightTimeline` for why).
        let elapsedMs = flightTimeline.map { (CACurrentMediaTime() - $0.beganAt) * 1000 } ?? 0
        // Estimated slightly ahead (`grabFreezeLead`): two frame captures measured the freeze point 2–3pt
        // (about 0.25 frame) behind the last frame on screen. Going a pt or two too far looks like "moved
        // once more and stopped"; going backwards is the jitter the eye sees.
        let pose = landingPose(at: CACurrentMediaTime() + Self.grabFreezeLead)
            ?? LayerPose(position: layer.position, scale: Self.scale(of: layer.transform))
        landingTimer?.invalidate(); landingTimer = nil
        landingAnimation &+= 1          // CA completion callbacks are discarded by generation
        endLandingGrabWatch()
        Self.instantly {
            layer.removeAllAnimations()
            layer.position = self.alignedCenter(pose.position, on: layer)
            layer.transform = Self.scaleTransform(pose.scale)
            layer.opacity = 1
        }
        grabOffset = DragCarrierGeometry.grabOffset(pointer: screenPoint, carriedCenter: pose.position,
                                                    panelFrame: carrierScreenFrame)
        // Click or drag is only known at release: record the press point; while pressed the carrier shrinks
        // slightly (same as a chip's press feedback), moving past `regrabClickSlop` returns it to the held
        // look (`update`), and not moving is a click (`endDrag`).
        regrabOrigin = screenPoint
        regrabPressed = ChipPressSwitches.pressDownEnabled
        // **State switches inside one synchronous block**: both branches of `hiddenSlotPayload` point at the
        // same card in turn, so the slot stays empty continuously.
        let payload = current.payload
        draggingPayload = payload
        carrierArmed = true
        carrierLifted = true
        landing = nil
        carrierRetiring = false
        endHoverHold()
        dragBeganAt = CACurrentMediaTime()
        globalLocation = screenPoint
        pointerSubject.send(screenPoint)
        refreshDropZone()
        installMonitors()
        startPoll()
        flightTimeline = nil
        applyCarrierVisualState(animated: true)   // Scale 0.93 during the press
        HoverTrace.dragHandoff("regrab", msSinceBegin: elapsedMs)
        return true
    }
    /// Where the regrab press happened, and whether it is still in the "pressed, not moved" state.
    private var regrabOrigin: CGPoint?
    private var regrabPressed = false

    /// Hit area of the flying icon (carrier panel coordinates): **the current frame ∪ the frame two frames
    /// ago**; nil when not flying.
    ///
    /// People press at the position they saw a frame or two ago, and the press event takes another 10–20ms to
    /// reach us; in the first part of the flight a frame covers ten-odd pt, so accepting only the current
    /// frame would just miss (synthetic measurement 2026-08-19: pressed at the origin 46ms after release, the
    /// icon had travelled 28pt with a half height of 27pt, a miss by 1pt). Adapts to speed: a longer tail
    /// when flying fast, almost no extension in the slow final part.
    private func landingIconPanelFrame() -> CGRect? {
        guard let layer = carrierLayer else { return nil }
        let now = CACurrentMediaTime()
        guard let current = landingPose(at: now), let trailing = landingPose(at: now - Self.grabTrail) else { return nil }
        func frame(_ pose: LayerPose) -> CGRect {
            let size = CGSize(width: layer.bounds.width * pose.scale, height: layer.bounds.height * pose.scale)
            return CGRect(x: pose.position.x - size.width / 2, y: pose.position.y - size.height / 2,
                          width: size.width, height: size.height)
        }
        return frame(current).union(frame(trailing))
    }
    /// How far back the hit area reaches (about two display frames).
    private static let grabTrail: CFTimeInterval = 0.034
    /// Lead for the regrab freeze point (about a quarter frame, see `regrabLanding` for why).
    private static let grabFreezeLead: CFTimeInterval = 0.005

    /// Same as above, in screen coordinates.
    private func landingIconScreenFrame() -> CGRect? {
        guard carrierScreenFrame.width > 0, let frame = landingIconPanelFrame() else { return nil }
        return frame.offsetBy(dx: carrierScreenFrame.minX, dy: carrierScreenFrame.minY)
    }

    /// During the flight, checks at 60Hz whether the pointer is over the icon: yes -> the carrier panel
    /// accepts events (a press is a regrab); no -> it takes no events as before.
    ///
    /// **Why events cannot be accepted for the whole flight**: with `ignoresMouseEvents = false` on a
    /// transparent panel, clicks in transparent areas do **not** pass through to the window below (measured
    /// in a spike on 2026-08-19: clicks where `hitTest` returns nil are swallowed and the window below never
    /// gets them). That would make every click on another icon fail for 0.9s after landing. So events are
    /// accepted only on the frames where the pointer is over the icon. Polling is the same kind as the
    /// landing hover hold (`.common`, a result as soon as the pointer moves, at most one flight long).
    private func beginLandingGrabWatch() {
        landingGrabTimer?.invalidate()
        refreshLandingGrabState()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                guard self.landing != nil else { timer.invalidate(); return }
                self.refreshLandingGrabState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        landingGrabTimer = timer
    }

    private func endLandingGrabWatch() {
        landingGrabTimer?.invalidate(); landingGrabTimer = nil
        setCarrierAcceptsMouse(false)
    }

    private func refreshLandingGrabState() {
        let inside = landingIconScreenFrame()?.contains(NSEvent.mouseLocation) == true
        setCarrierAcceptsMouse(inside)
    }

    /// Only the current panel set may accept events; the others never do. Compare before writing, don't hit
    /// WindowServer every frame.
    private func setCarrierAcceptsMouse(_ accepts: Bool) {
        for surface in surfaces {
            let ignores = !(accepts && surface.panel === carrierPanel)
            if surface.panel.ignoresMouseEvents != ignores { surface.panel.ignoresMouseEvents = ignores }
        }
    }
    private var landingGrabTimer: Timer?

    // MARK: - Hover hold after landing

    /// Holds hover from the moment of landing until the pointer really moves (or the 3-second fallback).
    ///
    /// Polls `NSEvent.mouseLocation` at 60Hz instead of using an event monitor: none of this app's panels is
    /// the key window, so there is no guarantee `.mouseMoved` reaches a local monitor (the taskbar's tracking
    /// area switched to polling for this reason, see `StripPointerTracker`), and a global `.mouseMoved`
    /// monitor is a persistent event tap that a project rule explicitly bans. The polling is transient: it
    /// stops as soon as the pointer moves, 3 seconds at most.
    private func beginHoverHold(for payload: DragPayload) {
        hoverHoldTimer?.invalidate()
        hoverHoldPayload = payload
        hoverHoldOrigin = NSEvent.mouseLocation
        hoverHoldStartedAt = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            Task { @MainActor in
                // Stop itself when the controller is gone: a `repeats: true` timer does not stop just because
                // self is released.
                guard let self else { timer.invalidate(); return }
                guard self.hoverHoldPayload != nil else { timer.invalidate(); return }
                let now = NSEvent.mouseLocation
                let moved = hypot(now.x - self.hoverHoldOrigin.x, now.y - self.hoverHoldOrigin.y) > 0.5
                let expired = CACurrentMediaTime() - self.hoverHoldStartedAt > DragLandingPlan.hoverHoldMaximum
                if moved || expired { self.endHoverHold() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverHoldTimer = timer
    }

    private func endHoverHold() {
        hoverHoldTimer?.invalidate(); hoverHoldTimer = nil
        if hoverHoldPayload != nil { hoverHoldPayload = nil }
    }

    /// Removes the carrier bitmap and panel at once. **Call only when "the card is already visible" or "there
    /// is no card to show at all".**
    private func retireCarrier() {
        if let layer = carrierLayer {
            Self.instantly {
                layer.removeAllAnimations()
                layer.contents = nil
            }
        }
        carrierSnapshot = nil
        originSnapshot = nil
        // **The panel stays up, no orderOut.** It is fully transparent, takes no mouse events, and sits one
        // level above our own panels; an orderOut / orderFront round trip on every drag only buys timing
        // traps of the "a freshly ordered window's content reaches the screen a few frames late" kind
        // (measured 2026-08-19 with the same code: kept up, 6/6 drag starts had no gap and the carrier always
        // showed; with repeated ordering the carrier stayed off screen for the whole drag several times).
    }

    /// Ends the flight at once with no handover (interrupted by a new drag, abnormal cancel, panel teardown).
    /// On these paths the slot may not exist any more, so retiring the carrier is not deferred.
    func abortLanding() {
        landingTimer?.invalidate(); landingTimer = nil
        landingLaunchTask?.cancel(); landingLaunchTask = nil
        landingAnimation &+= 1
        endLandingGrabWatch()
        flightTimeline = nil
        carrierRetiring = false
        convertedChipID = nil
        clearStripClaims()
        setStripSlotCollapsed(false)
        lastKnownSlotAnchor = nil
        guard landing != nil else { return }
        landing = nil
        retireCarrier()
    }

    /// The capsule highlight is lit only while "a taskbar card / messaging chip is hovering over the stash
    /// zone". The opposite direction has **no** symmetric full-bar highlight: dragging a drawer icon back to
    /// the taskbar is expressed by cards making room (2026-08-20, matching the native Dock, see
    /// `DockStripView.stripHighlighted`).
    var isOverStashZone: Bool {
        guard isOverDropZone, let s = draggingPayload?.source else { return false }
        return s == .strip || s == .messaging
    }

    /// Cross-panel **temporary conversion** state: explicit "original source + rollback snapshot", with at
    /// most one conversion in progress at a time (review 2026-07-11: no more stacked boolean flags). commit =
    /// `teardown()` clears the state without rolling back; rollback = each revert method restores from the
    /// snapshot; `cancelDrag()` rolls back by the current case and then cleans up. `@Published`: carrier
    /// switching, taskbar width freeze and the membership observer exemption all need to drive a refresh.
    enum CrossPanelConversion {
        /// A taskbar card is temporarily stashed in the drawer. Rollback = drawer.remove + restore the
        /// payload; kept unchanged.
        case stripToDrawer(original: DragPayload)
        /// A drawer icon is temporarily converted into the taskbar (unstash / keepPlacement). Rollback =
        /// drawer.add.
        case drawerToStrip(bundleID: String)
        /// A messaging zone chip is temporarily stashed in the drawer. Rollback = drawer.remove + restore the
        /// `.messaging` payload.
        case messagingToDrawer(original: DragPayload)
        /// A running messaging app in the drawer is temporarily released back to the messaging zone. Rollback
        /// = drawer.add + restore the `.drawer` payload.
        case drawerToMessaging(original: DragPayload)

    }
    @Published private(set) var conversion: CrossPanelConversion?

    /// Projection kept for existing view-layer call sites (reads `conversion`; @Published guarantees it
    /// drives a refresh).
    var convertedDrawerBundleID: String? {
        if case let .drawerToStrip(bid) = conversion { return bid }
        return nil
    }
    var isConvertedToStrip: Bool { convertedDrawerBundleID != nil }
    var isConvertedFromStrip: Bool {
        if case .stripToDrawer = conversion { return true }
        return false
    }
    var isConvertedFromMessaging: Bool {
        if case .messagingToDrawer = conversion { return true }
        return false
    }
    var isReleasedToMessaging: Bool {
        if case .drawerToMessaging = conversion { return true }
        return false
    }

    /// The **single representative card** the carrier draws after conversion. Written by DockStripView once
    /// the window card is materialized (the app's first materialized **real window card** in display order);
    /// nil before that (the carrier still draws the small drawer icon). Cleared by `revert`/`teardown`.
    @Published private(set) var convertedRepresentative: StripItem?

    /// **Which card on the bar to hide** after conversion (to leave the gap). Deliberately a separate field
    /// from the one above:
    ///
    /// The carrier can only draw a `StripItem`, while what materializes on the bar may be a `.keptApp`
    /// placeholder or an `isAppLevelFallback` fallback card. Neither is something that "can be drawn as a
    /// window card", and `liveChipIDs` excludes them too. Earlier both jobs shared the single field
    /// `convertedRepresentative`, so on the `keepPlacement` path (kept apps that are not running, running
    /// apps with only an app-level fallback card) it was always nil, and **the card on the bar was drawn
    /// fully opaque while the same icon was still held = two shadows** (reported 2026-08-18). So this stores
    /// the chip id, not the card itself.
    @Published private(set) var convertedChipID: String?
    /// The "active strip surface" of the current drag (under multi-display ③④ there are several taskbars with
    /// the same content, all subscribed to this controller, but only one may write back the landing anchor /
    /// reorder / convert. Otherwise the bar on another display would report its own display's rect as the
    /// landing point and the carrier would fly to the wrong display; see `DockStripView.ownsActiveDrag`). The
    /// strip where the drag starts claims it before `beginDrag`; for a drag starting in the drawer, the strip
    /// under the pointer claims it at conversion and releases it when the conversion is reverted; cleared
    /// when the landing ends or aborts. **Not `@Published`**: it changes once at drag start and once at
    /// landing, not worth recomputing the whole taskbar.
    private(set) var activeStripSurfaceID: String?
    /// The strip where the drag started (nil for a drag starting in the drawer). Cross-display drop criterion
    /// = `activeStripSurfaceID != originStripSurfaceID` at release.
    private(set) var originStripSurfaceID: String?
    /// The display the currently claiming strip is fixed to (passed in by
    /// `claimStripSurface(_:displayUUID:)`), used to move the window on a cross-display drop.
    private(set) var activeStripDisplayUUID: String?
    /// +1 when the claim changes hands. `activeStripSurfaceID` is deliberately not `@Published`, but under ④
    /// the projection layer decides by the claim which bar draws the dragged card
    /// (`DockStripView.makeProjection`), so a handover must make each bar recompute once. Handovers only
    /// happen when the pointer crosses bars, not every frame.
    @Published private(set) var stripClaimGeneration = 0

    func claimStripSurface(_ id: String, displayUUID: String? = nil) {
        activeStripDisplayUUID = displayUUID
        guard activeStripSurfaceID != id else { return }
        // Handover = the old bar's slot means nothing to the new bar. If kept, releasing over empty space on
        // display B after a cross-display drag would first fly toward bar A's old slot (the carrier panel
        // switches to display A and the icon vanishes from display B), and by the time B reports the real
        // anchor it is already in the wrong panel's coordinates (2026-09-03).
        if activeStripSurfaceID != nil {
            lastKnownSlotAnchor = nil
            if landingAnchor?.owner == .strip { landingAnchor = nil }
        }
        activeStripSurfaceID = id
        stripClaimGeneration &+= 1
    }

    private func clearStripClaims() {
        activeStripSurfaceID = nil
        originStripSurfaceID = nil
        activeStripDisplayUUID = nil
    }

    /// **Close up on drag-out** (2026-09-03, matching the native Dock; reverses the 2026-08-20 "taking a card
    /// off the bar clamps the bar width"): when the card whose drag started on the bar (window card /
    /// placeholder / messaging chip / folder chip) has left the taskbar, meaning the pointer is clearly
    /// outside the currently claiming bar's decision frame or the card was converted into the drawer body,
    /// the bar no longer keeps a gap for it and the panel shortens; it is restored when the pointer enters
    /// any bar's decision frame again. Before, the gap stayed throughout and the bar width did not change,
    /// which was reported as "unintuitive". `@Published`: the projection layer decides by it whether to draw
    /// that card (`DockStripView.makeProjection`), and `PanelCoordinator` relays out the panel width by it.
    @Published private(set) var stripSlotCollapsed = false
    /// While closed up, the bar cannot report a slot frame (the card is not in the layout). A release outside
    /// the bar and outside any drop zone has to reopen the slot first and then fly; this is that flight's
    /// temporary end point, the last slot reported. As soon as the slot frame is reported again, correction
    /// takes it to the real position.
    private var lastKnownSlotAnchor: CGRect?

    /// The pointer entered a strip's decision frame (`DockStripView.updateStripPresence`, which runs before
    /// the ownership gate). Only the currently claiming strip's frame counts: the claim itself is decided by
    /// the display the pointer is on (`.strip` payloads cross displays, `claimStripSurface`); messaging /
    /// folder chips do not cross bars, and their claim stays with the strip where the drag started.
    func noteStripEntered(surfaceID: String, displayUUID: String?) {
        guard let p = draggingPayload, p.source != .drawer, conversion == nil,
              activeStripSurfaceID == surfaceID else { return }
        setStripSlotCollapsed(false)
    }

    /// The pointer is clearly outside this strip's decision frame. Only the currently claiming strip leaving
    /// counts as "left the taskbar" (the claim does not change hands because of it).
    func noteStripLeft(surfaceID: String) {
        guard let p = draggingPayload, p.source != .drawer, conversion == nil,
              activeStripSurfaceID == surfaceID else { return }
        setStripSlotCollapsed(true)
    }

    private func setStripSlotCollapsed(_ collapsed: Bool) {
        guard stripSlotCollapsed != collapsed else { return }
        stripSlotCollapsed = collapsed
    }

    func setConvertedRepresentative(_ item: StripItem?, chipID: String?) {
        if convertedRepresentative != item { convertedRepresentative = item }
        if convertedChipID != chipID {
            convertedChipID = chipID
            HoverTrace.carrierRepresentative(rep: item?.id, hidden: chipID)
        }
    }
    /// Called back on a successful release and landing (converted state); the composition layer then calls
    /// `stripOrderStore.commitExternalBlock()`. Only `endDrag` receives the mouseUp, so the commit must be
    /// triggered by it, not inferred by DockStripView from the payload becoming nil.
    var onDrawerToStripCommitted: ((String) -> Void)?
    /// Called back on an abnormal cancel (cancelDrag) of a drawer-to-taskbar drag; the composition layer then
    /// calls `stripOrderStore.cancelExternalBlock()`. Symmetric with onDrawerToStripCommitted: commit = land
    /// and clear the staging; cancel = revert and clear the staging + boundIDs.
    var onDrawerToStripCancelled: (() -> Void)?
    /// Called back when a drawer icon is released into the taskbar (fires on both the precise landing path
    /// and the degraded path). PanelCoordinator uses it to close the drawer; independent of
    /// onDrawerToStripCommitted, neither replaces the other.
    var onDrawerToStripCompleted: ((String) -> Void)?
    /// Live drop classification for a folder chip drag. **Computed and written by DockStripView** (only it
    /// has folderChipFrames / shelfFrame / stripRootScreenRect); the carrier view (DragCarrierView) only
    /// reads it to decide whether to fade. The final mouseUp is still triggered by `endDrag()`, which
    /// classifies once more with `folderDropGeometry`.
    @Published private(set) var folderDragZone: FolderChipDropZone?
    func setFolderDragZone(_ zone: FolderChipDropZone?) {
        guard folderDragZone != zone else { return }
        folderDragZone = zone
        applyCarrierVisualState(animated: true)   // Dragged outside the bar -> fade + enlarge slightly
    }
    private var folderDropGeometry: FolderChipDropGeometry?
    func setFolderDropGeometry(_ geometry: FolderChipDropGeometry?) {
        if folderDropGeometry != geometry { folderDropGeometry = geometry }
    }
    /// A pinned folder drag was released and landed. PanelCoordinator performs the store / Finder side
    /// effects; the controller only handles reliable cleanup.
    var onFolderDragEnded: ((String, FolderChipDropZone) -> Void)?

    /// The **original source** of this drag. A conversion flips `draggingPayload.source` (it becomes
    /// `.drawer` after entering the drawer body), so "did this drag bring it in from outside the drawer" can
    /// only be answered from this. The single authority is the rollback snapshot in `conversion`; **no
    /// parallel field is added** (see the `CrossPanelConversion` comment: no more stacked boolean flags).
    private var originSource: DragSource? {
        guard let payload = draggingPayload else { return nil }
        switch conversion {
        case let .stripToDrawer(original),
             let .messagingToDrawer(original),
             let .drawerToMessaging(original):
            return original.source
        case .drawerToStrip:
            return .drawer
        case nil:
            return payload.source
        }
    }

    private let drawerStore: DrawerStore
    private let messagingStore: MessagingAppStore
    /// The only write entry point for kept: setting kept after a stash lands goes through it, and
    /// `DragController` does not hold `KeptAppStore` itself.
    private let membershipController: AppMembershipController
    /// Candidate drop zones by source (screen coordinates, already inset + tolerance): strip/messaging ->
    /// capsule (+ drawer); drawer -> the taskbar dock panel.
    private let dropZonesProvider: (DragSource) -> [CGRect]
    /// **All** screens. One carrier panel set per display (see `CarrierSurface`), switched by the display the
    /// pointer is on.
    private let screensProvider: () -> [NSScreen]
    /// Visible frame of the capsule (screen coordinates): when a taskbar card / messaging chip is released on
    /// the capsule to stash, the icon is pulled in here. `nil` = no flight.
    private let stashTargetProvider: () -> CGRect?

    /// One set per display (panel + container view + bitmap layer). **Why not one panel that follows the
    /// pointer**: after a window is `setFrame`d onto another display, WindowServer needs a frame or two to
    /// rebuild it there, and during those frames the freshly lit carrier is invisible (measured 2026-08-19:
    /// the panel last rested on another display and this drag start showed a 2-frame gap). With one set kept
    /// up per display and switching by the display the pointer is on, there is no migration at all.
    private struct CarrierSurface {
        let panel: NSPanel
        let container: CarrierContainerView
        let layer: CALayer
        let frame: CGRect
    }
    private var surfaces: [CarrierSurface] = []
    /// Delegate of the carrier layer, with one job: turning implicit actions off during the single assignment
    /// in `hideCarrierInSlotRevealCommit`. Not `layer.actions = […NSNull]` (it would also kill the return
    /// flight's implicit animations, see `makeCarrierPanel`), and not `instantly` (an explicit transaction
    /// with no enclosing implicit transaction is **sent at once**, exactly what has to be avoided here).
    private final class CarrierLayerActionGate: NSObject, CALayerDelegate {
        var suppressesImplicitActions = false
        func action(for layer: CALayer, forKey event: String) -> CAAction? {
            suppressesImplicitActions ? NSNull() : nil   // nil = hand back to the default lookup; normally no intervention at all
        }
    }
    private let carrierActionGate = CarrierLayerActionGate()
    private var activeSurface: CarrierSurface?
    /// After the carrier panel is built and ordered front, it is handed to the orchestration layer to be
    /// pinned into **the private Space the taskbar is in** (`OverlaySpaceHost`). Once the taskbar is pinned
    /// into a private Space, windows left in the desktop Space are composited below it whatever their
    /// `level`: the carrier looked translucent as soon as it went under the glass backplate and darkened near
    /// the capsule (2026-09-03, confirmed by A/B with `DOCK_OVERLAY_SPACE=0`). On assignment the sets already
    /// built are pinned as well (`prewarmCarrier` may run before the wiring).
    var pinCarrierWindows: (([Int]) -> Void)? {
        didSet { pinCarrierWindows?(surfaces.map { $0.panel.windowNumber }) }
    }
    private var carrierPanel: NSPanel? { activeSurface?.panel }
    private var carrierContainer: CarrierContainerView? { activeSurface?.container }
    /// The layer holding the carrier bitmap. **Position / scale / shadow / opacity are all its CA
    /// properties**, decided synchronously by this controller in the same run loop turn that receives the
    /// mouse event. SwiftUI is not involved, so there is no handover race.
    private var carrierLayer: CALayer? { activeSurface?.layer }
    /// The current bitmap. If the card's look changed before landing it must be recaptured (see
    /// `setCarrierSnapshot`).
    private var carrierSnapshot: CarrierSnapshot?
    /// The one captured at drag start. Converting a drawer icon into the taskbar temporarily swaps in the
    /// representative card's image; rollback swaps this back.
    private var originSnapshot: CarrierSnapshot?
    /// +1 each time the carrier goes on screen. The "remove one turn later" async checks it; otherwise, if a
    /// new drag has already started in the next turn, it would wipe the new carrier's bitmap too.
    private var carrierGeneration = 0

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var pollTimer: Timer?

    init(drawerStore: DrawerStore,
         messagingStore: MessagingAppStore,
         membershipController: AppMembershipController,
         dropZonesProvider: @escaping (DragSource) -> [CGRect],
         screensProvider: @escaping () -> [NSScreen],
         stashTargetProvider: @escaping () -> CGRect? = { nil }) {
        self.pointerMoves = pointerSubject.eraseToAnyPublisher()
        self.carrierClicks = carrierClickSubject.eraseToAnyPublisher()
        self.drawerStore = drawerStore
        self.messagingStore = messagingStore
        self.membershipController = membershipController
        self.dropZonesProvider = dropZonesProvider
        self.screensProvider = screensProvider
        self.stashTargetProvider = stashTargetProvider
    }

    // MARK: - Drag start

    /// The carrier prepared at mouse down: bitmap already attached to the layer, texture already uploaded
    /// (see `prepareCandidate`).
    private struct Candidate {
        let payloadID: String
        let snapshot: CarrierSnapshot
        let sourceScreenRect: CGRect
        let preparedAt: CFTimeInterval
    }
    /// How long a candidate counts as fresh: when SwiftUI cancels the gesture, `clearCandidate` is never
    /// received and the candidate stays until the next press; a new press on the same card reuses it if still
    /// fresh (saves a snapshot), otherwise it is recaptured, since the card's look may have changed.
    private static let candidateFreshness: CFTimeInterval = 2
    private var candidate: Candidate?
    /// The "hide the card + lift after two display frames" step used when there is no candidate.
    private var armTask: DispatchWorkItem?

    /// **Prepare on press**: at mouse-down the card's bitmap is attached to the carrier layer and put on
    /// screen once at an opacity invisible to the eye, paying for the texture upload up front. When the drag
    /// really starts (≥ 8pt), `beginDrag` only has to light it up and position it, in **the same turn and the
    /// same commit** as `draggingPayload = payload` (hiding the card), so both land in the same frame and the
    /// lift can happen in the drag-start turn, with no more "sit there and wait a turn".
    ///
    /// Opacity is 0.01 rather than 0: a fully transparent layer is culled from the render tree and its
    /// texture is never uploaded, so the warm-up would be wasted; 0.01 is invisible to the eye (under 3/255
    /// of brightness on the dark backplate) but really goes through the upload. One click costs ~0.6ms for
    /// the snapshot + one order front of a transparent panel, which is acceptable. Released without dragging
    /// -> `clearCandidate`. A candidate is claimed by `payloadID`; on a mismatch it falls back to the
    /// no-candidate path.
    func prepareCandidate(payloadID: String, sourceScreenRect: CGRect,
                          snapshot: @autoclosure () -> CarrierSnapshot?) {
        guard draggingPayload == nil, landing == nil,
              sourceScreenRect.width > 0, sourceScreenRect.height > 0 else { return }
        // Idempotent: a `minimumDistance: 0` gesture keeps firing `onChanged` while held, and one press
        // prepares only once.
        if let current = candidate, current.payloadID == payloadID,
           CACurrentMediaTime() - current.preparedAt < Self.candidateFreshness {
            return
        }
        guard let snapshot = snapshot() else { return }
        candidate = Candidate(payloadID: payloadID, snapshot: snapshot,
                              sourceScreenRect: sourceScreenRect, preparedAt: CACurrentMediaTime())
        let frame = ensureCarrierPanel(for: CGPoint(x: sourceScreenRect.midX, y: sourceScreenRect.midY))
        guard let layer = carrierLayer, let panel = carrierPanel else { return }
        carrierGeneration &+= 1
        Self.instantly {
            layer.removeAllAnimations()
            self.apply(snapshot, to: layer)
            layer.position = self.alignedCenter(
                DragCarrierGeometry.panelCenter(ofScreenRect: sourceScreenRect, panelFrame: frame), on: layer)
            layer.transform = CATransform3DIdentity
            layer.opacity = DragLandingPlan.candidateOpacity
        }
        orderCarrierFrontIfNeeded(panel)
        HoverTrace.dragHandoff("candidatePrepared", msSinceBegin: 0)
    }

    /// The press did not become a drag (released / gesture cancelled) -> drop the candidate. **Untouched
    /// while a drag is in progress**: by then the candidate has been claimed by `beginDrag` and the carrier
    /// is being held.
    func clearCandidate(payloadID: String) {
        guard draggingPayload == nil, landing == nil, !carrierRetiring,
              candidate?.payloadID == payloadID else { return }
        candidate = nil
        retireCarrier()
    }

    /// - Parameters:
    ///   - sourceScreenRect: **the cell this card occupies on screen right now** (screen coordinates). The
    ///     carrier first appears here at the slot's original size and is then lifted to the pointer. **Cannot
    ///     be derived from `grabOffset`**: `grabOffset` is measured relative to the gesture start
    ///     `value.startLocation`, while `startScreenLocation` is the position when `minimumDistance: 8`
    ///     fires, so the two differ by 8pt or more by nature. That 8pt was the jump in the reported "first
    ///     frame stutters".
    ///   - pose: the slot's shape **right now** (combined scale and upward offset of hover × press). Only
    ///     when the carrier's first frame follows it does it coincide with the slot pixel for pixel, see
    ///     `DragCarrierGeometry.pickUpPose`.
    ///   - snapshot: bitmap of the same view as the slot (taken by the view that renders the slot, see
    ///     `ChipSnapshotter`). **It is an autoclosure**: if a candidate was prepared at mouse down
    ///     (`prepareCandidate`), no second one is taken here. If neither side can produce one, the drag does
    ///     not start: without a bitmap there is nothing to hold, and forcing a drag would only make the icon
    ///     vanish.
    /// - Parameter stripSurfaceID: surface identity of the strip where the drag starts
    ///   (`activeStripSurfaceID`); pass nil for a drag starting in the drawer.
    func beginDrag(payload: DragPayload,
                   stripSurfaceID: String? = nil,
                   startScreenLocation: CGPoint,
                   grabOffset: CGSize,
                   sourceScreenRect: CGRect,
                   pose: DragCarrierGeometry.PickUpPose,
                   snapshot: @autoclosure () -> CarrierSnapshot?) {
        guard draggingPayload == nil else { return }
        // The same card is still on its return flight -> continue the drag from the icon's current position,
        // without the "retire at once + lift again from the slot" jump (see `regrabLanding`). On the taskbar
        // this path is normally unreachable: an empty slot has opacity 0 and SwiftUI gives it no hit
        // (measured with synthetic input). It stays as a guardrail: if some panel / OS version does deliver
        // it, the result must still be a continued drag, not a jump.
        if let current = landing, current.payload.id == payload.id,
           regrabLanding(at: startScreenLocation, requireHit: false) {
            return
        }
        let prepared = candidate.flatMap { $0.payloadID == payload.id ? $0 : nil }
        candidate = nil
        guard let image = prepared?.snapshot ?? snapshot() else {
            HoverTrace.dragHandoff("noSnapshot", msSinceBegin: 0)
            retireCarrier()
            return
        }
        // If the previous return is still flying, retire it at once (**no deferred handover**: that is for a
        // normal landing).
        abortLanding()
        endHoverHold()
        activeStripSurfaceID = stripSurfaceID   // After abortLanding: aborting the previous flight clears the claim
        originStripSurfaceID = stripSurfaceID
        activeStripDisplayUUID = nil
        let started = CACurrentMediaTime()
        dragBeganAt = started
        let hadCarrier = carrierPanel != nil
        carrierArmed = false
        carrierLifted = false
        liftTimer?.invalidate(); liftTimer = nil
        armTask?.cancel(); armTask = nil
        self.grabOffset = grabOffset
        globalLocation = startScreenLocation
        pointerSubject.send(startScreenLocation)
        // **Place the carrier at the slot's position first, then publish the payload**: the bitmap now sits
        // on the card in the slot's current pose, so hiding the card a frame later is invisible and no gap
        // can appear.
        let beforeCarrier = CACurrentMediaTime()
        // The slot frame measured at drag start wins (the bar may have reordered between press and drag
        // start); the prepared one is used only if it cannot be measured.
        let slotRect = sourceScreenRect.width > 0 && sourceScreenRect.height > 0
            ? sourceScreenRect : (prepared?.sourceScreenRect ?? sourceScreenRect)
        presentCarrier(snapshot: image, at: slotRect, pose: pose)
        let afterCarrier = CACurrentMediaTime()
        draggingPayload = payload
        refreshDropZone()
        installMonitors()
        startPoll()
        if prepared != nil {
            // The texture has long been on the GPU: lighting up and hiding the card share one commit, and the
            // lift happens this turn.
            armCarrier()
        } else {
            // Not warmed up: sit on the card for two display frames first (see `carrierArmed` for why), then
            // hide the card + lift.
            let task = DispatchWorkItem { [weak self] in
                guard let self, self.draggingPayload != nil, !self.carrierArmed else { return }
                self.armCarrier()
            }
            armTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + DragLandingPlan.pickUpSettle, execute: task)
        }
        HoverTrace.dragStart(totalMs: (CACurrentMediaTime() - started) * 1000,
                             carrierMs: (afterCarrier - beforeCarrier) * 1000,
                             carrierCreated: !hadCarrier,
                             prepared: prepared != nil)
    }

    /// Hide the card (this turn) + lift (`DragLandingPlan.liftDelay` later). Idempotent.
    ///
    /// **Why the lift waits a little longer**: carrier changes use explicit transactions and `commit` reaches
    /// WindowServer on the spot, while "hiding" the card on the bar is a SwiftUI update that is committed
    /// only in AppKit's display cycle for this turn. When the main thread is busy (high-frequency mouse
    /// events, reordering) the two can be a display frame or two apart. If the carrier has already left the
    /// slot toward the pointer in that time, the screen shows two icons, "card still there, copy already some
    /// way out" (measured on a recording of a 1000Hz synthetic drag: lifting in the same turn first showed 2
    /// frames of a vertically offset double image, and only then was the card hidden). With the carrier
    /// resting on the slot in the slot's current pose for two frames first, the hide commit is certain to
    /// arrive first; during those two overlapping frames both are pixel-identical and nothing shows.
    private func armCarrier() {
        guard draggingPayload != nil, !carrierArmed else { return }
        armTask?.cancel(); armTask = nil
        carrierArmed = true
        HoverTrace.dragHandoff("slotHidden", msSinceBegin: (CACurrentMediaTime() - dragBeganAt) * 1000)
        liftTimer?.invalidate()
        let timer = Timer(timeInterval: DragLandingPlan.liftDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.draggingPayload != nil, self.carrierArmed, !self.carrierLifted else { return }
                self.liftCarrier()
            }
        }
        RunLoop.main.add(timer, forMode: .common)   // Timers during a drag must be .common (project rule)
        liftTimer = timer
    }
    private var liftTimer: Timer?
    /// The lift has started (the carrier follows the pointer from this moment).
    private(set) var carrierLifted = false

    // MARK: - Taskbar card enters the drawer body -> becomes an in-drawer drag (unified feel, 2026-06-22)

    /// A taskbar card dragged into the **open drawer body** -> instantly "converted" into a drawer member,
    /// with its source changed to `.drawer`. From then on it follows the in-drawer reorder path entirely
    /// (driven by the global mouse, no placeholder gap, no repeated panel resizing), bypassing the old
    /// "placeholder + panel resizing" mechanism completely. **Reversible**: the conversion is only a
    /// temporary insertion (pushing others aside = preview); dragging the card out of the drawer body ->
    /// `revertStripFromDrawer` undoes it; it only counts as landed when actually released inside the drawer
    /// (2026-06-22: reopening the drawer must show its original state, not the pushed-aside one). `guard
    /// source==.strip && conversion==nil` keeps it idempotent (not triggered again after one conversion).
    func convertStripToDrawer() {
        guard let p = draggingPayload, p.source == .strip, p.canExternalDrop, conversion == nil else { return }
        conversion = .stripToDrawer(original: p)  // Set first and flip the payload before touching the store (the membership-disappearance observer exempts by source)
        draggingPayload = DragPayload(source: .drawer, id: p.bundleID, bundleID: p.bundleID,
                                      item: p.item, visualKind: p.visualKind, canExternalDrop: true)
        setStripSlotCollapsed(true)               // Entered the drawer body = left the bar (after a revert, the bar's decision frame decides when to restore)
        drawerStore.add(p.bundleID)
        refreshDropZone()   // The drop zone set depends on the source, recompute
    }

    /// Reverts the conversion: card dragged out of the drawer body -> removed from the drawer members (the
    /// drawer shrinks back, other icons return), source restored to a taskbar card. Dragging into the drawer
    /// body again triggers `convertStripToDrawer` anew. This is what makes "reopening the drawer = original
    /// state" hold. Clear the conversion state and restore the payload first, **then** touch the store: the
    /// membership observer exempts by the new payload source, so there is no cancel race (review P1-2).
    func revertStripFromDrawer() {
        guard case let .stripToDrawer(original) = conversion, draggingPayload?.source == .drawer else { return }
        conversion = nil    // Unfreeze + trigger relayout (dragged out of the drawer and restored -> the taskbar returns to its original width)
        draggingPayload = original
        drawerStore.remove(original.bundleID)
        refreshDropZone()
    }

    // MARK: - Messaging chip enters the drawer body -> stash preview / restore on drag-out (as taskbar cards)

    /// A messaging zone chip dragged into the **open drawer body** -> temporarily stashed as a drawer member,
    /// source flipped to `.drawer` (in-drawer reordering is then reused in full). **The messaging flag is
    /// untouched**: being in the drawer only hides it in the projection, consistent with the existing stash
    /// semantics. Set the conversion state and flip the payload first, then `drawer.add`: the messaging zone
    /// observer exempts by source and does not misread it as "chip disappeared from the zone" (review
    /// P1-2/P2-5).
    func convertMessagingToDrawer() {
        guard let p = draggingPayload, p.source == .messaging, p.canExternalDrop, conversion == nil else { return }
        conversion = .messagingToDrawer(original: p)
        draggingPayload = DragPayload(source: .drawer, id: p.bundleID, bundleID: p.bundleID,
                                      item: nil, visualKind: .drawerIcon, canExternalDrop: true)
        setStripSlotCollapsed(true)               // Same as convertStripToDrawer
        drawerStore.add(p.bundleID)
        refreshDropZone()
    }

    /// Reverts the stash preview: dragged out of the drawer body -> removed from the drawer members, payload
    /// restored to `.messaging` (the chip returns to its place in the messaging zone).
    func revertMessagingFromDrawer() {
        guard case let .messagingToDrawer(original) = conversion, draggingPayload?.source == .drawer else { return }
        conversion = nil
        draggingPayload = original
        drawerStore.remove(original.bundleID)
        refreshDropZone()
    }

    // MARK: - Drawer icon enters the taskbar -> window card / restore on drag-out (precise landing, 2026-06-22)

    /// A drawer icon dragged into the **taskbar panel area** -> instantly "converted":
    /// `drawerStore.remove(bid)`, and the app's window cards enter the live zone right away. Landing order
    /// (staging + placement inside sync) belongs to DockStripView; this method only handles the membership
    /// change + records the bundleID. **source is not flipped**: keeping `.drawer` lets the `.drawer` branch
    /// of `endDrag` and the landing anchor's owner attribution continue to hold. `guard` keeps it idempotent.
    func convertDrawerToStrip() {
        guard let p = draggingPayload, p.source == .drawer, p.canExternalDrop, conversion == nil else { return }
        conversion = .drawerToStrip(bundleID: p.bundleID)  // Set first (width freeze), then touch drawerStore
        drawerStore.remove(p.bundleID)
        applyCarrierVisualState(animated: true)   // After conversion it no longer shrinks to 0.82 and keeps the normal held size
    }

    /// Reverts the conversion: dragged out of the taskbar area -> `drawerStore.add(bid)` restores placement;
    /// kept never changes. The order-layer revert (remove boundIDs + clear absentSince) is done by
    /// DockStripView with `cancelExternalBlock` **before** calling this method.
    func revertDrawerToStrip() {
        guard case let .drawerToStrip(bid) = conversion else { return }
        drawerStore.add(bid)
        conversion = nil
        convertedRepresentative = nil   // The carrier goes back to the small drawer icon
        convertedChipID = nil           // No card on the bar needs to make room any more
        activeStripSurfaceID = nil      // Release the claim: after dragging back to the drawer area, any strip may convert next
        applyCarrierVisualState(animated: true)
    }

    // MARK: - Drawer messaging app enters the messaging zone -> temporary release / restore (review P1-3)

    /// A **running messaging app** dragged from the drawer enters the messaging zone range -> temporary
    /// release: the payload flips to `.messaging` (in-zone reordering and the stash preview on re-entering
    /// the drawer all reuse the generic logic), then `drawer.remove` (the projection puts the chip back at
    /// its original position in the messaging zone at once). The trigger range is decided by DockStripView
    /// from the messaging zone frame; it is **not** "released on leaving the drawer body".
    func convertDrawerToMessaging() {
        guard let p = draggingPayload, p.source == .drawer, p.canExternalDrop, conversion == nil else { return }
        conversion = .drawerToMessaging(original: p)
        draggingPayload = DragPayload(source: .messaging, id: p.bundleID, bundleID: p.bundleID,
                                      item: nil, visualKind: .messagingIcon, canExternalDrop: true)
        drawerStore.remove(p.bundleID)
        refreshDropZone()
    }

    /// Reverts the release: leaving the messaging zone range (or entering a drop zone) -> taken back into the
    /// drawer, payload restored to `.drawer`.
    func revertDrawerToMessaging() {
        guard case let .drawerToMessaging(original) = conversion, draggingPayload?.source == .messaging else { return }
        conversion = nil
        draggingPayload = original
        drawerStore.add(original.bundleID)
        activeStripSurfaceID = nil      // Release the claim (same as revertDrawerToStrip): entering any bar's messaging zone can release again
        refreshDropZone()
    }

    // MARK: - Pointer following / landing

    private func update(_ loc: CGPoint) {
        globalLocation = loc
        // **Position synchronously, as the very first thing**: this is all there is to following the pointer.
        // The old SwiftUI route went through the render pipeline every frame, and in fast drags the copy fell
        // more than a hundred pt behind the pointer (shown by burst captures on 2026-08-18).
        followScreenIfNeeded(loc)
        moveCarrier()
        if regrabPressed, let origin = regrabOrigin,
           hypot(loc.x - origin.x, loc.y - origin.y) > DragLandingPlan.regrabClickSlop {
            regrabPressed = false                    // Moved past the threshold = drag: back to the held look (equals a lift)
            applyCarrierVisualState(animated: true)
        }
        refreshDropZone()
        pointerSubject.send(loc)    // Side-effect subscribers (bar / drawer); creates no view dependency
        auditCarrierVisibility()
    }

    /// Self-check on every pointer update: **the cell on the bar is empty, is the copy really on screen?**
    /// Whenever the two do not hold together, the user sees "the icon is gone". "Occasionally disappears" was
    /// reported three rounds in a row and screenshots only allow guessing; this turns it into a countable
    /// fact in the log.
    ///
    /// The reverse case (copy on screen while the cell on the bar is still occupied = ghost) **no longer
    /// needs checking**: drag start has no gate any more, the timing of the two is guaranteed by the same run
    /// loop turn, and there is no "who goes first" degree of freedom.
    private func auditCarrierVisibility() {
        guard HoverTrace.isEnabled, carriedPayload != nil,
              let panel = carrierPanel, let layer = carrierLayer else { return }
        let onScreen = panel.isVisible && panel.alphaValue > 0.99
        let drawn = layer.contents != nil && layer.opacity > 0.01
        // The bitmap center must really fall inside the panel (= the union of all screens), with 24pt of
        // extra tolerance.
        let inFrame = CGRect(origin: .zero, size: carrierScreenFrame.size)
            .insetBy(dx: -24, dy: -24).contains(layer.position)
        guard !onScreen || !drawn || !inFrame else { return }
        let reason = !panel.isVisible ? "panelHidden"
            : (panel.alphaValue <= 0.99 ? "panelFaded"
               : (!drawn ? "emptyContent" : "iconOffscreen"))
        HoverTrace.carrierGap(reason: reason, alpha: panel.alphaValue,
                              hostX: layer.position.x, hostY: layer.position.y)
    }

    /// **Write only when the result really changed**: `@Published` notifies on every assignment without
    /// comparing the old value. Writing on every mouse move would invalidate the whole taskbar on every mouse
    /// move (same as `globalLocation`).
    private func refreshDropZone() {
        let next: Bool = {
            guard let p = draggingPayload, p.canExternalDrop else { return false }
            return dropZonesProvider(p.source).contains { $0.contains(globalLocation) }
        }()
        guard isOverDropZone != next else { return }
        isOverDropZone = next
        applyCarrierVisualState(animated: true)   // Entering/leaving a drop zone -> 0.82 ↔ normal
    }

    // MARK: - Cleanup (idempotent, clear first, then commit)

    /// Normal release: in a drop zone -> stash / move back by source; otherwise nothing (in-zone ordering was
    /// already committed live during the drag). The cleanup decision for `.messaging`/`.drawer` goes through
    /// the pure logic `DragConversionPlan.endAction` (covered by unit tests).
    func endDrag() {
        guard let p = draggingPayload else { return }
        // Regrabbed mid-flight and released without moving = **the card was clicked**: the icon keeps flying
        // back to the slot as usual (nothing is stashed or landed), and "was clicked" is then handed to the
        // panel that owns it to activate / minimize (2026-08-19: clicking it before landing did nothing).
        if let origin = regrabOrigin,
           hypot(globalLocation.x - origin.x, globalLocation.y - origin.y) < DragLandingPlan.regrabClickSlop {
            let folderZone = folderDropGeometry?.classify(screenPoint: globalLocation) ?? .folderZone
            teardown(landing: plannedLanding(for: p, folderZone: folderZone, allowStash: false))
            HoverTrace.dragHandoff("click", msSinceBegin: 0)
            carrierClickSubject.send(p)
            return
        }
        let external = isOverDropZone
        let converted = isConvertedToStrip
        let convertedBid = convertedDrawerBundleID
        let origin = originSource ?? p.source   // Must be read before teardown() clears conversion
        let finalLocation = globalLocation
        let folderZone = folderDropGeometry?.classify(screenPoint: finalLocation) ?? .folderZone
        let action = DragConversionPlan.endAction(source: p.source,
                                                  isConvertedToStrip: converted,
                                                  isOverDropZone: external,
                                                  isMessagingMember: messagingStore.contains(p.bundleID))
        // Cross-display drop (multi-display ③④): at release the claim is on **another** strip (which took
        // over back when the pointer hovered over it: the empty slot, reordering and landing anchor are all
        // its own) -> the flight heads for the slot it reports as usual, and the window moves to that
        // display.
        let crossStripDisplayUUID = crossStripDropDisplayUUID(for: p, external: external)
        if crossStripDisplayUUID != nil {
            HoverTrace.dragHandoff("crossStrip", msSinceBegin: (CACurrentMediaTime() - dragBeganAt) * 1000)
        }
        // The card is still outside the bar (gap closed up) and is not being stashed -> reopen the slot first
        // (in the same synchronous block, the bar lengthens at once); the flight first heads for the last
        // known slot (`plannedLanding`), and as soon as the slot frame is reported, correction takes it to
        // the real position. A folder chip released outside the bar = unpin, no reopening.
        if stripSlotCollapsed, p.source != .folder, !willStash(p) { setStripSlotCollapsed(false) }
        teardown(landing: plannedLanding(for: p, folderZone: folderZone))
        if let crossStripDisplayUUID {
            onCrossStripDrop?(p, crossStripDisplayUUID)
        }
        switch p.source {
        case .folder:
            onFolderDragEnded?(p.id, folderZone)
        case .strip:
            // A card that entered the drawer body was already converted to .drawer by convertStripToDrawer
            // (landing inside = already a member, not handled here). Reaching this branch = a card that never
            // entered the drawer body: released in the drop zone (capsule) -> change the drawer placement.
            // kept is not touched here; all four entry paths share the single criterion after the switch.
            if external {
                drawerStore.add(p.bundleID)
            }
        case .messaging:
            // Drag started in the messaging zone and was not converted (after conversion the source is
            // already .drawer), or started in the drawer and was already released back to the messaging zone
            // (drawer.remove has happened, so release lands it). Drop zone (capsule) -> stash; anywhere else
            // -> stays where it is (in-zone reordering was committed live).
            if action == .stashMessagingChip {
                drawerStore.add(p.bundleID)
            }
        case .drawer:
            switch action {
            case .commitDrawerToStrip:
                // Already converted into the taskbar (member removed, window card placed) -> treated as
                // landed; membership is no longer changed based on external. A revert already happened live
                // on leaving the zone; this only notifies the order layer to commit (clear the staging
                // tracking).
                let bid = convertedBid ?? p.bundleID
                onDrawerToStripCommitted?(bid)
                onDrawerToStripCompleted?(bid)
            case .fallbackUnstash:
                // Not converted (not running / app-fallback): dropped on the taskbar -> move back. Messaging
                // members never take this branch: their only way back to the taskbar is the temporary release
                // within the messaging zone range (review P1-3); released anywhere else they stay in the
                // drawer.
                drawerStore.remove(p.bundleID)
                onDrawerToStripCompleted?(p.bundleID)
            case .none, .stashMessagingChip:
                break
            }
        }

        // Stash landed -> turn on "Keep in Dock" (2026-08-06). Placed **after** the switch: by now
        // drawerStore has its final membership, the four entry paths (taskbar / messaging chip × drawer body
        // / capsule) share one criterion, and in-drawer reordering, conversion into the taskbar and degraded
        // move-out, which must not enable it, are excluded by construction. For the semantics (one-way,
        // re-enabled on every drag-in) see DragConversionPlan.enablesKeptOnDrop; it is applied in
        // AppMembershipController.applyDragLanding (the single mutation boundary for kept).
        membershipController.applyDragLanding(bundleID: p.bundleID, originSource: origin)
    }

    /// Cancel: abnormal paths such as the target disappearing or a display switch during the drag. First roll
    /// back the store changes already made according to the current conversion state (same path as each
    /// "restore on drag-out"), then clean up. Every temporary state restores the original membership.
    func cancelDrag() {
        // During the return flight `draggingPayload` is already nil but the carrier panel is still up.
        // Display switches / panel teardown all come through here, and without retiring it first a
        // translucent full-screen carrier would be left on screen.
        abortLanding()
        guard draggingPayload != nil else { return }
        switch conversion {
        case .stripToDrawer:
            revertStripFromDrawer()
        case .drawerToStrip:
            onDrawerToStripCancelled?()
            revertDrawerToStrip()
        case .messagingToDrawer:
            revertMessagingFromDrawer()
        case .drawerToMessaging:
            revertDrawerToMessaging()
        case nil:
            break
        }
        // An abnormal cancel (target disappeared / display switch) does not fly: that is not "landing in a
        // cell", and flying back to a position that no longer exists would only look odder.
        teardown(landing: nil)
    }

    /// Whether this release should fly, and where to. No landing anchor (or switched off by
    /// `DOCK_DRAG_LANDING=0`) -> nil -> instant cleanup.
    private func plannedLanding(for payload: DragPayload, folderZone: FolderChipDropZone,
                                allowStash: Bool = true) -> Landing? {
        guard DragLandingSwitches.enabled else { return nil }
        // Folder chip dragged out of the taskbar (release = unpin / open) -> that cell is about to be gone,
        // and flying back to a disappearing position would only look odder. The carrier keeps its faded look
        // and is retired directly.
        guard payload.source != .folder || folderZone == .folderZone else { return nil }
        // Released on the capsule to stash -> pulled into the capsule (`DragLandingPlan.stashFlight`). The
        // criterion matches the two branches in `endDrag` that really call `drawerStore.add`. **Must not fly
        // back to the slot**: the cell is gone as soon as the stash is committed (2026-08-19 screenshot: the
        // icon drifts toward the taskbar for a while and then vanishes). Without a capsule frame, clean up
        // instantly.
        if allowStash, willStash(payload) {
            let from = DragCarrierGeometry.topLeftCarriedCenter(pointer: globalLocation,
                                                                grabOffset: grabOffset,
                                                                panelFrame: carrierScreenFrame)
            guard let flight = DragLandingPlan.stashFlight(from: from, fromScale: carriedScale,
                                                           targetScreenRect: stashTargetProvider(),
                                                           carrierScreenFrame: carrierScreenFrame) else {
                HoverTrace.landing(from: from, to: nil, source: "stash:\(payload.source)")
                return nil
            }
            HoverTrace.landing(from: from, to: flight.to, source: "stash:\(payload.source)")
            landingToken &+= 1
            return Landing(token: landingToken, payload: payload, kind: .stash, flight: flight)
        }
        // The gap was just reopened and the slot frame has not been reported yet (released outside the bar
        // after closing up on drag-out): fly toward the last known slot first; during the hold period / after
        // takeoff, correction takes it to the real position. Only payloads whose drag started on the bar have
        // this memory.
        let slotAnchor = landingAnchor?.rect
            ?? ((payload.source == .strip || payload.source == .messaging) ? lastKnownSlotAnchor : nil)
        // The slot is on another display (dragged back across displays): the panel moves to the slot's
        // display first, so the flight is computed within one panel.
        if let rect = slotAnchor {
            followScreenIfNeeded(CGPoint(x: rect.midX, y: rect.midY))
            placeCarrierUnderPointer()   // The carrier's current position in the new panel's coordinates = the start
        }
        let from = DragCarrierGeometry.topLeftCarriedCenter(pointer: globalLocation,
                                                            grabOffset: grabOffset,
                                                            panelFrame: carrierScreenFrame)
        var flight = DragLandingPlan.flight(from: from,
                                            fromScale: carriedScale,
                                            anchorScreenRect: slotAnchor,
                                            carrierScreenFrame: carrierScreenFrame)
        // No anchor at all, but the empty slot was just reopened (payload whose drag started on the bar):
        // hold in place and wait for it. During the hold period, correction replaces it wholesale with the
        // real flight; if nothing has arrived when time is up, land directly (`launchLanding`). See
        // `DragLandingPlan.holdingFlight` for why.
        if flight == nil, slotAnchor == nil, payload.source == .strip || payload.source == .messaging,
           carrierScreenFrame.width > 0 {
            flight = DragLandingPlan.holdingFlight(at: from, scale: carriedScale)
        }
        HoverTrace.landing(from: from, to: flight?.to, source: "\(payload.source)")
        guard let flight else { return nil }
        landingToken &+= 1
        return Landing(token: landingToken, payload: payload, kind: .returnToSlot, flight: flight)
    }

    /// Places the carrier under the pointer on the spot (panel coordinates computed from
    /// `carrierScreenFrame`), without `moveCarrier`'s "no following before the lift" guard: in the return
    /// phase `carrierLifted` has already been cleared by `teardown`, and after a cross-display panel switch
    /// the carrier has to be repositioned to have a start point.
    private func placeCarrierUnderPointer() {
        guard let layer = carrierLayer, carrierScreenFrame.width > 0 else { return }
        let center = DragCarrierGeometry.carriedCenter(pointer: globalLocation,
                                                       grabOffset: grabOffset,
                                                       panelFrame: carrierScreenFrame)
        let aligned = alignedCenter(center, on: layer)
        Self.instantly { layer.position = aligned }
    }

    /// Cross-display drop decision: a taskbar card, not in a stash drop zone, no cross-panel conversion in
    /// progress, and the strip claiming it right now is not the one where the drag started. ①② have a single
    /// strip, so always nil. Returns the display the target strip is fixed to.
    private func crossStripDropDisplayUUID(for payload: DragPayload, external: Bool) -> String? {
        guard !external, conversion == nil, payload.source == .strip,
              let origin = originStripSurfaceID, let active = activeStripSurfaceID,
              active != origin else { return nil }
        return activeStripDisplayUUID
    }

    /// Whether this release will stash into the drawer (= the `external` branch of `.strip` / the
    /// `.stashMessagingChip` branch of `.messaging` in `endDrag`).
    private func willStash(_ payload: DragPayload) -> Bool {
        switch payload.source {
        case .strip:
            return isOverDropZone
        case .messaging:
            return DragConversionPlan.endAction(source: .messaging,
                                                isConvertedToStrip: isConvertedToStrip,
                                                isOverDropZone: isOverDropZone,
                                                isMessagingMember: messagingStore.contains(payload.bundleID))
                == .stashMessagingChip
        case .drawer, .folder:
            return false
        }
    }

    /// Cleanup. When `landing` is non-nil the carrier is **not retired**: it still has a flight to make, and
    /// `finishLanding()` retires it when time is up.
    private func teardown(landing flight: Landing?) {
        let released = draggingPayload
        conversion = nil                  // Landing path: clear the conversion state without rolling back (commit)
        convertedRepresentative = nil
        // **The converted card's empty slot must be held until landing**, on the same basis as in-bar drags
        // (where `hiddenSlotPayload` holds it for the whole flight). Cleared on the spot, the card would
        // appear fully opaque at once while the carrier is still flying = a double image. Cleared by
        // `finishLanding` / `abortLanding`.
        if flight == nil {
            convertedChipID = nil
            clearStripClaims()
            setStripSlotCollapsed(false)
            lastKnownSlotAnchor = nil
        }
        folderDragZone = nil
        folderDropGeometry = nil
        draggingPayload = nil
        carrierArmed = false
        carrierLifted = false
        regrabOrigin = nil
        regrabPressed = false
        liftTimer?.invalidate(); liftTimer = nil
        armTask?.cancel(); armTask = nil
        candidate = nil
        isOverDropZone = false
        landingAnchor = nil
        removeMonitors()
        pollTimer?.invalidate(); pollTimer = nil
        landingTimer?.invalidate(); landingTimer = nil
        landingLaunchTask?.cancel(); landingLaunchTask = nil
        landing = flight
        guard let flight else {
            // **Even without a flight it is "show first, remove after".** `draggingPayload` was just cleared,
            // and the card on the bar only appears at SwiftUI's next commit; an `orderOut` on the spot here
            // necessarily exposes one empty frame. The no-flight paths (sub-pixel landing where the travel is
            // below `minimumTravel`, no anchor, folder dragged outside the bar) would flash every time, which
            // is how the reported "clicking the icon next to an icon shows a vertical ghost" looks under
            // rapid clicks. Hover is likewise held until the pointer moves again: on this path too the
            // pointer sits on the card that just appeared.
            if let released { beginHoverHold(for: released) }
            retireCarrierAfterHandoff()
            return
        }
        landingDeadline = CACurrentMediaTime() + DragLandingPlan.maximumDuration
        guard flight.kind == .returnToSlot else {
            // Pulled into the capsule: the end point is the capsule, which does not move with the layout, so
            // there is nothing to wait for.
            landingLaunched = true
            flyCarrier(along: flight.flight, token: flight.token)
            return
        }
        // Flying back to the slot/cell: first hold for two display frames until the landing anchor settles
        // (`DragLandingPlan.landingSettle`); meanwhile `retargetLandingIfNeeded` only updates the end point
        // and does not take off, otherwise the first segment would already head for the old cell.
        landingLaunched = false
        let token = flight.token
        let task = DispatchWorkItem { [weak self] in self?.launchLanding(token: token) }
        landingLaunchTask?.cancel()
        landingLaunchTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + DragLandingPlan.landingSettle, execute: task)
        beginLandingGrabWatch()
    }

    /// End of the hold period: take off with the latest end point as of now. Idempotent (nothing happens on a
    /// token mismatch or if already airborne).
    private func launchLanding(token: Int) {
        guard !landingLaunched, let current = landing, current.token == token else { return }
        landingLaunched = true
        // Hold period over and still holding in place (the anchor never came) -> land directly, don't leave
        // the carrier hanging for a full duration.
        guard !current.flight.isStationary else { finishLanding(token: token); return }
        flyCarrier(along: current.flight, token: token)
    }

    /// Schedules (or reschedules) the "retire the carrier when the flight is over" step. `.common`: at
    /// release the main run loop may still be in event tracking mode, where a default-mode timer does not
    /// fire and the carrier would hang in mid-air forever (same reason as `armSpringOpenTimer`).
    private func scheduleLandingFinish(token: Int) {
        landingTimer?.invalidate()
        let flightDuration = landing?.flight.duration ?? DragLandingPlan.duration
        let remaining = max(0.05, min(flightDuration + DragLandingPlan.settleMargin,
                                      landingDeadline - CACurrentMediaTime()))
        let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.finishLanding(token: token)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        landingTimer = timer
    }

    /// Whether a taskbar card can be stashed: only cards without a bundleID are blocked (Finder can be
    /// stashed too since 2026-08-20). App-level fallback is not blocked: the drawer's running zone shows
    /// app-level icons anyway.
    static func canStash(_ item: StripItem) -> Bool {
        guard let bid = item.bundleIdentifier, !bid.isEmpty else { return false }
        return true
    }

    // MARK: - Carrier panel (bitmap layer)

    /// Builds the carrier panel ahead of time, so the user's **first drag** does not pay for it.
    ///
    /// With a bitmap carrier this cost is much smaller (no order front is needed any more to force layout of
    /// a SwiftUI host tree), but creating an `NSPanel` still costs something, and the first drag is exactly
    /// the one reported as "the first frame stutters".
    func prewarmCarrier() {
        guard surfaces.isEmpty else { return }
        // One set per display, ordered front right now (the layer is empty, nothing shows on screen). See
        // `retireCarrier` for why.
        for frame in screensProvider().map(\.frame) { _ = surface(for: frame) }
        activeSurface = surfaces.first
        carrierScreenFrame = activeSurface?.frame ?? .zero
    }

    /// Panel teardown (suspension on lost permissions, etc.): the panel sets that stay up must be retired
    /// explicitly; an on-screen `NSWindow` does not go away with the controller.
    func closeCarrierSurfaces() {
        abortLanding()
        for surface in surfaces { surface.panel.orderOut(nil); surface.panel.close() }
        surfaces.removeAll()
        activeSurface = nil
        carrierScreenFrame = .zero
    }

    /// The set covering the display with this `frame`; if there is none, build one and order it front.
    private func surface(for frame: CGRect) -> CarrierSurface {
        if let existing = surfaces.first(where: { $0.frame == frame }) { return existing }
        let made = makeCarrierSurface(frame: frame)
        surfaces.append(made)
        made.panel.orderFrontRegardless()
        pinCarrierWindows?([made.panel.windowNumber])
        return made
    }

    /// Makes "the current set" the one for the display containing `point`; returns that display's frame. On a
    /// display switch the old set's layer is cleared, and the caller fills the new one right after with
    /// `apply(snapshot)`.
    @discardableResult
    private func ensureCarrierPanel(for point: CGPoint) -> CGRect {
        let frames = screensProvider().map(\.frame)
        // The screen arrangement changed: retire the sets of displays that no longer exist (they were empty
        // and invisible anyway).
        for stale in surfaces where !frames.contains(stale.frame) {
            stale.panel.orderOut(nil); stale.panel.close()
            if activeSurface?.panel === stale.panel { activeSurface = nil }
        }
        surfaces.removeAll { !frames.contains($0.frame) }
        let frame = DragCarrierGeometry.screenFrame(containing: point, in: frames)
        guard frame.width > 0 else { return .zero }
        let next = surface(for: frame)
        if activeSurface?.panel !== next.panel {
            if let old = activeSurface {
                Self.instantly { old.layer.removeAllAnimations(); old.layer.contents = nil }
            }
            activeSurface = next
        }
        carrierScreenFrame = frame
        return frame
    }

    /// Pointer crossed to another display -> switch to that display's set, carry the current bitmap / scale /
    /// shadow over unchanged, then position by screen coordinates (all geometry is "screen coordinates −
    /// panel origin", so a new origin just works). Nothing happens within the same display.
    private func followScreenIfNeeded(_ point: CGPoint) {
        guard carrierScreenFrame.width > 0, !carrierScreenFrame.contains(point) else { return }
        let frames = screensProvider().map(\.frame)
        guard frames.contains(where: { $0.contains(point) }) else { return }   // Gap between displays, leave it alone for now
        ensureCarrierPanel(for: point)
        if let layer = carrierLayer, let snapshot = carrierSnapshot {
            Self.instantly { self.apply(snapshot, to: layer); layer.opacity = 1 }
            applyCarrierVisualState(animated: false)
        }
        HoverTrace.dragHandoff("screenSwitch", msSinceBegin: (CACurrentMediaTime() - dragBeganAt) * 1000)
    }

    /// Places the bitmap at the slot's position, appearing in the slot's current pose (not lifted yet). Fully
    /// synchronous, no implicit animation.
    private func presentCarrier(snapshot: CarrierSnapshot, at sourceScreenRect: CGRect,
                                pose: DragCarrierGeometry.PickUpPose) {
        let anchor = sourceScreenRect.width > 0 && sourceScreenRect.height > 0
            ? CGPoint(x: sourceScreenRect.midX, y: sourceScreenRect.midY) : globalLocation
        let frame = ensureCarrierPanel(for: anchor)
        guard let layer = carrierLayer, let panel = carrierPanel else { return }
        carrierGeneration &+= 1
        carrierSnapshot = snapshot
        originSnapshot = snapshot
        // If the frame has not been measured yet (`.zero`), fall back to "place it under the pointer", which
        // beats the bottom-left corner of the screen.
        var center = sourceScreenRect.width > 0 && sourceScreenRect.height > 0
            ? DragCarrierGeometry.panelCenter(ofScreenRect: sourceScreenRect, panelFrame: frame)
            : DragCarrierGeometry.carriedCenter(pointer: globalLocation, grabOffset: grabOffset, panelFrame: frame)
        // If the slot is currently pushed up from its bottom anchor by the quiet level's hover and also
        // shrunk by a press, its visual center is not the slot center: compensate by the pose.
        center.y += pose.dy
        Self.instantly {
            layer.removeAllAnimations()
            self.apply(snapshot, to: layer)          // Swap the image first: `alignedCenter` needs the new bounds
            layer.position = self.alignedCenter(center, on: layer)
            layer.transform = Self.scaleTransform(pose.scale)
            layer.opacity = 1
        }
        orderCarrierFrontIfNeeded(panel)
    }

    /// **Every change to the carrier layer must be wrapped in an explicit `CATransaction`, even an instant
    /// assignment.**
    ///
    /// Measured (2026-08-19, item-by-item A/B): for sublayers in this panel, a **bare assignment never
    /// reaches WindowServer**. `presentation()` reads back the new value (that is computed locally), yet
    /// nothing moves on screen: the position does not follow the pointer and the opacity stays at the 0.01
    /// from preparation, which looks like "the carrier is gone entirely"; the same code works as soon as it
    /// is wrapped in `begin/commit`. The cause was not tracked to the bottom (this panel has no AppKit
    /// display cycle to flush commits for it), but the rule is hard: **bare assignment = silently
    /// ineffective**. Instant changes go through here (which also turns implicit animations off); animated
    /// ones go through `animate`, likewise inside a transaction.
    private static func instantly(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// **Don't order it again if it is already frontmost.**
    ///
    /// Measured (2026-08-19, frame by frame on a recording of a 1000Hz synthetic drag, all else equal):
    /// calling `orderFrontRegardless()` once more at drag start on a carrier panel that is **already**
    /// ordered front delays its content by 2–3 display frames. The slot side is already hidden and the copy
    /// is not out yet, which is that 3-frame gap; without the duplicate ordering the gap drops to zero. The
    /// panel is already ordered front at press-time preparation (`prepareCandidate`), so the drag-start turn
    /// should only change the layer, not touch the window.
    private func orderCarrierFrontIfNeeded(_ panel: NSPanel) {
        guard !panel.isVisible else { return }
        panel.orderFrontRegardless()
    }

    /// Lift: slide from the slot to under the pointer while growing to the normal size.
    private func liftCarrier() {
        guard let layer = carrierLayer else { return }
        carrierLifted = true
        HoverTrace.dragHandoff("lift", msSinceBegin: (CACurrentMediaTime() - dragBeganAt) * 1000)
        let rawTarget = DragCarrierGeometry.carriedCenter(pointer: globalLocation,
                                                       grabOffset: grabOffset,
                                                       panelFrame: carrierScreenFrame)
        let target = alignedCenter(rawTarget, on: layer)
        let from = layer.position
        // The model value goes straight to the target (it is what pointer following changes every frame), and
        // an **additive** animation covers the difference in position. Otherwise every position write from
        // pointer following during the lift would fight an absolute-value animation, and the copy would fly
        // toward the old target and then teleport. Adding the animation is also inside the transaction: **any
        // bare layer change (including adding an animation) may open an implicit transaction that is never
        // committed** (see `instantly`).
        Self.instantly {
            layer.position = target
            if hypot(target.x - from.x, target.y - from.y) > 0.5 {
                let slide = CABasicAnimation(keyPath: "position")
                slide.isAdditive = true
                slide.fromValue = NSValue(point: NSPoint(x: from.x - target.x, y: from.y - target.y))
                slide.toValue = NSValue(point: .zero)
                slide.duration = DragLandingPlan.liftDuration
                slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
                slide.isRemovedOnCompletion = true
                layer.add(slide, forKey: "lift")
            }
        }
        applyCarrierVisualState(animated: true)
    }

    /// Pointer following: synchronous positioning on every mouse event. **Implicit animation must be off**:
    /// `CALayer.position` has a default 0.25s implicit animation, and with it on, every frame interpolates
    /// toward the previous frame's target and the copy trails limply behind the pointer forever.
    private func moveCarrier() {
        // **No following before the lift**: in that turn the carrier must stay on the slot, covering the card
        // (see `carrierArmed`). Without this guard, a dragged event arriving first in the drag-start turn
        // would teleport the carrier under the pointer, the start `liftCarrier` then measures would already
        // be the end point, and the slide would silently be gone.
        guard carrierLifted, let layer = carrierLayer, carrierScreenFrame.width > 0 else { return }
        let center = DragCarrierGeometry.carriedCenter(pointer: globalLocation,
                                                       grabOffset: grabOffset,
                                                       panelFrame: carrierScreenFrame)
        let aligned = alignedCenter(center, on: layer)   // Unaligned means blurry for the whole drag, see `alignedCenter`
        Self.instantly { layer.position = aligned }
    }

    /// Scale + opacity (entering/leaving a drop zone, conversion, folder dragged outside the bar) all go
    /// through this single exit, so several places don't each write their own and overwrite each other when
    /// states stack.
    private func applyCarrierVisualState(animated: Bool) {
        // Same as `moveCarrier`: before the lift the carrier keeps the "as in the slot" look (0.93),
        // otherwise a single drop zone evaluation in the drag-start turn could pull it to normal size early
        // and leave only half a lift animation.
        guard carrierLifted, let layer = carrierLayer, draggingPayload != nil else { return }
        let scale = regrabPressed ? ChipPressDecision.pressedScale : carrierVisualScale
        let opacity = carrierVisualOpacity
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(DragLandingPlan.stateChangeDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        layer.transform = Self.scaleTransform(scale)
        layer.opacity = opacity
        CATransaction.commit()
    }

    /// Runs an explicit animation on a layer property: the model value goes to the target at once, and the
    /// animation runs from the **current presentation value** to the new value. `duration == 0` is instant.
    /// The layer's implicit actions are all off (see `makeCarrierPanel`), so this is the only way to animate;
    /// conversely, a plain assignment where no animation is wanted is instant and needs no transaction
    /// wrapper.
    private static func animate(_ layer: CALayer, _ keyPath: String, to value: Any,
                                duration: TimeInterval,
                                timing: CAMediaTimingFunction = CAMediaTimingFunction(name: .easeOut)) {
        let from = (layer.presentation() ?? layer).value(forKeyPath: keyPath)
        layer.setValue(value, forKeyPath: keyPath)
        guard duration > 0 else { layer.removeAnimation(forKey: keyPath); return }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = value
        animation.duration = duration
        animation.timingFunction = timing
        animation.isRemovedOnCompletion = true
        layer.add(animation, forKey: keyPath)
    }

    /// Swaps the bitmap (drawer icon converted into a taskbar card / rollback; taskbar card stashed into the
    /// drawer body / restored on drag-out; the card's look changed before landing). **Passing `nil` = swap
    /// back to the drag-start one** (rollback path).
    ///
    /// - Parameter reanchor: `true` = the old and new bitmaps differ a lot in size (a 168pt title card ↔ a
    ///   30.8pt small drawer icon), so the grab offset scales with the size ratio and the pointer stays at
    ///   **the same relative position** on the icon. Otherwise a title card grabbed at its right end would,
    ///   once swapped for the small icon, float tens of pt away from the pointer (2026-08-19 screenshot:
    ///   after entering the drawer the icon sat on the drawer's edge). The position slides over, and bounds
    ///   and contents transition with the same 0.12s animation (the large card shrinks into the small icon
    ///   while moving up to the pointer). `false` = instant swap, offset unchanged. **Both directions now use
    ///   `true`** (the 2026-08-20 requirement "dragging from the drawer into the taskbar must match in-bar
    ///   dragging exactly" reversed the earlier sign-off on the look of the `false` version): an instant swap
    ///   means the 30.8pt drawer icon explodes around its own center into a 40–168pt card within one frame,
    ///   and the pointer's relative grip point jumps with it.
    func setCarrierSnapshot(_ snapshot: CarrierSnapshot?, reanchor: Bool = false) {
        guard let layer = carrierLayer, draggingPayload != nil,
              let next = snapshot ?? originSnapshot else { return }
        let previousSize = carrierSnapshot?.size ?? layer.bounds.size
        carrierSnapshot = next
        guard reanchor, carrierLifted, previousSize.width > 0, previousSize.height > 0 else {
            Self.instantly { self.apply(next, to: layer) }
            return
        }
        grabOffset = CGSize(width: grabOffset.width * next.size.width / previousSize.width,
                            height: grabOffset.height * next.size.height / previousSize.height)
        let from = layer.position
        let rawTarget = DragCarrierGeometry.carriedCenter(pointer: globalLocation, grabOffset: grabOffset,
                                                       panelFrame: carrierScreenFrame)
        // Implicit bounds animation + contents cross-fade: the bitmap changes look and size over the same
        // period.
        CATransaction.begin()
        CATransaction.setAnimationDuration(DragLandingPlan.stateChangeDuration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        apply(next, to: layer)
        CATransaction.commit()
        // Position: model straight to the target + additive slide (same as `liftCarrier`); pointer following
        // continues as usual and does not fight an absolute-value animation.
        let target = alignedCenter(rawTarget, on: layer)
        Self.instantly {
            layer.position = target
            if hypot(target.x - from.x, target.y - from.y) > 0.5 {
                let slide = CABasicAnimation(keyPath: "position")
                slide.isAdditive = true
                slide.fromValue = NSValue(point: NSPoint(x: from.x - target.x, y: from.y - target.y))
                slide.toValue = NSValue(point: .zero)
                slide.duration = DragLandingPlan.stateChangeDuration
                slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
                slide.isRemovedOnCompletion = true
                layer.add(slide, forKey: "reanchor")
            }
        }
    }

    private func apply(_ snapshot: CarrierSnapshot, to layer: CALayer) {
        layer.contents = snapshot.image
        layer.contentsScale = snapshot.scale
        layer.bounds = CGRect(origin: .zero, size: snapshot.size)
    }

    /// Return flight: translation and scale are **in the same transaction**, so the kind of miss where "the
    /// fade-out timer was not rescheduled along with the correction" cannot happen (which is how the previous
    /// version faded the carrier to 0 halfway).
    private func flyCarrier(along flight: DragLandingFlight, token: Int) {
        guard let layer = carrierLayer else { return }
        // Start: if still flying (reissue by a correction), the current position computed from the timeline;
        // otherwise the model value from being held.
        let now = CACurrentMediaTime()
        let start = landingPose(at: now)
            ?? LayerPose(position: layer.position, scale: Self.scale(of: layer.transform))
        landingAnimation &+= 1
        let generation = landingAnimation
        let c = flight.curve   // Each flight carries its own curve (slow when near, fast when far); like duration it must not be computed separately
        let timing = CAMediaTimingFunction(controlPoints: Float(c.c0x), Float(c.c0y), Float(c.c1x), Float(c.c1y))
        let destination = alignedCenter(
            DragCarrierGeometry.panelPoint(fromTopLeft: flight.to, panelFrame: carrierScreenFrame), on: layer)
        CATransaction.begin()
        CATransaction.setAnimationDuration(flight.duration)
        CATransaction.setAnimationTimingFunction(timing)
        // CA's completion callback also fires when the animation is **replaced** (a correction is a
        // replacement), so the generation must be checked: checking `token` alone would let a correction end
        // the flight on the spot.
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                guard let self, self.landingAnimation == generation else { return }
                self.finishLanding(token: token)
            }
        }
        // The end point is aligned to device pixels: the bitmap lands 1:1 on the grid and the landing frame
        // is as sharp as the card on the bar (`DragCarrierGeometry.pixelAligned`; reported 2026-08-19:
        // "blurry on the frame before landing, suddenly sharp on the last frame").
        layer.position = destination
        layer.transform = Self.scaleTransform(flight.toScale)
        layer.opacity = flight.toOpacity        // Back to the slot = 1 (the fade from a folder dragged outside the bar must be undone); into the capsule = 0
        CATransaction.commit()
        // Timeline: the takeoff time is the moment just before the transaction begins (`now`). commit itself
        // is a round trip to WindowServer, and a time taken after commit would run a few ms behind the screen
        // (frame captures measured a 3pt step back on regrab). Better to estimate slightly ahead: a freeze
        // point a pt or two beyond the screen looks like "moved once more and stopped", while stepping back
        // is a jump.
        flightTimeline = FlightTimeline(beganAt: now, start: start,
                                        destination: LayerPose(position: destination, scale: flight.toScale),
                                        duration: flight.duration, curve: flight.curve)
        scheduleLandingFinish(token: token)
    }

    /// A set of presentation values for the layer: position (panel coordinates) + scale. The carrier has no
    /// shadow, so there is no shadow term here.
    private struct LayerPose {
        var position: CGPoint
        var scale: CGFloat
    }

    /// Timeline of this flight. **"Where the icon is right now" is computed from it, not read from
    /// `presentation()`**: the latter is about two frames behind the screen (ten-odd pt per frame in the
    /// first part of the flight), and freezing by it jumps backwards (15pt measured from frame captures on
    /// 2026-08-19). The render server uses the same curve, the same clock and the same beginTime as here, so
    /// only our own computation matches. On a reissue by a correction the start is the estimate at that time.
    private struct FlightTimeline {
        let beganAt: CFTimeInterval
        let start: LayerPose
        let destination: LayerPose
        let duration: TimeInterval
        let curve: DragLandingCurve
        func pose(at time: CFTimeInterval) -> LayerPose {
            let p = CGFloat(curve.progress(at: (time - beganAt) / duration))
            return LayerPose(position: CGPoint(x: start.position.x + (destination.position.x - start.position.x) * p,
                                               y: start.position.y + (destination.position.y - start.position.y) * p),
                             scale: start.scale + (destination.scale - start.scale) * p)
        }
    }
    private var flightTimeline: FlightTimeline?

    /// Current presentation values of the flying icon; nil when not flying.
    private func landingPose(at time: CFTimeInterval) -> LayerPose? {
        guard let landing, let timeline = flightTimeline else { return nil }
        // An icon pulled into the capsule accepts no regrab / click: the card it stands for is no longer on
        // the bar.
        guard landing.kind == .returnToSlot else { return nil }
        return timeline.pose(at: time)
    }

    private static func scale(of transform: CATransform3D) -> CGFloat { transform.m11 }

    /// Landing accuracy self-check: where the carrier finally stopped and how far that is from the slot. >
    /// 0.5pt means a jump will be visible on landing.
    private func recordLandingDelta() {
        guard HoverTrace.isEnabled, let layer = carrierLayer, let flight = landing?.flight else { return }
        let want = DragCarrierGeometry.panelPoint(fromTopLeft: flight.to, panelFrame: carrierScreenFrame)
        let got = layer.presentation()?.position ?? layer.position
        HoverTrace.landingDelta(dx: got.x - want.x, dy: got.y - want.y)
    }

    private static func scaleTransform(_ scale: CGFloat) -> CATransform3D {
        CATransform3DMakeScale(scale, scale, 1)
    }

    /// **Wherever the carrier rests, it must sit on the device pixel grid.**
    ///
    /// A bitmap resting on half a pixel is resampled by the system and looks like "the icon is slightly
    /// blurrier than the card on the bar" (2026-08-19: "the icon has a faint blur while dragging that only
    /// goes away after landing"). Previously only the **end point** of the return flight was aligned, so the
    /// whole drag was blurry and it turned sharp on landing: two halves of the same problem.
    ///
    /// The quantization step is one device pixel (0.5pt on a 2x display), invisible to the eye, and it is
    /// exactly why native dragging is sharp. Scaled states (0.82 while over a drop zone, 1.023 for the
    /// drag-start pose) are resampled anyway, so aligning them neither hurts nor helps, but going through
    /// here in all cases keeps two algorithms from drifting apart.
    private func alignedCenter(_ center: CGPoint, on layer: CALayer) -> CGPoint {
        DragCarrierGeometry.pixelAligned(center: center,
                                         size: layer.bounds.size,
                                         scale: carrierSnapshot?.scale ?? 2)
    }

    private func makeCarrierSurface(frame: CGRect) -> CarrierSurface {
        // NonConstrainingPanel: the carrier covers **one display** (not the union, see
        // `DragCarrierGeometry.screenFrame`); being constrained to the visible area by the system would
        // misplace it, same as the dock/capsule.
        let panel = NonConstrainingPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.collectionBehavior = PanelCollectionBehavior.standard
        panel.isFloatingPanel = true
        // **The level must be set after `isFloatingPanel`, and one level above the taskbar/drawer/capsule
        // (all `.floating`).** The `.popUpMenu` that used to be set earlier was silently changed back to
        // `.floating` by `isFloatingPanel = true` (AppKit semantics: a floating panel is at the floating
        // level), so the carrier and the taskbar shared a level and whichever ordered front last was on top.
        // The taskbar orders front again in several places (show/hide cycle, display switch, initial layout).
        // Measured 2026-08-19: about 0.5s after release the taskbar jumped above the carrier, the copy flying
        // back to the slot was fully covered as soon as it entered the taskbar panel's rect (including the
        // 20pt shadow margin), and nothing was visible for 250ms before the card appeared: the reported
        // "disappears / ghosts on landing". During a drag, the pointer leaving and returning to the bar was
        // covered the same way, which is "the icon disappears when dragged fast". One level higher, it no
        // longer depends on ordering, always sits above our own panels, and still does not go above system
        // menus.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = NSColor(white: 1.0, alpha: 0.0)
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true          // Drawing only, takes no events; the one exception is in `refreshLandingGrabState`
        panel.alphaValue = 1                     // Always 1: there is no panel-level alpha animation any more
        // The panel's contentView is a plain full-screen NSView (project rule: a panel must not use a hosting
        // view as contentView), and the carrier is a sublayer in its layer. Non-flipped view -> sublayer
        // coordinates have a bottom-left origin with y up.
        let container = CarrierContainerView(frame: CGRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.0).cgColor
        container.autoresizingMask = [.width, .height]
        let layer = CALayer()
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.isOpaque = false
        layer.allowsEdgeAntialiasing = true
        layer.delegate = carrierActionGate
        // **Don't blanket-disable implicit actions here with `layer.actions = […NSNull]`**: the return flight
        // and the scaling on entering/leaving a drop zone use exactly the implicit animation of "set a
        // duration in the transaction + assign directly", and with everything off they become teleports (hit
        // once on 2026-08-19: after release the icon jumped back to the slot in one frame and the flight was
        // gone). Instant assignments are simply wrapped in `instantly`, which turns animation off.
        // **The carrier never has a shadow** (2026-08-19: icons on the bar cast no shadow, so neither does
        // the held copy). `CALayer` draws none by default, so not a single shadow property is set here. As
        // soon as someone sets half of one, the landing handover again shows the step of "the bitmap's shadow
        // is lighter than the card's" (which caused the +2.85 in the previous round).
        container.layer?.addSublayer(layer)
        // The flight is interruptible: the icon's current frame is the hit area, and a press = continue the
        // drag from the current position (see `regrabLanding`).
        container.grabRegion = { [weak self] in self?.landingIconPanelFrame() }
        container.onGrab = { [weak self] point in self?.regrabLanding(at: point) }
        panel.contentView = container
        return CarrierSurface(panel: panel, container: container, layer: layer, frame: frame)
    }

    /// Brings the carrier back to the front after a spring-opened drawer: the newly opened drawer, once
    /// ordered front, may cover a carrier created before it (reported 2026-06-21: "the floating icon
    /// disappears when dragging into a spring-opened drawer"). Acts only while a drag is in progress.
    func bringCarrierToFront() {
        guard draggingPayload != nil, let c = carrierPanel else { return }
        c.orderFrontRegardless()
    }

    // MARK: - Monitors + polling fallback

    private func installMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] ev in
            guard let self else { return ev }
            let loc = NSEvent.mouseLocation
            if ev.type == .leftMouseUp { self.update(loc); self.endDrag() }
            else { self.update(loc) }
            return ev
        }
        // global measured 0 events throughout (the implicit grab is locked to this app); kept as a cheap
        // fallback.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] ev in
            guard let self else { return }
            let loc = NSEvent.mouseLocation
            if ev.type == .leftMouseUp { self.update(loc); self.endDrag() }
            else { self.update(loc) }
        }
    }

    private func removeMonitors() {
        if let m = localMonitor  { NSEvent.removeMonitor(m); localMonitor  = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
    }

    private func startPoll() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.draggingPayload != nil else { return }
                if NSEvent.pressedMouseButtons == 0 { self.endDrag() }
            }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }
}

// The carrier views (DragCarrierView / DrawerDragIconView) are in App/Composition/DragCarrierView.swift. They
// pull in UI dependencies such as ChipView/PinnedFolderChip; splitting them out lets this controller be
// compiled locally into the test target.
