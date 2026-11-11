import XCTest
@testable import NitiaDock

/// Coordinate conversion for the carrier layer.
///
/// Three coordinate systems are in play at once (screen,
/// bottom-left origin / carrier-panel-local, bottom-left origin /
/// `"strip"` space, top-left origin, y down), and mixing them
/// sends the icon flying to the other end of the screen. In visual
/// acceptance that only ever gets described as "the animation looks odd", and nobody can
/// tell at a glance whether y was flipped or the origin was not subtracted. So pin it down.
final class DragCarrierGeometryTests: XCTestCase {
    /// Main display 1512×982, origin at (0,0).
    private let main = CGRect(x: 0, y: 0, width: 1512, height: 982)

    // MARK: - The carrier panel covers one display at a time

    /// Two displays: the secondary directly above the main one. The panel
    /// covers whichever display the pointer is on, **never the union**:
    /// with "Displays have separate Spaces" a window belongs to one display and the part
    /// beyond it is not drawn (cause of the built-in display "vanishing" on 2026-08-19).
    func testPanelFollowsTheScreenContainingThePoint() {
        let external = CGRect(x: -504, y: 982, width: 2560, height: 1440)
        XCTAssertEqual(DragCarrierGeometry.screenFrame(containing: CGPoint(x: 100, y: 100),
                                                       in: [main, external]), main)
        XCTAssertEqual(DragCarrierGeometry.screenFrame(containing: CGPoint(x: 100, y: 1500),
                                                       in: [main, external]), external)
    }

    /// Point on no display (the edge during a display switch) -> fall back to the first one, never `.zero`.
    func testPointOutsideEveryScreenFallsBackToTheFirst() {
        XCTAssertEqual(DragCarrierGeometry.screenFrame(containing: CGPoint(x: -9999, y: -9999),
                                                       in: [main]), main)
    }

    /// No displays (panel not built yet) -> `.zero`; callers always treat it as "no placement, no flight".
    func testNoScreensIsZero() {
        XCTAssertEqual(DragCarrierGeometry.screenFrame(containing: .zero, in: []), .zero)
    }

    // MARK: - Pixel alignment (the landing frame must not be blurry)

    /// 2x display: a 52pt wide layer, center 100.3 -> left edge
    /// 74.3pt = 148.6px -> rounded to 149px = 74.5pt -> center 100.5.
    func testPixelAlignedSnapsTheOriginToDevicePixels() {
        let center = DragCarrierGeometry.pixelAligned(center: CGPoint(x: 100.3, y: 40.2),
                                                      size: CGSize(width: 52, height: 66),
                                                      scale: 2)
        XCTAssertEqual(center.x, 100.5, accuracy: 0.0001)
        XCTAssertEqual(center.y, 40, accuracy: 0.0001)     // 7.2pt = 14.4px -> 14px = 7pt -> center 40
    }

    /// An already aligned point is returned as is; scale ≤ 0 leaves it alone.
    func testPixelAlignedIsIdempotent() {
        let aligned = DragCarrierGeometry.pixelAligned(center: CGPoint(x: 100.5, y: 40),
                                                       size: CGSize(width: 52, height: 66), scale: 2)
        XCTAssertEqual(aligned, CGPoint(x: 100.5, y: 40))
        XCTAssertEqual(DragCarrierGeometry.pixelAligned(center: CGPoint(x: 1.234, y: 5.678),
                                                        size: CGSize(width: 10, height: 10), scale: 0),
                       CGPoint(x: 1.234, y: 5.678))
    }

    // MARK: - Screen -> panel-local (both bottom-left origin, only a translation apart)

    func testScreenPointSubtractsThePanelOrigin() {
        let panel = CGRect(x: -504, y: 0, width: 2016, height: 982)
        let point = DragCarrierGeometry.panelPoint(screen: CGPoint(x: 100, y: 200), panelFrame: panel)
        XCTAssertEqual(point, CGPoint(x: 604, y: 200))
    }

