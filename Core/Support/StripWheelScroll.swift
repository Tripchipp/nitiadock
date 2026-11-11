import CoreGraphics

/// Pure decision for horizontal taskbar scrolling: converts one scroll event into a horizontal offset within
/// the bar.
///
/// Why it exists: an overflowing taskbar scrolls with a horizontal `ScrollView`, and a horizontal ScrollView
/// **does not respond to vertical swipes at all**. Only discrete wheels used to be taken over
/// (`hasPreciseScrollingDeltas == false`), so trackpads, Magic Mouse and mice with smooth scrolling on
/// (Logitech Options etc.), which all send continuous events, had every
/// vertical swipe swallowed (issue #14).
///
/// Side effects (reading `NSEvent`, writing `NSScrollView`) stay in the intercepting view in `DockStripView`.
enum StripWheelScroll {
    /// Points per discrete wheel notch. Finalized feel: must be identical before and after any change.
    static let wheelSpeed: CGFloat = 56
    /// Per-event step cap for discrete wheels. A fast flick can produce a large delta; uncapped it jumps to
    /// the end at once.
    static let maxStep: CGFloat = 120

    /// Pure input extracted from `NSEvent`.
    struct Input: Equatable {
        var deltaX: CGFloat
        var deltaY: CGFloat
        /// `NSEvent.hasPreciseScrollingDeltas`: true = continuous event (trackpad / Magic Mouse / smooth
        /// wheel).
        var hasPreciseDeltas: Bool
        /// `NSEvent.isDirectionInvertedFromDevice`: whether system "natural scrolling" applies to this
        /// device.
        /// **Taken from the event itself, not read from `com.apple.swipescrolldirection`**: correct per
        /// device, and no UserDefaults read remains on the event hot path.
        var isDirectionInverted: Bool

        init(deltaX: CGFloat, deltaY: CGFloat, hasPreciseDeltas: Bool, isDirectionInverted: Bool) {
            self.deltaX = deltaX
            self.deltaY = deltaY
            self.hasPreciseDeltas = hasPreciseDeltas
            self.isDirectionInverted = isDirectionInverted
        }
    }

    /// Horizontal offset to scroll within the bar (pt, positive = forward); `nil` = this event is not taken
    /// over and goes unchanged to the `NSScrollView` underneath.
    static func horizontalStep(for input: Input) -> CGFloat? {
        guard input.deltaY != 0 else { return nil }
        // **Mostly horizontal gestures must pass through**: left / right swipes on a trackpad or Magic Mouse
        // are already handled natively by NSScrollView, with inertia and rubber banding; taking them over
        // would only make it worse.
        guard abs(input.deltaY) > abs(input.deltaX) else { return nil }

        let sign: CGFloat = input.isDirectionInverted ? -1 : 1
        if input.hasPreciseDeltas {
            // A continuous event's delta is already in points, so 1:1 is enough; multiplying by wheelSpeed
            // would overshoot.
            // No cap either: the large deltas of the inertia phase are exactly the feel it should have.
            let step = sign * input.deltaY
            return step == 0 ? nil : step
        }
        let raw = sign * input.deltaY * wheelSpeed
        let step = min(max(raw, -maxStep), maxStep)
        return step == 0 ? nil : step
    }
}
