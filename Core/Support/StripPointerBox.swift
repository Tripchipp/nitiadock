import CoreGraphics

/// Enter / exit hysteresis box for "is the pointer on the taskbar" (pure geometry, unit-tested). Easy to
/// enter, far to exit, with a hysteresis band in between: jitter at the boundary does not flip it. Two
/// profiles:
/// - `.drawerConversion`: a drawer icon dragged down onto the bar to convert / cancel. Very generous above
///   (enter 16 / exit 40), because the pointer comes from above and jitter near the bar must not cancel the
///   conversion.
/// - `.stripPresence`: a payload dragged from the bar leaving / returning to it (collapse on drag-out). The
///   top matches the native Dock (enter 0 / exit 6): it closes as soon as the pointer leaves the gap at the
///   top of the bar and reopens under the pointer as soon as it returns to a gap inside the bar. Measured
///   frame by frame from a native screen recording (2026-09-03; the earlier 24pt was reported as "you have to
///   lift very high before the taskbar closes"). The 6pt hysteresis band only absorbs pointer jitter.
///
/// The right side always extends to the outer edge of the drawer entry capsule (`rightReach` = capsule gap +
/// capsule width): dragging down from the drawer's rightmost column keeps the cursor on the capsule the whole
/// way, so without it the pointer never enters the box (measured 2026-08-18: enter was false on all 60 frames
/// of the pass); conversely an icon moved sideways from the bar onto the capsule still counts as on the bar,
/// which makes room and does not collapse.
struct StripPointerBox: Equatable {
    enum Profile {
        case drawerConversion
        case stripPresence

        /// Height above the bar top that still counts as "in" / as "clearly out".
        var topEnter: CGFloat { self == .drawerConversion ? 16 : 0 }
        var topOut: CGFloat { self == .drawerConversion ? 40 : 6 }
    }

    let enter: Bool
    let clearlyOut: Bool

    /// - Parameters:
    ///   - pointer: screen coordinates (bottom-left).
    ///   - stripRect: screen rect of the taskbar root view (`DockStripView.stripRootScreenRect`).
    ///   - rightReach: width beyond the bar's right edge that still counts as "on the bar" (the capsule).
    static func classify(pointer g: CGPoint, stripRect r: CGRect, rightReach: CGFloat,
                         profile: Profile) -> StripPointerBox {
        let enter      = g.x >= r.minX - 8  && g.x <= r.maxX + rightReach
                      && g.y >= r.minY - 8  && g.y <= r.maxY + profile.topEnter
        let clearlyOut = g.x < r.minX - 24  || g.x > r.maxX + rightReach + 16
                      || g.y < r.minY - 24  || g.y > r.maxY + profile.topOut
        return StripPointerBox(enter: enter, clearlyOut: clearlyOut)
    }
}
