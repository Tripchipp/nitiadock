import CoreGraphics
import Foundation

/// One flight of the floating copy "back to its slot" after release. Coordinates are all **inside the
/// carrier panel** (top-left origin, y down), because the carrier is the only place that draws it.
struct DragLandingFlight: Equatable {
    let from: CGPoint
    let to: CGPoint
    let fromScale: CGFloat
    let toScale: CGFloat
    /// How long **this** flight lasts. Computed from distance, not
    /// a global constant, see `DragLandingPlan.duration(travel:)`.
    let duration: TimeInterval
    /// Which curve **this** flight uses. Also by distance (gentle when
    /// near, fast when far), see `DragLandingPlan.curve(travel:)`.
    let curve: DragLandingCurve
    /// Opacity at landing: back to the slot = 1; sucked into the capsule = 0 (`DragLandingPlan.stashFlight`).
    var toOpacity: Float = 1

    /// Mid-flight correction: **only the end point changes;
    /// start / duration / curve / opacity stay as they are.**
    /// The flight is already running, so a new duration and curve means restarting from now and
    /// easing to a stop again; when the anchor drifts every frame (taskbar unfreezes and recenters,
    /// drawer panel slides along for 0.22s) restarting per frame is the "stutter" (2026-09-03 trace:
    /// resent 11 times within 0.22s, end point moving 1-3pt each time).
    /// Sliding the end point on the same timeline reads as one smooth path.
    func sliding(to newTo: CGPoint, toScale newToScale: CGFloat) -> DragLandingFlight {
        DragLandingFlight(from: from, to: newTo, fromScale: fromScale, toScale: newToScale,
                          duration: duration, curve: curve, toOpacity: toOpacity)
    }

    /// A "hold in place" flight (`DragLandingPlan.holdingFlight`): travel is
    /// below `minimumTravel`, so if it is still this one at takeoff it lands
    /// immediately instead of making the carrier wait out a duration in place.
    var isStationary: Bool {
        hypot(to.x - from.x, to.y - from.y) < DragLandingPlan.minimumTravel
    }
}

/// A fixed-duration cubic Bezier curve (the four numbers of `CAMediaTimingFunction(controlPoints:)`).
struct DragLandingCurve: Equatable {
    let c0x: Double
    let c0y: Double
    let c1x: Double
    let c1y: Double

    /// Progress (0…1) at normalized time `t` (0…1): solve x(s) = t, then take y(s), the same
    /// algorithm as CA / CSS timing functions. **The controller uses it to compute "where the
    /// flying icon is right now"** (`DragController.landingPose`). `CALayer.presentation()` lags
    /// what is on screen by about two frames, and the flight covers over ten pt per frame at the
    /// start, so freezing by it jumps backwards (15pt measured from frame captures on 2026-08-19);
    /// only computing it ourselves on the same curve and clock matches the render server.
    func progress(at t: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        var lo = 0.0, hi = 1.0, s = t
        for _ in 0..<48 {
            let x = Self.bezier(s, c0x, c1x)
            if abs(x - t) < 1e-7 { break }
            if x < t { lo = s } else { hi = s }
            s = (lo + hi) / 2
        }
        return Self.bezier(s, c0y, c1y)
    }

    private static func bezier(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
        let u = 1 - s
        return 3 * u * u * s * p1 + 3 * u * s * s * p2 + s * s * s
    }
}

