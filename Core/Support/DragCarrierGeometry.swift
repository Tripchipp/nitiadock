import CoreGraphics

/// Coordinate conversions for the carrier layer (pure decisions).
///
/// **Three** coordinate systems are in play here. Mixing them sends the icon
/// flying to the other side of the screen, and in visual review that only
/// gets described as "the animation feels off". So they are pinned down here:
///
/// | Coordinate system | Origin | y direction | Used by |
/// |---|---|---|---|
/// | Screen | bottom-left of main screen | up | `NSEvent.mouseLocation`, panel frames, `sourceScreenRect` |
/// | Carrier panel | bottom-left of panel frame | up | `CALayer.position` (host view is not flipped) |
/// | `"strip"` / `"drawer"` | top-left of panel content | **down** | `grabOffset`, start and end points of `DragLandingPlan` |
enum DragCarrierGeometry {
    /// **The carrier panel covers one screen at a time**: the one containing `point`, or the
    /// first one if none does (callers treat it as `.zero` while the panel is not built yet).
    ///
    /// Why not the union of all screens (hit on 2026-08-19): with the macOS default "Displays
    /// have separate Spaces" a window belongs to one display and anything outside it is **not
    /// drawn at all**. A union window is assigned to the larger screen, so with the taskbar
    /// on the other screen the carrier never shows during a drag: the "icon disappears when
    /// dragging on the built-in display" bug (the external 5K is larger, so it worked there).
    /// Cross-screen drags now move the panel once the pointer enters another screen.
    static func screenFrame(containing point: CGPoint, in frames: [CGRect]) -> CGRect {
        frames.first { $0.contains(point) } ?? frames.first ?? .zero
    }

    /// Moves a center point to the nearest position where the
    /// layer's bottom-left corner sits on whole device pixels.
    ///
    /// The bitmap matches the card on the bar pixel for pixel only if it is not
    /// resampled: layer size = bitmap pixels / scale (how `CarrierSnapshot.size` is
    /// computed), plus an origin aligned to the pixel grid, and CA copies pixels 1:1.
    /// If the landing end point falls on a half pixel, the last frame is slightly
    /// blurry and the card "suddenly sharpens" as it appears (flaw seen 2026-08-19).
    static func pixelAligned(center: CGPoint, size: CGSize, scale: CGFloat) -> CGPoint {
        guard scale > 0 else { return center }
        let originX = (center.x - size.width / 2) * scale
        let originY = (center.y - size.height / 2) * scale
        return CGPoint(x: originX.rounded() / scale + size.width / 2,
                       y: originY.rounded() / scale + size.height / 2)
    }

    /// Screen point (bottom-left origin) -> AppKit point inside the carrier panel (bottom-left origin).
    static func panelPoint(screen point: CGPoint, panelFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x - panelFrame.minX, y: point.y - panelFrame.minY)
    }

    /// Center of a screen rect -> AppKit point inside the carrier panel.
    /// The carrier sits here at drag start (the slot's own position).
    static func panelCenter(ofScreenRect rect: CGRect, panelFrame: CGRect) -> CGPoint {
        panelPoint(screen: CGPoint(x: rect.midX, y: rect.midY), panelFrame: panelFrame)
    }

    /// Where the carrier belongs while "held in hand": pointer + grab offset.
    ///
    /// `grabOffset` is measured in the **y-down** space of `"strip"` / `"drawer"`
    /// (`frame.midY - value.startLocation.y`), so the vertical component must be negated.
    static func carriedCenter(pointer: CGPoint, grabOffset: CGSize, panelFrame: CGRect) -> CGPoint {
        CGPoint(x: pointer.x - panelFrame.minX + grabOffset.width,
                y: pointer.y - panelFrame.minY - grabOffset.height)
    }

    /// Inverse of `carriedCenter`: given the carrier's current center (bottom-left origin in the
    /// panel) and the pointer, derive `grabOffset`. Used when the icon is re-grabbed mid return flight
    /// (`DragController.regrabLanding`), so the drag continues from the icon's current position
    /// without a jump. Same vertical sign trap as `carriedCenter`: a unit test locks the round trip.
    static func grabOffset(pointer: CGPoint, carriedCenter: CGPoint, panelFrame: CGRect) -> CGSize {
        CGSize(width: carriedCenter.x - (pointer.x - panelFrame.minX),
               height: (pointer.y - panelFrame.minY) - carriedCenter.y)
    }

    /// Points from `DragLandingPlan` are "top-left origin in
    /// the panel, y down"; flip to AppKit's bottom-left origin.
    static func panelPoint(fromTopLeft point: CGPoint, panelFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x, y: panelFrame.height - point.y)
    }

    /// The reverse: current carrier center -> "top-left origin in the
    /// panel, y down", fed as the start point of `DragLandingPlan.flight`.
    static func topLeftCarriedCenter(pointer: CGPoint, grabOffset: CGSize, panelFrame: CGRect) -> CGPoint {
        CGPoint(x: pointer.x - panelFrame.minX + grabOffset.width,
                y: panelFrame.maxY - pointer.y + grabOffset.height)
    }

    // MARK: - Pose at drag start

    /// How the carrier should look when it appears at the slot: overall
    /// scale, and how far the visual center sits above the slot center.
    ///
    /// **The carrier's first frame must match the slot's current rendering pixel for pixel.** Real
    /// drags are always "hover, press, then drag", so at drag start the card in the slot is not at
    /// rest: quiet-mode hover scales it up anchored at the **bottom edge** (`chipQuietHoverScale`),
    /// then the press scales it to 0.93 anchored at the **center** (`chipPressScale`). A carrier
    /// placed at the slot center at the resting 0.93 gives one or two overlapping frames with two
    /// icons 10% apart in size and offset by 2-3 pt vertically: the "vertical ghosting" seen
    /// 2026-08-19 (the first bitmap carrier matched the press but not the hover).
    struct PickUpPose: Equatable {
        /// Overall scale relative to the slot's resting size.
        let scale: CGFloat
        /// How far the visual center sits **above** the slot center (pt, positive
        /// = up). The amount the bottom-anchored scale pushes the center up.
        let dy: CGFloat

        static let resting = PickUpPose(scale: 1, dy: 0)
    }

    /// - Parameters:
    ///   - chipHeight: Layout height of the slot (hover scaling is
    ///     anchored at its bottom edge, press scaling at its center).
    ///   - pressedScale: Scale the card is currently pressed down to;
    ///     `nil` = no press (folder chips have no press feedback).
    ///   - hoverScale: Scale of the card's current bottom-anchored
    ///     enlargement; `nil` = none (standard mode / not hovered).
    ///
    /// Derivation: bottom-anchored scaling s_h raises the center by (s_h − 1)·h/2; the press s_p
    /// about the layout center then multiplies that offset by s_p. Both are uniform scalings on
    /// the vertical center line, so the result is still "uniform scaling about the center +
    /// vertical translation", which one `CALayer` transform + position reproduces exactly.
    static func pickUpPose(chipHeight: CGFloat,
                           pressedScale: CGFloat?,
                           hoverScale: CGFloat?) -> PickUpPose {
        let hover = max(0, hoverScale ?? 1)
        let press = max(0, pressedScale ?? 1)
        let dy = (hover - 1) * chipHeight / 2 * press
        return PickUpPose(scale: hover * press, dy: dy)
    }
}