    /// At drag start the carrier sits at the slot center. A
    /// 40×54 card on the taskbar, visible bottom edge at y=8.
    func testSlotCentreIsWhereTheCarrierStarts() {
        let slot = CGRect(x: 700, y: 8, width: 40, height: 54)
        let centre = DragCarrierGeometry.panelCenter(ofScreenRect: slot, panelFrame: main)
        XCTAssertEqual(centre, CGPoint(x: 720, y: 35))
    }

    // MARK: - Vertical sign flip of the grab offset (the easiest spot to get wrong)

    /// `grabOffset` is measured in a **y-down** space like `"strip"` / `"drawer"`
    /// (`frame.midY − startLocation.y`), while layer coordinates
    /// are y-up, so the vertical component must flip sign.
    /// Flip it wrong and pressing on the upper half of a card
    /// makes the copy jump below the cursor instead of above it.
    func testGrabOffsetVerticalIsInverted() {
        // Press 10pt above the card center -> grab.height = +10 in the y-down space.
        let grab = CGSize(width: 6, height: 10)
        let centre = DragCarrierGeometry.carriedCenter(pointer: CGPoint(x: 400, y: 300),
                                                       grabOffset: grab, panelFrame: main)
        XCTAssertEqual(centre.x, 406)
        XCTAssertEqual(centre.y, 290)   // not 310
    }

    func testCarriedCentreAlsoSubtractsThePanelOrigin() {
        let panel = CGRect(x: -504, y: 982, width: 2560, height: 1440)
        let centre = DragCarrierGeometry.carriedCenter(pointer: CGPoint(x: 0, y: 1000),
                                                       grabOffset: .zero, panelFrame: panel)
        XCTAssertEqual(centre, CGPoint(x: 504, y: 18))
    }

    /// Re-grab: derive the grab offset from the carrier's current center;
    /// feeding it back into `carriedCenter` must return the same point
    /// (holding the icon mid-flight and dragging on must not make it jump).
    /// It must also close on an external display with a negative origin.
    func testGrabOffsetIsTheInverseOfCarriedCenter() {
        for panel in [main, CGRect(x: -504, y: 982, width: 2560, height: 1440)] {
            let pointer = CGPoint(x: 123.4, y: 1000.6)
            let centre = CGPoint(x: 700.25, y: 40.5)   // panel-local
            let grab = DragCarrierGeometry.grabOffset(pointer: pointer, carriedCenter: centre, panelFrame: panel)
            let back = DragCarrierGeometry.carriedCenter(pointer: pointer, grabOffset: grab, panelFrame: panel)
            XCTAssertEqual(back.x, centre.x, accuracy: 0.0001)
            XCTAssertEqual(back.y, centre.y, accuracy: 0.0001)
        }
        // Direction: pointer 6/10pt to the lower right of the icon
        // center -> same numbers as `testGrabOffsetVerticalIsInverted`.
        let grab = DragCarrierGeometry.grabOffset(pointer: CGPoint(x: 400, y: 300),
                                                  carriedCenter: CGPoint(x: 406, y: 290), panelFrame: main)
        XCTAssertEqual(grab, CGSize(width: 6, height: 10))
    }

    // MARK: - Seam with DragLandingPlan (top-left origin y-down <-> bottom-left origin y-up)

    /// The end point of `DragLandingPlan.flight` is "panel-local,
    /// top-left origin, y down"; placement has to flip it.
    func testTopLeftPointFlipsIntoLayerCoordinates() {
        let flipped = DragCarrierGeometry.panelPoint(fromTopLeft: CGPoint(x: 720, y: 947),
                                                     panelFrame: main)
        XCTAssertEqual(flipped, CGPoint(x: 720, y: 35))
    }