/// Pure decisions for the return flight (2026-08-18: the icon's return
/// animation on release was less calm and graceful than the native Dock).
///
/// **Before the rework this phase did not exist**: in `endDrag()` the carrier's `orderOut` and
/// `draggingPayload = nil` happened in the same frame, so the floating copy in hand vanished instantly and
/// the card on the bar went from opacity 0 to 1 instantly. The distance from the cursor to the slot center,
/// and the 1.05 -> 1.0 size difference, were all **jumped**. The native Dock flies the icon back to its slot.
///
/// The decisions are extracted for the same reason as `DragConversionPlan` / `StripHoverResolution`:
/// coordinate conversion is the easiest thing to get wrong (screen is bottom-left
/// origin, carrier panel is top-left origin), and unit tests pin it down.
enum DragLandingPlan {
    /// The two ends of the flight duration. **Duration follows distance, it is not
    /// fixed** (2026-08-18: not as calm and graceful as the native animation).
    ///
    /// The trouble with a fixed duration: the same 0.26s feels
    /// hurried for a 20pt return and rushed for a 200pt trip.
    /// Much of the native "calm" comes from longer distances taking longer. Square root rather than linear:
    /// short distances do not get too short to see, and long ones do not drag.
    /// Tuned round by round: 0.16/0.34 -> 0.22/0.46 -> 0.30/0.62 -> 0.60/0.90
    /// (2026-08-18) -> **0.32/0.50** (2026-08-19: "much slower than native").
    ///
    /// **This is not a regression, the premise changed.** 0.60/0.90 was set when the carrier was
    /// still a translucent SwiftUI copy and the curve was still the long-haul fast-out, slow-stop
    /// one: that curve covers 61% in 17% of the time and the eye can barely see movement for most
    /// of the rest, so 0.6s read as "calm" back then. After 2026-08-19 swapped the short-haul
    /// curve for a standard ease-out, the same duration had far more "visible travel" and felt
    /// sluggish. The curve stays; only the durations are scaled back proportionally.
    ///
    /// These two numbers can be tuned without reinstalling:
    /// `DOCK_DRAG_FLIGHT_MS=320,500` (see `DragLandingSwitches.flightDurations`).
    static let minimumDuration: TimeInterval = DragLandingSwitches.flightDurations?.minimum ?? 0.32
    static let maximumFlightDuration: TimeInterval = DragLandingSwitches.flightDurations?.maximum ?? 0.50
    /// At this travel the full duration is used; farther does not add more.
    static let referenceTravel: CGFloat = 300

    /// **Travel below this does not fly, it lands directly.** Only blocks subpixel moves:
    /// the landing is already rounded to device pixels
    /// (`DragCarrierGeometry.pixelAligned`), and a flight of less than 1pt shows nothing.
    ///
    /// It used to be 12pt, set for "hand shake while clicking": the drag threshold is 8pt, so a
    /// shake is a tiny drag, and back then the carrier was still a translucent SwiftUI copy, so
    /// wobbling back in place for 0.6s left a visible shadow (2026-08-18: "clicking the icon next
    /// to an icon shows a vertical ghost"). With the bitmap carrier that reason is gone: the copy
    /// is opaque, pixel-identical to the slot, and hover is not re-evaluated after landing, so
    /// flying back is only better than jumping. Conversely, 12pt is exactly the most common
    /// landing for reorders within the bar (icon spacing is 42pt, the slot center and the carrier
    /// differ by 0-21pt on release, more than half within 12pt), and all of those jumped into
    /// place instantly, which is half of the "short distances feel too fast" report of 2026-08-19.
    /// A hand shake of 8-12pt now flies too, sliding back like the native Dock instead of jumping back.
    static let minimumTravel: CGFloat = 1

    /// Fallback/baseline duration (nominal value used by the correction gate
    /// and unit tests). The real per-flight duration is `duration(travel:)`.
    static let duration: TimeInterval = 0.26

    static func duration(travel: CGFloat) -> TimeInterval {
        minimumDuration + (maximumFlightDuration - minimumDuration) * travelFactor(travel)
    }

    /// Distance -> a 0…1 progress value: reaches 1 at `referenceTravel`
    /// and no more beyond it; square root (more generous at short range).
    /// **Both duration and curve use it**, one number deciding "how long-haul this flight is".
    static func travelFactor(_ travel: CGFloat) -> Double {
        min(1, max(0, Double(travel) / Double(referenceTravel))).squareRoot()
    }

