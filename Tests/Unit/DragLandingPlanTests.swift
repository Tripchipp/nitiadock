import XCTest
@testable import NitiaDock

/// Pure decisions for the return flight on release. The core pinned here is **coordinate
/// conversion**: the screen has a bottom-left origin, the carrier panel a top-left one,
/// and mixing them up sends the icon flying to the other end of the screen. In
/// visual acceptance that only ever gets described as "the animation looks odd".
final class DragLandingPlanTests: XCTestCase {
    /// Main display 1512×982, the carrier panel always covers the whole display.
    private let carrier = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testAnchorCentreConvertsToCarrierPanelCoordinates() {
        // A 40×54 card on the taskbar, bottom edge of the visible area at y=8 (screen, bottom-left origin).
        let slot = CGRect(x: 700, y: 8, width: 40, height: 54)
        let flight = DragLandingPlan.flight(from: CGPoint(x: 900, y: 400),
                                            fromScale: DragLandingPlan.carriedScale,
                                            anchorScreenRect: slot,
                                            carrierScreenFrame: carrier)
        // Center x = 720; y has to flip: 982 − 35 = 947 (panel-local, top-left origin).
        XCTAssertEqual(flight?.to.x, 720)
        XCTAssertEqual(flight?.to.y, 947)
    }

    /// When the carrier panel is not at the main display's origin (external
    /// display), the conversion subtracts the panel's own origin.
    func testCarrierOriginIsSubtracted() {
        let external = CGRect(x: -504, y: 982, width: 2560, height: 1440)
        let slot = CGRect(x: 0, y: 1000, width: 40, height: 54)
        let flight = DragLandingPlan.flight(from: .zero,
                                            fromScale: 1,
                                            anchorScreenRect: slot,
                                            carrierScreenFrame: external)
        XCTAssertEqual(flight?.to.x, 20 - (-504))
        XCTAssertEqual(flight?.to.y, (982 + 1440) - 1027)
    }

    /// Start point and start scale are passed through as is: the carrier is
    /// shrunk in a drop zone (0.82) and the flight must start at that size,
    /// otherwise it jumps bigger at the moment of release and then flies.
    func testStartStateIsCarriedThrough() {
        let flight = DragLandingPlan.flight(from: CGPoint(x: 123, y: 456),
                                            fromScale: DragLandingPlan.dropZoneScale,
                                            anchorScreenRect: CGRect(x: 0, y: 0, width: 40, height: 40),
                                            carrierScreenFrame: carrier)
        XCTAssertEqual(flight?.from, CGPoint(x: 123, y: 456))
        XCTAssertEqual(flight?.fromScale, DragLandingPlan.dropZoneScale)
    }

    /// End scale is always 1: at landing it must be pixel for pixel the size
    /// of the card on the bar, otherwise removing the carrier flickers.
    func testAlwaysLandsAtNativeScale() {
        for start in [DragLandingPlan.carriedScale, DragLandingPlan.dropZoneScale] {
            let flight = DragLandingPlan.flight(from: .zero, fromScale: start,
                                                anchorScreenRect: CGRect(x: 0, y: 0, width: 40, height: 40),
                                                carrierScreenFrame: carrier)
            XCTAssertEqual(flight?.toScale, 1.0)
        }
    }

    // MARK: - Cases with no flight (always fall back to the pre-rework instant finish, zero risk)

    /// No landing point -> no flight. Promotion into the taskbar is such a
    /// case: release unfreezes the bar width and re-centers the whole bar,
    /// so the landing point keeps drifting mid-flight; better no flight than a crooked one.
    func testNoAnchorMeansNoFlight() {
        XCTAssertNil(DragLandingPlan.flight(from: .zero, fromScale: 1,
                                            anchorScreenRect: nil, carrierScreenFrame: carrier))
    }

    /// A frame not measured yet (`.zero` / zero width or height) cannot be a
    /// landing point: the icon would fly to the bottom-left corner of the screen.
    func testUnmeasuredAnchorIsRejected() {
        XCTAssertNil(DragLandingPlan.flight(from: .zero, fromScale: 1,
                                            anchorScreenRect: .zero, carrierScreenFrame: carrier))
        XCTAssertNil(DragLandingPlan.flight(from: .zero, fromScale: 1,
                                            anchorScreenRect: CGRect(x: 10, y: 10, width: 0, height: 54),
                                            carrierScreenFrame: carrier))
    }

