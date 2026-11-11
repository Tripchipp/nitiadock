import CoreGraphics

/// When a drawer icon is dragged into the taskbar, whether the whole
/// block lands left or right of which live card (pure decision).
///
/// **Looks only at x, and always has an answer** (as long as the live zone has a card).
/// Both points were forced by measurements (2026-08-18, `DOCK_HOVER_TRACE` drag log):
///
/// - The conversion box deliberately extends **16pt beyond the top edge** of
///   the bar, so a reaction shows earlier when dragging down from the drawer.
///   But the old landing check used a full-frame `contains`, which **never
///   hits** in those 16pt outside the bar, so the first landing degraded 100%
///   of the time to "the whole block lands at the end of the live zone".
/// - Each later cursor move did check again, but with the cursor in the 2pt gap between two cards, or over
///   the messaging/folder zone, it missed just the same -> at that moment the whole block **stayed put**.
///
/// Together, the user saw "the gap opens at a fixed position unrelated to the finger and will not move
/// however you shift", which is the "hard to trigger the animation that pushes other icons aside" report.
///
/// The criterion is **nearest by distance to the card center** (not to the card edge): the question
/// here is "between which two cards to insert", and the card center is exactly the boundary between
/// two adjacent insertion slots. `StripHoverResolution` uses nearest by card edge, because it
/// answers a different question (which card the pointer is **on**); the two are not interchangeable.
enum StripBlockLanding {
    /// - Parameter frames: Frames of the candidate cards in the live zone
    ///   (the dragged block already excluded). Order does not matter.
    /// - Returns: `nil` only when there are no candidates (the live zone really has no other card).
    static func target(pointerX: CGFloat, frames: [String: CGRect]) -> (id: String, after: Bool)? {
        var best: (id: String, distance: CGFloat, after: Bool)?
        for (id, frame) in frames {
            guard frame.width > 0, frame.height > 0 else { continue }
            let distance = abs(pointerX - frame.midX)
            let after = pointerX > frame.midX
            guard let current = best else { best = (id, distance, after); continue }
            // Equal distances are ordered by id so the decision is
            // deterministic (dictionary iteration order is not).
            if distance < current.distance || (distance == current.distance && id < current.id) {
                best = (id, distance, after)
            }
        }
        guard let best else { return nil }
        return (best.id, best.after)
    }
}