    /// **The curve also follows distance: gentle when near, fast when far, with a
    /// continuous transition** (2026-08-19: short-distance flights felt too fast).
    ///
    /// Duration already has a 0.60s floor, yet short trips still looked
    /// fast because the long-haul curve (`curve`) is too front-loaded:
    /// 61% covered in 17% of the time, 84% in 31%. A 300pt trip leaves 48pt to ease out
    /// over the second half, which reads as "calm"; a 30pt trip finishes its visible travel
    /// in 0.15-0.2s and crawls the last few pt over 0.4s, which amounts to no animation. So
    /// short trips get a gentler ease-out: `shortCurve` is Penner's easeOutQuad, 53% in 30%
    /// of the time and 77% in 50%, so the first 0.4s of 0.6s is **visibly** sliding.
    /// Between the two ends the four control points are interpolated linearly by `travelFactor`. No
    /// threshold switch, because two flights on either side of a threshold would look different. At
    /// `referenceTravel` and above it is the original curve, so the approved long haul is unchanged.
    static func curve(travel: CGFloat) -> DragLandingCurve {
        let f = travelFactor(travel)
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * f }
        return DragLandingCurve(c0x: mix(shortCurve.c0x, curve.c0x),
                                c0y: mix(shortCurve.c0y, curve.c0y),
                                c1x: mix(shortCurve.c1x, curve.c1x),
                                c1y: mix(shortCurve.c1y, curve.c1y))
    }

    /// The curve at the short-haul end (Penner easeOutQuad). Still
    /// fast out, slow stop, and still ends exactly at `duration`.
    static let shortCurve = DragLandingCurve(c0x: 0.25, c0y: 0.46, c1x: 0.45, c1y: 0.94)

    /// Parser for `DOCK_DRAG_FLIGHT_MS` (pure function, unit tested). `"320,500"` -> 0.32s / 0.50s.
    /// Anything invalid is `nil`: **half applied is worse than not applied**,
    /// since honoring only the lower bound would invert the two ends of the curve.
    static func parseFlightDurations(_ raw: String) -> (minimum: TimeInterval, maximum: TimeInterval)? {
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let lo = parts[0], let hi = parts[1],
              lo > 0, hi > 0, lo <= hi else { return nil }
        return (lo / 1000, hi / 1000)
    }

    /// After the carrier arrives, wait a little before actually
    /// removing it, leaving margin for the last frame to commit.
    static let settleMargin: TimeInterval = 0.03

    /// Mid-flight correction pushes back the moment the carrier is removed (each correction flies another
    /// segment). This is the hard cap for the whole flight, so the carrier does not hang around while the
    /// slot keeps moving. Normally never reached: nothing reorders on release, so the slot is still.
    static let maximumDuration: TimeInterval = 2.00

    /// Stop correcting when less than one full duration remains before the flight cap: a restarted
    /// segment would be cut off by the cap and create the very jump it is meant to cure.
    static func allowsRetarget(remainingBeforeDeadline: TimeInterval,
                               flightDuration: TimeInterval = duration) -> Bool {
        remainingBeforeDeadline > flightDuration + settleMargin
    }

    /// **Must be a fixed-duration curve, not a spring** (2026-08-18: the return visibly still jittered).
    ///
    /// `spring(response: 0.26)` has **not stopped at all** at 0.26s: response is only its natural
    /// period, and it takes 2-3 times that to come to rest. The carrier removal timer is cut at
    /// `duration`, so the icon was cut off mid-flight and the remaining distance was covered in
    /// one jump by "carrier vanishes, card on the bar appears", which looks like a jitter.
    ///
    /// Control points are the repo's existing "fast out, slow
    /// stop" curve (same as `PopoverAnimation.curve()`):
    /// quick start and gentle finish, which is how the native
    /// Dock return reads, and it **really ends at `duration`**.
    /// This is the **long-haul** end; each flight uses `curve(travel:)`
    /// to pick between it and `shortCurve` by distance.
    static let curve = DragLandingCurve(c0x: 0.2, c0y: 0.9, c1x: 0.3, c1y: 1.0)

    /// **Lift**: how long the carrier takes to slide from the slot to under the pointer at drag start.
    ///
    /// The drag threshold is `DragGesture(minimumDistance: 8)`, so if the carrier
    /// appeared directly under the pointer the icon would **jump** there, which is half
    /// of the "first frame of dragging a selected icon stutters" report of 2026-08-18.
    /// The position animation is additive (`isAdditive`), so the mouse moving during the lift does not
    /// conflict: the model value still changes every frame and the added offset decays to 0 on its own.
    static let liftDuration: TimeInterval = 0.12

    /// The short stretch (two display frames) after the card is hidden and before
    /// the lift, where the carrier holds still at the slot in the slot's pose.
    /// Carrier changes are an explicit transaction committed on the spot;
    /// "hiding" the card waits for the SwiftUI/AppKit display cycle.
    /// When the main thread is busy the two can differ by a frame or two, and a carrier
    /// that has already left the slot then shows a double image, so it waits first and
    /// the two overlapping frames are pixel-identical (`DragController.armCarrier`).
    static let liftDelay: TimeInterval = 0.034

    /// With **no prepared candidate**, how long the carrier
    /// covers the card at the slot before "hide card + lift".
    ///
    /// The bitmap's first frame is one display frame later than SwiftUI hiding the card (texture upload,
    /// measured). The first version waited "one run loop turn", but a real mouse sends an event every
    /// 1-8ms and the next turn is often in the same frame -> a one-frame gap = "sometimes disappears".
    /// Waiting two display frames by time (33ms at 60Hz) is what lines up with the display; on ProMotion
    /// 120Hz that is four frames, and waiting longer only overlaps a few more frames, which is
    /// invisible. **The normal path does not come here**: after prepare-on-press (`prepareCandidate`)
    /// the texture is already uploaded and the drag is let through in the same turn.
    static let pickUpSettle: TimeInterval = 0.034

    /// After release, **how long the return flight holds before taking off** (only
    /// for flights back to a slot/cell; sucking into the capsule does not wait).
    ///
    /// At the moment of release the landing anchor is still from the frame **before landing**: the
    /// drawer grid only knows, after the layout this drop commits, which column the cell ends up
    /// in. Taking off without waiting, CA first flies toward the old cell and a few milliseconds
    /// later `retargetLandingIfNeeded` pulls the end point back, which shows as a bent path
    /// (2026-08-20: "drifts to the right of the target first, then goes to the target").
    ///
    /// **Wait by time, not by run loop turns**, for the same reason as `pickUpSettle`: a real
    /// mouse sends an event every 1-8ms and the next turn is often in the same frame. Two display
    /// frames are enough to reach that layout; meanwhile the carrier stays at the release
    /// position, and with the flight itself at 320-500ms these two frames are not noticeable.
    static let landingSettle: TimeInterval = 0.034

    /// Opacity of the carrier layer while prepared on press. **Not 0**: a fully
    /// transparent layer is culled from the render tree and its texture is not uploaded,
    /// which would waste the warm-up; 0.01 is invisible but does go through the upload.
    static let candidateOpacity: Float = 0.01

    /// After a mid-flight re-grab, pointer movement below this before
    /// release = **click** (activate / minimize that card), above = drag.
    /// Same number as the chip drag threshold `DragGesture(minimumDistance: 8)`.
    static let regrabClickSlop: CGFloat = 8

    /// Cap on the hover hold after landing. Normally it ends as soon as the pointer moves; this is the
    /// fallback for "the user does not move after release", so the 60Hz poll does not hang forever.
    static let hoverHoldMaximum: TimeInterval = 3.0

    /// Duration of state changes during a drag (entering/leaving
    /// the drop zone, a folder dragged off the bar).
    static let stateChangeDuration: TimeInterval = 0.12

    /// Look of a folder chip dragged outside the taskbar's visible range: fades + slightly
    /// enlarges, giving live feedback for "release removes the pin" (2026-07-06). It used
    /// to be hardcoded in the carrier view and moved here when the carrier became a bitmap.
    static let folderRemovalScale: CGFloat = 1.1
    static let folderRemovalOpacity: Float = 0.35

    /// Scale while held in hand (the steady state of `DragCarrierView`).
    /// **1.0, no enlargement** (2026-08-19, was 1.05): neither the native Dock nor BestDock
    /// enlarges on pick-up (BestDock's preview window is even called `dragPreviewLockedSize`);
    /// no scaling = the bitmap is never resampled, so it stays as sharp as the card on the bar
    /// from drag start to landing, and the last landing frame has no "sudden sharpening".
    static let carriedScale: CGFloat = 1.0
    /// Scale while hovering over a drop zone (capsule / taskbar).
    static let dropZoneScale: CGFloat = 0.82
    /// At landing it is the same size as the card on the bar.
    static let landedScale: CGFloat = 1.0

    /// **Released on the capsule to stash = sucked into the capsule** (2026-08-19
    /// screenshot: after stashing, the icon drifted toward the taskbar before vanishing).
    /// Once the stash commits, that cell on the bar is gone; flying back to a position that no longer
    /// exists just vanishes. Instead it flies to the capsule center, scales to `stashScale` and fades
    /// to 0. Fixed duration: this is not the calm "back to its place" return, it is "being sucked in".
    static let stashScale: CGFloat = 0.3
    static let stashDuration: TimeInterval = 0.35

    /// Flight into the capsule. `targetScreenRect` = the capsule's visible
    /// frame; `nil` = capsule position unknown -> no flight (instant finish).
    static func stashFlight(from: CGPoint,
                            fromScale: CGFloat,
                            targetScreenRect: CGRect?,
                            carrierScreenFrame: CGRect) -> DragLandingFlight? {
        guard let rect = targetScreenRect,
              rect.width > 0, rect.height > 0,
              carrierScreenFrame.width > 0, carrierScreenFrame.height > 0 else { return nil }
        let to = CGPoint(x: rect.midX - carrierScreenFrame.minX,
                         y: carrierScreenFrame.maxY - rect.midY)
        return DragLandingFlight(from: from, to: to,
                                 fromScale: fromScale, toScale: stashScale,
                                 duration: stashDuration, curve: shortCurve, toOpacity: 0)
    }

    /// **No landing anchor at release yet, but one is about to arrive** (released off the
    /// bar after close-on-drag-out: the empty slot only reopens at this moment, and the bar
    /// cannot report that cell's frame until the next SwiftUI commit; when dragging a window
    /// across screens it is even another strip drawing this card for the first time):
    /// returns a hold-in-place flight that takes the hold (`landingSettle`) path, and once
    /// the anchor arrives the correction **replaces it entirely** with the real flight.
    /// If it is still this one at takeoff (the anchor never came) -> land directly
    /// (`isStationary`). This case used to finish instantly, which across screens
    /// was the "icon vanishes on release and pops up on bar B" report of 2026-09-03.
    static func holdingFlight(at point: CGPoint, scale: CGFloat) -> DragLandingFlight {
        DragLandingFlight(from: point, to: point, fromScale: scale, toScale: landedScale,
                          duration: minimumDuration, curve: shortCurve)
    }

    /// Screen rect (bottom-left origin) -> center point inside the carrier panel (top-left origin).
    ///
    /// - Parameter anchorScreenRect: The cell on screen where this item will end up. `nil`
    ///   = unknown -> no flight, take the pre-rework instant finish (the zero-risk way
    ///   out). The convert-into-taskbar branch is this case: release unfreezes the taskbar
    ///   width, the whole bar recenters, and the landing still drifts during the flight.
    static func flight(from: CGPoint,
                       fromScale: CGFloat,
                       anchorScreenRect: CGRect?,
                       carrierScreenFrame: CGRect) -> DragLandingFlight? {
        guard let rect = anchorScreenRect,
              rect.width > 0, rect.height > 0,
              carrierScreenFrame.width > 0, carrierScreenFrame.height > 0 else { return nil }
        let to = CGPoint(x: rect.midX - carrierScreenFrame.minX,
                         y: carrierScreenFrame.maxY - rect.midY)
        // Subpixel -> no flight (see `minimumTravel` for why).
        let travel = hypot(to.x - from.x, to.y - from.y)
        guard travel >= minimumTravel else { return nil }
        return DragLandingFlight(from: from, to: to,
                                 fromScale: fromScale, toScale: landedScale,
                                 duration: duration(travel: travel),
                                 curve: curve(travel: travel))
    }
}