    /// Same when the carrier panel is not built yet (empty frame).
    func testEmptyCarrierFrameIsRejected() {
        XCTAssertNil(DragLandingPlan.flight(from: .zero, fromScale: 1,
                                            anchorScreenRect: CGRect(x: 0, y: 0, width: 40, height: 40),
                                            carrierScreenFrame: .zero))
    }

    // MARK: - Duration by distance (2026-08-18: "not as calm and graceful as the native animation")

    /// A fixed duration makes short distances look hasty and long ones
    /// rushed. The farther, the longer the flight, but both ends are clamped.
    func testDurationGrowsWithDistanceAndIsClampedAtBothEnds() {
        XCTAssertEqual(DragLandingPlan.duration(travel: 0), DragLandingPlan.minimumDuration)
        XCTAssertEqual(DragLandingPlan.duration(travel: DragLandingPlan.referenceTravel),
                       DragLandingPlan.maximumFlightDuration, accuracy: 0.0001)
        // No more added beyond that, otherwise very long distances such as across displays would drag.
        XCTAssertEqual(DragLandingPlan.duration(travel: 5000),
                       DragLandingPlan.maximumFlightDuration, accuracy: 0.0001)
        // A negative number (should not occur) must not get below the lower bound either.
        XCTAssertEqual(DragLandingPlan.duration(travel: -10), DragLandingPlan.minimumDuration)
    }

    /// Square root rather than linear: **short distances must be more
    /// generous than linear**, otherwise a small return flashes by unseen.
    func testShortTravelIsMoreGenerousThanLinear() {
        let quarter = DragLandingPlan.referenceTravel / 4
        let linear = DragLandingPlan.minimumDuration
            + (DragLandingPlan.maximumFlightDuration - DragLandingPlan.minimumDuration) * 0.25
        XCTAssertGreaterThan(DragLandingPlan.duration(travel: quarter), linear)
    }

    /// Every flight carries its own duration, and the view and the
    /// timer read the same value; computed separately they drift.
    func testFlightCarriesItsOwnDuration() {
        let near = DragLandingPlan.flight(from: CGPoint(x: 100, y: 100), fromScale: 1,
                                          anchorScreenRect: CGRect(x: 90, y: 870, width: 40, height: 54),
                                          carrierScreenFrame: carrier)
        let far = DragLandingPlan.flight(from: CGPoint(x: 100, y: 100), fromScale: 1,
                                         anchorScreenRect: CGRect(x: 1200, y: 8, width: 40, height: 54),
                                         carrierScreenFrame: carrier)
        XCTAssertNotNil(near?.duration)
        XCTAssertLessThan(near!.duration, far!.duration)
    }

    /// **Only sub-pixel landings skip the flight.** With the bitmap
    /// carrier, a 5pt "click jitter" flies too: the copy is opaque and
    /// pixel for pixel equal to the slot, so flying back can only look
    /// better than jumping; the old 12pt gate turned more than half of
    /// in-bar landings into an instant jump into place (2026-08-19:
    /// "the short-distance flight animation is a bit fast").
    func testOnlySubPixelTravelSkipsTheFlight() {
        let slot = CGRect(x: 700, y: 8, width: 40, height: 54)
        let centre = CGPoint(x: 720, y: 982 - 35)
        let subPixel = CGPoint(x: centre.x + 0.3, y: centre.y + 0.2)
        XCTAssertNil(DragLandingPlan.flight(from: subPixel, fromScale: 1,
                                            anchorScreenRect: slot, carrierScreenFrame: carrier))
        let jitter = CGPoint(x: centre.x + 4, y: centre.y + 3)
        XCTAssertNotNil(DragLandingPlan.flight(from: jitter, fromScale: 1,
                                               anchorScreenRect: slot, carrierScreenFrame: carrier))
    }

    /// A real drag away always flies.
    func testTravelBeyondTheThresholdStillFlies() {
        let slot = CGRect(x: 700, y: 8, width: 40, height: 54)
        let away = CGPoint(x: 720 + DragLandingPlan.minimumTravel + 6, y: 982 - 35)
        XCTAssertNotNil(DragLandingPlan.flight(from: away, fromScale: 1,
                                               anchorScreenRect: slot, carrierScreenFrame: carrier))
    }

