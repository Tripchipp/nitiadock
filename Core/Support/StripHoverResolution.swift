import CoreGraphics

/// Pointer position -> which chip owns the hover.
///
/// **Why the taskbar no longer lets each card attach its own `.onHover`.** That gives every card its own
/// `NSTrackingArea`, and hover relies on the paired "enter / exit" the system dispatches. Once the pointer
/// speeds up, macOS coalesces mouse-move events and the enter/exit pairs of the cards in between are dropped
/// entirely, so those cards never know the pointer passed. Measured (2026-08-17, fixed 120Hz synthetic events
/// sweeping a row of 10 cards): 9 hit at 800pt/s, 6 at 1600pt/s, only 3 at 2400pt/s, and a rerun at the same
/// speed dropped from 9 to 5. In the same round's control experiment, turning Liquid Glass off (halving the
/// cost of placing a bubble) changed the hit count in no consistent way, so **the bottleneck is events, not
/// rendering**. This is the "native bubbles keep up with a fast sweep, NitiaDock does not" report.
///
/// The same root cause also explains the "boundary is not fixed": the hit rects of two cards
/// are separated by the `chipSpacing` dead zone, and the handover needs the pointer **fully
/// inside** the next card, so the switch point is directional: right of the geometric midpoint
/// going right, left of it going left, with a measured hysteresis of 3.5pt (2026-08-17).
///
/// **The native Dock does not work this way**: the whole bar is one area and
/// every mouse event is looked up by position to find the tile it is on.
/// This type is that lookup. A pure function whose boundaries depend only on geometry,
/// not on the direction of approach; the tracking area that calls it covers the whole
/// taskbar, so it recomputes on every pointer move without relying on paired events.
///
/// This is **not** the permanent `.mouseMoved` global monitor
/// banned by the project rule on menus, panels and screens:
/// that rule bans `NSEvent.addGlobalMonitorForEvents` (an event tap: system-wide mouse
/// events pass through our process first, and it slows us down by 100ms when we show our own
/// menus). This is an ordinary tracking area **inside our own window**, a different thing.
enum StripHoverResolution {
    /// In the gaps between cards, the hit area is extended outward
    /// by at most this much (pt, before the size tier multiplier).
    ///
    /// Why 2pt: the card spacing itself is `ChipPillMetrics.chipSpacing` (2pt), and extending 2pt
    /// on each side overlaps in the middle of the gap, so the gap has no dead zone and the
    /// boundary falls exactly at **the midpoint between the two cards**, independent of direction.
    /// The 9pt gap at a zone divider still has 5pt empty in the middle after
    /// extending 2 on each side, so hovering the divider still shows nothing
    /// (native behaves the same); likewise for the blank ends of the taskbar.
    static let defaultGapBridge: CGFloat = 2

    /// Ownership decision.
    ///
    /// - Parameters:
    ///   - point: Pointer, in the same coordinate system as `frames` (the `"strip"` space inside the bar).
    ///   - frames: All chip frames taking part (all four zones included); the key is the chip identity.
    ///   - gapBridge: Gap bridging amount, already multiplied by the size tier.
    /// - Returns: Identity of the chip hit; in the wide divider
    ///   gap / the blank ends of the bar / off the bar -> `nil`.
    ///
    /// Inside a gap the verdict goes to the nearest by **distance to the card edge**, not to
    /// the card center: with cards of different widths side by side, the center would give
    /// the narrow card an extra share, while the edge gives the exact middle of the gap.
    static func chip(at point: CGPoint,
                     frames: [String: CGRect],
                     gapBridge: CGFloat = defaultGapBridge) -> String? {
        var best: (id: String, distance: CGFloat, centerDistance: CGFloat)?
        for (id, frame) in frames {
            guard frame.width > 0, frame.height > 0 else { continue }
            guard frame.insetBy(dx: -gapBridge, dy: 0).contains(point) else { continue }
            let distance = max(frame.minX - point.x, point.x - frame.maxX, 0)
            // fork: frames of one app's cards can overlap (`ForkAppearance.sameAppSpacing` below 0), and a
            // pointer inside both is at distance 0 from both. The nearer centre wins then.
            let centerDistance = abs(point.x - frame.midX)
            guard let current = best else {
                best = (id, distance, centerDistance)
                continue
            }
            // Ties are ordered by id, so dictionary iteration order
            // does not make the result jump between two frames.
            if distance < current.distance
                || (distance == current.distance && centerDistance < current.centerDistance)
                || (distance == current.distance && centerDistance == current.centerDistance && id < current.id) {
                best = (id, distance, centerDistance)
            }
        }
        return best?.id
    }
}

/// Where a chip's hover state comes from. **Deliberately no
/// default value**, for the same reason as `scale` / `hoverStyle`:
/// omitting it must be a compile error.
enum ChipHoverInput: Equatable {
    /// Hover state computed externally. The taskbar takes this
    /// path: one bar-wide tracking area + `StripHoverResolution`.
    case resolved(Bool)
    /// The view attaches its own `.onHover` tracking. The
    /// drawer panel has no tracking area and takes this path.
    case selfTracked
}