/// Switches for the return flight. New feel always ships with a way out (same as
/// `ChipPressSwitches`): if it fights reordering or cross-panel stashing on a real machine,
/// it can be reverted to the instant finish right away without waiting for a new build.
enum DragLandingSwitches {
    static let enabled = DebugSwitch.dragLanding.isEnabled(in: ProcessInfo.processInfo.environment)

    /// Live tuning knob for the return flight duration:
    /// `DOCK_DRAG_FLIGHT_MS=<min>,<max>` (milliseconds, e.g. `320,500`).
    ///
    /// The reason is practical: these two numbers went through five rounds of tuning, each needing
    /// "change constant -> rebuild -> reinstall -> feel it again", over two minutes a round. With
    /// this, changing the env var and restarting is enough and converges in seconds (same
    /// precedent as `DOCK_PANEL_MATERIAL`). **The defaults still live in `DragLandingPlan`**;
    /// without this variable the behavior is identical to the hardcoded constants.
    ///
    /// An invalid value (half missing, not a number, not positive,
    /// min > max) is treated as unset, never half applied.
    static let flightDurations: (minimum: TimeInterval, maximum: TimeInterval)? =
        DebugSwitch.dragFlightMs.value(in: ProcessInfo.processInfo.environment)
            .flatMap(DragLandingPlan.parseFlightDurations)
}