    /// The threshold must be **below** the 8pt drag-start threshold: every real
    /// drag (≥ 8pt) gets a return flight on release, and it must not be raised
    /// back to two digits for "click jitter", which is where instant short-distance
    /// landings came from. It cannot be 0 either (no pointless sub-pixel flights).
    func testThresholdOnlyBlocksSubPixelTravel() {
        XCTAssertGreaterThan(DragLandingPlan.minimumTravel, 0)
        XCTAssertLessThan(DragLandingPlan.minimumTravel, 8)
    }

    // MARK: - Curve by distance (2026-08-19: "the short-distance flight animation is a bit fast")

    /// Both ends are locked: short haul = `shortCurve`, long haul =
    /// the original (0.2, 0.9, 0.3, 1.0), hard-coded as a literal;
    /// the long-haul feel was approved and nobody should change it in passing.
    func testCurveEndsAreFrozen() {
        XCTAssertEqual(DragLandingPlan.curve(travel: 0), DragLandingPlan.shortCurve)
        let long = DragLandingCurve(c0x: 0.2, c0y: 0.9, c1x: 0.3, c1y: 1.0)
        XCTAssertEqual(DragLandingPlan.curve(travel: DragLandingPlan.referenceTravel), long)
        XCTAssertEqual(DragLandingPlan.curve(travel: 5000), long)
        XCTAssertEqual(DragLandingPlan.curve, long)
    }

    /// Nearer is gentler: the short-haul curve's y control points are all below the long-haul
    /// ones (long haul covers 61% in 17% of the time, short haul must not rush like that).
    func testShortCurveIsGentlerThanTheLongOne() {
        XCTAssertLessThan(DragLandingPlan.shortCurve.c0y, DragLandingPlan.curve.c0y)
        XCTAssertLessThanOrEqual(DragLandingPlan.shortCurve.c1y, DragLandingPlan.curve.c1y)
    }

    /// Continuous transition in between: every control point lies between
    /// the two ends and uses the same progress value as the duration.
    func testCurveInterpolatesBetweenTheEnds() {
        let mid = DragLandingPlan.curve(travel: DragLandingPlan.referenceTravel / 4)
        let f = DragLandingPlan.travelFactor(DragLandingPlan.referenceTravel / 4)
        XCTAssertEqual(f, 0.5, accuracy: 0.0001)
        func between(_ v: Double, _ a: Double, _ b: Double) -> Bool { v >= min(a, b) && v <= max(a, b) }
        XCTAssertTrue(between(mid.c0x, DragLandingPlan.shortCurve.c0x, DragLandingPlan.curve.c0x))
        XCTAssertTrue(between(mid.c0y, DragLandingPlan.shortCurve.c0y, DragLandingPlan.curve.c0y))
        XCTAssertTrue(between(mid.c1x, DragLandingPlan.shortCurve.c1x, DragLandingPlan.curve.c1x))
        XCTAssertTrue(between(mid.c1y, DragLandingPlan.shortCurve.c1y, DragLandingPlan.curve.c1y))
        XCTAssertEqual(mid.c0y, DragLandingPlan.shortCurve.c0y
                       + (DragLandingPlan.curve.c0y - DragLandingPlan.shortCurve.c0y) * f, accuracy: 0.0001)
    }

    /// Curve evaluation (computing where the icon is right now on a re-grab):
    /// 0 / 1 at the ends, monotonic, and matching the hand-computed shape
    /// (long haul covers about 61% in 17% of the time; short haul about 77% in 50% of the time).
    func testCurveProgressMatchesTheBezier() {
        let long = DragLandingPlan.curve, short = DragLandingPlan.shortCurve
        XCTAssertEqual(long.progress(at: 0), 0)
        XCTAssertEqual(long.progress(at: 1), 1)
        XCTAssertEqual(long.progress(at: -1), 0)
        XCTAssertEqual(long.progress(at: 2), 1)
        XCTAssertEqual(long.progress(at: 0.17), 0.61, accuracy: 0.03)
        XCTAssertEqual(short.progress(at: 0.5), 0.77, accuracy: 0.02)
        var previous = 0.0
        for i in 1...100 {
            let v = long.progress(at: Double(i) / 100)
            XCTAssertGreaterThanOrEqual(v, previous - 1e-9)
            previous = v
        }
        XCTAssertGreaterThan(long.progress(at: 0.3), short.progress(at: 0.3), "long haul rushes more")
    }

