import CoreGraphics

/// The **bitmap** of the floating copy held during a drag.
///
/// Since 2026-08-18 the carrier is no longer a separate SwiftUI tree but an image captured at the moment the
/// drag starts (see `ChipSnapshotter`). The reason is structural: the card on the bar and the carrier used to
/// belong to two renderers that do not sync with each other, drag start and landing each needed a "who shows,
/// who hides" handoff, and only SwiftUI knows when either side actually reaches the screen. Every handoff was
/// a race: win and they overlap, lose and there is a gap. Four rounds of flag patches (`carrierReady` /
/// `onAppear` report / fallback timer / early fade-out) only added referees to the race and never converged.
/// With a bitmap, every pixel of the carrier is decided synchronously by `DragController` in the same run
/// loop pass that receives the mouse event, and the handoff no longer exists.
struct CarrierSnapshot {
    /// The bitmap itself. Pixel size = `size × scale`.
    let image: CGImage
    /// Logical size (pt), **including bleed**: this is the carrier layer's `bounds`. For the reason behind
    /// the bleed see `ChipSnapshotter.bleed`: the icon shadow inside the card overflows the layout frame, and
    /// cropping to the layout frame would cut that shadow ring off, so it would not match the card on the bar
    /// at landing.
    let size: CGSize
    /// The card slot's own size (pt, without bleed). For diagnostics only: if it does not match the size of
    /// the `sourceScreenRect` reported at drag start, the snapshot did not draw the same view as the card
    /// slot.
    let contentSize: CGSize
    /// Backing scale used for rendering. The carrier layer's `contentsScale` takes it, otherwise it is blurry
    /// on Retina.
    let scale: CGFloat
}