    /// **The round trip must close**: slot center -> top-left system
    /// (fed to `DragLandingPlan`) -> flipped back to layer coordinates
    /// must return the same point. The two steps live in two places; a
    /// mismatched seam is the kind of jitter where landing is off by a few pt.
    func testRoundTripThroughTheLandingPlanCoordinateSystemIsClosed() {
        let slot = CGRect(x: 700, y: 8, width: 40, height: 54)
        let layerCentre = DragCarrierGeometry.panelCenter(ofScreenRect: slot, panelFrame: main)
        // DragLandingPlan computes the end point with exactly this conversion.
        let topLeft = CGPoint(x: slot.midX - main.minX, y: main.maxY - slot.midY)
        XCTAssertEqual(DragCarrierGeometry.panelPoint(fromTopLeft: topLeft, panelFrame: main),
                       layerCentre)
    }

    /// The flight **start point** also goes through the top-left system
    /// and must be the same physical point as while following the pointer.
    func testFlightStartMatchesTheLiveCarriedPosition() {
        let pointer = CGPoint(x: 400, y: 300)
        let grab = CGSize(width: 6, height: 10)
        let live = DragCarrierGeometry.carriedCenter(pointer: pointer, grabOffset: grab, panelFrame: main)
        let start = DragCarrierGeometry.topLeftCarriedCenter(pointer: pointer, grabOffset: grab,
                                                             panelFrame: main)
        XCTAssertEqual(DragCarrierGeometry.panelPoint(fromTopLeft: start, panelFrame: main), live)
    }

    /// The case above must also hold on an external display (negative panel origin);
    /// a missing origin subtraction is the other half of this class of bug.
    func testFlightStartMatchesTheLiveCarriedPositionOnAnExternalScreen() {
        let panel = CGRect(x: -504, y: 0, width: 2560, height: 1440)
        let pointer = CGPoint(x: -100, y: 900)
        let grab = CGSize(width: -4, height: 7)
        let live = DragCarrierGeometry.carriedCenter(pointer: pointer, grabOffset: grab, panelFrame: panel)
        let start = DragCarrierGeometry.topLeftCarriedCenter(pointer: pointer, grabOffset: grab,
                                                             panelFrame: panel)
        XCTAssertEqual(DragCarrierGeometry.panelPoint(fromTopLeft: start, panelFrame: panel), live)
    }

    // MARK: - Drag-start pose (hover × press combined)

    /// Medium 54pt card, quiet-level hover 1.10 (bottom anchored) +
    /// press 0.93 (centered): overall 1.023, centroid moves up 2.51pt.
    /// These numbers are the slot's real shape in the 2026-08-19 "vertical
    /// ghosting" report; the carrier does not line up unless placed to match.
    func testPickUpPoseCombinesBottomAnchoredHoverWithCentredPress() {
        let pose = DragCarrierGeometry.pickUpPose(chipHeight: 54, pressedScale: 0.93, hoverScale: 1.10)
        XCTAssertEqual(pose.scale, 1.023, accuracy: 0.0005)
        XCTAssertEqual(pose.dy, 2.511, accuracy: 0.001)
    }

    /// Press only, no hover (standard level): pure center scaling, no upward shift.
    func testPickUpPosePressOnlyDoesNotShift() {
        let pose = DragCarrierGeometry.pickUpPose(chipHeight: 54, pressedScale: 0.93, hoverScale: nil)
        XCTAssertEqual(pose.scale, 0.93, accuracy: 0.0005)
        XCTAssertEqual(pose.dy, 0)
    }

    /// Hover only, no press (folder chip: 1.12 bottom-anchored enlargement, no press feedback).
    func testPickUpPoseHoverOnlyLiftsHalfTheGrowth() {
        let pose = DragCarrierGeometry.pickUpPose(chipHeight: 54, pressedScale: nil, hoverScale: 1.12)
        XCTAssertEqual(pose.scale, 1.12, accuracy: 0.0005)
        XCTAssertEqual(pose.dy, 0.12 * 54 / 2, accuracy: 0.001)
    }

    /// Nothing at all = at rest.
    func testPickUpPoseRestingIsIdentity() {
        XCTAssertEqual(DragCarrierGeometry.pickUpPose(chipHeight: 54, pressedScale: nil, hoverScale: nil),
                       .resting)
    }
}