    /// Every flight carries its own curve, like `duration`; the controller must read the same value.
    func testFlightCarriesItsOwnCurve() {
        let near = DragLandingPlan.flight(from: CGPoint(x: 100, y: 100), fromScale: 1,
                                          anchorScreenRect: CGRect(x: 90, y: 870, width: 40, height: 54),
                                          carrierScreenFrame: carrier)!
        let travel = hypot(near.to.x - near.from.x, near.to.y - near.from.y)
        XCTAssertEqual(near.curve, DragLandingPlan.curve(travel: travel))
        XCTAssertNotEqual(near.curve, DragLandingPlan.curve)   // short haul is not the long-haul curve
    }

    // MARK: - Sucked into the capsule (2026-08-19: after stashing the icon drifted toward the taskbar before vanishing)

    /// Release on the capsule to stash: end point = capsule center, scale
    /// to 0.3, fade to 0, fixed duration, not a flight back to the slot.
    func testStashFlightShrinksAndFadesIntoTheTarget() {
        let capsule = CGRect(x: 1400, y: 8, width: 44, height: 54)
        let flight = DragLandingPlan.stashFlight(from: CGPoint(x: 1300, y: 900), fromScale: 0.82,
                                                 targetScreenRect: capsule, carrierScreenFrame: carrier)!
        XCTAssertEqual(flight.to, CGPoint(x: 1422, y: 982 - 35))
        XCTAssertEqual(flight.fromScale, 0.82)
        XCTAssertEqual(flight.toScale, DragLandingPlan.stashScale)
        XCTAssertEqual(flight.toOpacity, 0)
        XCTAssertEqual(flight.duration, DragLandingPlan.stashDuration)
        XCTAssertLessThan(DragLandingPlan.stashScale, 0.5, "it has to read as being sucked in")
        // Capsule position unknown -> no flight (instant finish), never fall back to "fly back to the slot".
        XCTAssertNil(DragLandingPlan.stashFlight(from: .zero, fromScale: 1, targetScreenRect: nil,
                                                 carrierScreenFrame: carrier))
    }

    /// A regular return flight lands opaque.
    func testReturnFlightLandsOpaque() {
        let flight = DragLandingPlan.flight(from: CGPoint(x: 100, y: 100), fromScale: 1,
                                            anchorScreenRect: CGRect(x: 90, y: 870, width: 40, height: 54),
                                            carrierScreenFrame: carrier)!
        XCTAssertEqual(flight.toOpacity, 1)
    }

    // MARK: - Time gate for mid-flight correction (2026-08-18: landing sometimes jittered)

    /// Close to the cap, correction is **not allowed**: a restarted
    /// segment at that point is bound to be cut off by the cap,
    /// which creates the very jump it is meant to cure.
    func testRetargetIsRefusedNearTheDeadline() {
        XCTAssertFalse(DragLandingPlan.allowsRetarget(remainingBeforeDeadline: 0))
        XCTAssertFalse(DragLandingPlan.allowsRetarget(
            remainingBeforeDeadline: DragLandingPlan.duration))
        XCTAssertFalse(DragLandingPlan.allowsRetarget(remainingBeforeDeadline: -1))
    }

    /// With enough time left it is allowed: correction is the cure for "the slot is
    /// still moving, the end point drifts" and cannot be cut off across the board.
    func testRetargetIsAllowedWhileThereIsRoomForAWholeFlight() {
        XCTAssertTrue(DragLandingPlan.allowsRetarget(
            remainingBeforeDeadline: DragLandingPlan.maximumDuration))
    }

    /// The cap must leave room for at least one full correction re-flight,
    /// otherwise the gate is always closed and correction is a dead letter.
    func testDeadlineLeavesRoomForAtLeastOneRetarget() {
        XCTAssertGreaterThan(DragLandingPlan.maximumDuration,
                             2 * (DragLandingPlan.duration + DragLandingPlan.settleMargin))
    }

    /// Correction after takeoff only slides the end point: duration, curve,
    /// start point and opacity are all kept. Recomputing from the new distance
    /// would restart and ease out again on every correction, which is
    /// "jerky" when the anchor drifts frame by frame (2026-09-03).
    func testSlidingARetargetKeepsTheTimelineAndOnlyMovesTheDestination() {
        let carrier = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let flight = DragLandingPlan.flight(from: CGPoint(x: 500, y: 100), fromScale: 1,
                                            anchorScreenRect: CGRect(x: 90, y: 870, width: 40, height: 54),
                                            carrierScreenFrame: carrier)!
        let slid = flight.sliding(to: CGPoint(x: 480, y: 120), toScale: 0.5)
        XCTAssertEqual(slid.to, CGPoint(x: 480, y: 120))
        XCTAssertEqual(slid.toScale, 0.5)
        XCTAssertEqual(slid.from, flight.from)
        XCTAssertEqual(slid.fromScale, flight.fromScale)
        XCTAssertEqual(slid.duration, flight.duration)
        XCTAssertEqual(slid.curve, flight.curve)
        XCTAssertEqual(slid.toOpacity, flight.toOpacity)
    }

    /// No anchor at release -> a hold-in-place flight: start = end, landing
    /// at normal size; it is a placeholder for "waiting for an anchor",
    /// and if it is still that at takeoff it should land directly
    /// (`isStationary`); a real flight is never stationary.
    func testHoldingFlightIsStationaryAndARealFlightIsNot() {
        let held = DragLandingPlan.holdingFlight(at: CGPoint(x: 500, y: 100), scale: 1)
        XCTAssertTrue(held.isStationary)
        XCTAssertEqual(held.from, held.to)
        XCTAssertEqual(held.toScale, DragLandingPlan.landedScale)
        XCTAssertEqual(held.toOpacity, 1)
        let carrier = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let real = DragLandingPlan.flight(from: CGPoint(x: 500, y: 100), fromScale: 1,
                                          anchorScreenRect: CGRect(x: 90, y: 870, width: 40, height: 54),
                                          carrierScreenFrame: carrier)!
        XCTAssertFalse(real.isStationary)
        // Once correction replaces the hold with a real flight it is no longer
        // stationary either; sliding back to the origin counts as a hold again
        XCTAssertFalse(held.sliding(to: real.to, toScale: real.toScale).isStationary)
    }


    /// The lift (sliding from the slot to under the pointer) must be clearly
    /// shorter than the return flight: it is the drag's **takeover** motion,
    /// and when long it becomes "the drag has to wait a moment", the very lag it is meant to cure.
    ///
    /// The gate used to be `/ 3` and was relaxed to `/ 2` on 2026-08-19
    /// when the return went from 0.60 to 0.32. **The intent is unchanged**
    /// (lift clearly shorter than return); what changed is the return itself. To tighten
    /// further, re-decide the lift together with it, do not change only this number.
    func testLiftIsMuchShorterThanTheReturnFlight() {
        XCTAssertLessThan(DragLandingPlan.liftDuration, DragLandingPlan.minimumDuration / 2)
        XCTAssertGreaterThan(DragLandingPlan.liftDuration, 0)
    }

    // MARK: - Speed knob (2026-08-19: "can the return flight be made faster")

    /// The duration table itself must be at "native magnitude": the shortest leg must not be
    /// long enough to read as dragging, nor short enough for the animation to be invisible.
    func testDurationTableStaysInTheNativeBallpark() {
        XCTAssertGreaterThan(DragLandingPlan.minimumDuration, 0.15)
        XCTAssertLessThan(DragLandingPlan.minimumDuration, 0.45)
        XCTAssertGreaterThan(DragLandingPlan.maximumFlightDuration, DragLandingPlan.minimumDuration)
        XCTAssertLessThan(DragLandingPlan.maximumFlightDuration, 0.70)
    }

    /// `DOCK_DRAG_FLIGHT_MS` only accepts "two positive numbers
    /// with shortest ≤ longest"; anything else counts as unset.
    /// **Half applied is worse than not applied** (changing only
    /// the lower bound would swap the two ends of the curve).
    func testFlightDurationOverrideRejectsAnythingMalformed() {
        for bad in ["", "320", "320,", ",500", "abc,500", "320,abc", "0,500", "-320,500", "500,320", "320,500,700"] {
            XCTAssertNil(DragLandingPlan.parseFlightDurations(bad), "'\(bad)' must not be accepted")
        }
        let good = DragLandingPlan.parseFlightDurations("320,500")
        XCTAssertEqual(good?.minimum ?? 0, 0.32, accuracy: 0.0001)
        XCTAssertEqual(good?.maximum ?? 0, 0.50, accuracy: 0.0001)
        // Equal ends are valid (fixed-duration flight), and spaces must be tolerated
        XCTAssertNotNil(DragLandingPlan.parseFlightDurations(" 400 , 400 "))
    }
}
