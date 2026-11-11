import SwiftUI

// MARK: - Pure decisions

/// Pure decision layer for press feedback. Time only comes in through parameters; `ChipPressFeedbackTests`
/// locks this down.
///
/// **Why the press-down edge exists** (2026-08-11: pressing felt sticky): the old implementation hung the
/// bounce on
/// `.onTapGesture`, and SwiftUI's TapGesture only fires on **mouse up**: nothing changed on screen at
/// press-down,
/// and scaling only started after release. The whole "press" happened after the click had ended, which reads
/// as lag. It is now driven
/// at press-down by the `onChanged` of `DragGesture(minimumDistance: 0)`.
enum ChipPressDecision {
    /// Scale while pressed. Identical to the previous `isTapPressed ? 0.93 : 1.0`, deliberately unchanged.
    static let pressedScale: CGFloat = 0.93

    /// Minimum time to stay pressed after release. If a very fast click (a few ms from down to up) bounced
    /// back at once,
    /// the scale would not be visible at all; that was the purpose of the old 90ms timer, kept as is.
    static let minimumHold: TimeInterval = 0.09

    /// Fallback upper bound. SwiftUI **cancels** the gesture when a reorder moves the chip (see the comments
    /// at the `DockStripView` message-zone reorder and
    /// the `DrawerView` drawer reorder), in which case `onEnded` may never arrive. Without this gate
    /// the chip would stay at 0.93 forever.
    static let maximumHold: TimeInterval = 1.0

    /// How much longer to hold after release before bouncing back is allowed (0 = bounce back at once).
    ///
    /// - `pressedAt` is nil: no press-down was recorded (e.g. the pulse-only force-touch path), hold the full
    ///   duration.
    /// - Release earlier than press-down (clock anomaly): also hold the full duration, never return a negative.
    static func holdAfterRelease(pressedAt: TimeInterval?, releasedAt: TimeInterval) -> TimeInterval {
        guard let pressedAt, releasedAt >= pressedAt else { return minimumHold }
        return max(0, minimumHold - (releasedAt - pressedAt))
    }
}

/// Feedback on press-down by default. `DOCK_CHIP_PRESS_DOWN=0` restores the old behavior (one pulse on mouse
/// up).
///
/// Reason for the switch: a `minimumDistance: 0` gesture has to coexist with the existing 8pt reorder drag.
/// The repo already has
/// a precedent of `simultaneousGesture` + `onTapGesture` + `nativeContextMenu` coexisting
/// (`DockStripView.chipWithReorder`), but if it affects dragging or clicking on a real machine,
/// it can be turned back at once without waiting for a new build.
enum ChipPressSwitches {
    static let pressDownEnabled = DebugSwitch.chipPressDown.isEnabled(in: ProcessInfo.processInfo.environment)
}

enum ChipPressAnimation {
    /// Press-down has to "sink fast". The old implementation shared one spring (damping 0.5) for both edges,
    /// so press-down overshot too;
    /// that was barely visible when played after release, but is obvious when played at press-down.
    static let down = Animation.easeOut(duration: 0.08)

    /// The bounce-back keeps the old parameters unchanged: this is the look that was already signed off.
    static let up = Animation.spring(response: 0.22, dampingFraction: 0.5)
}

// MARK: - View integration

extension View {
    /// Visual only: press scale + a separate curve for each edge.
    ///
    /// Split into **two modifiers** from the gesture on purpose: the drawer capsule's press only applies to
    /// the 3×3 grid inside while the outer frame stays still
    /// (decided 2026-06-21), so scale and gesture must be attachable at different levels.
    func chipPressScale(_ isPressed: Bool) -> some View {
        scaleEffect(isPressed ? ChipPressDecision.pressedScale : 1.0)
            .animation(isPressed ? ChipPressAnimation.down : ChipPressAnimation.up, value: isPressed)
    }

    /// Drives state only, changes no geometry. Placed **after** `.contentShape(...)` so the press hit area
    /// matches the click exactly.
    ///
    /// - Parameters:
    ///   - isPressed: `@State` held by the caller (same place as the old `isTapPressed`).
    ///   - pulseNonce: external pulse for force touch / middle-click preview. That path has no mouse-up and
    ///     needs one automatic down+up.
    ///   - isEnabled: when off, neither installs the gesture nor responds to pulses (`LauncherChip` uses it
    ///     during a launch session:
    ///     clicks are a no-op then, so press feedback would be misleading).
    ///   - onEvent: diagnostics-only outlet (`ChipAnimationTrace`). **Never feeds the planner / frontmost
    ///     axis**.
    func chipPressGesture(
        isPressed: Binding<Bool>,
        pulseNonce: Int = 0,
        isEnabled: Bool = true,
        onEvent: @escaping (Bool) -> Void = { _ in }
    ) -> some View {
        modifier(ChipPressGestureModifier(
            isPressed: isPressed,
            pulseNonce: pulseNonce,
            isEnabled: isEnabled,
            onEvent: onEvent
        ))
    }
}

private struct ChipPressGestureModifier: ViewModifier {
    @Binding var isPressed: Bool
    let pulseNonce: Int
    let isEnabled: Bool
    let onEvent: (Bool) -> Void

    @State private var pressedAt: TimeInterval?
    @State private var releaseWork: DispatchWorkItem?
    @State private var watchdogWork: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard isEnabled, ChipPressSwitches.pressDownEnabled else { return }
                        beginPress()
                    }
                    .onEnded { _ in
                        guard isEnabled else { return }
                        if ChipPressSwitches.pressDownEnabled {
                            endPress()
                        } else {
                            // Old behavior: one full down + up played on release.
                            firePulse()
                        }
                    }
            )
            .onChange(of: pulseNonce) { _ in
                guard isEnabled else { return }
                firePulse()
            }
            .onDisappear {
                cancelPending()
                setPressed(false)
            }
    }

    private func beginPress() {
        guard !isPressed else { return }
        cancelPending()
        pressedAt = ProcessInfo.processInfo.systemUptime
        setPressed(true)
        scheduleWatchdog()
    }

    private func endPress() {
        guard isPressed else { return }
        let hold = ChipPressDecision.holdAfterRelease(
            pressedAt: pressedAt,
            releasedAt: ProcessInfo.processInfo.systemUptime
        )
        if hold <= 0 {
            cancelPending()
            setPressed(false)
        } else {
            scheduleRelease(after: hold)
        }
    }

    /// Paths with no mouse-up (force touch / middle-click preview / compatibility behavior with press-down
    /// off).
    private func firePulse() {
        cancelPending()
        pressedAt = ProcessInfo.processInfo.systemUptime
        setPressed(true)
        scheduleRelease(after: ChipPressDecision.minimumHold)
    }

    private func scheduleRelease(after delay: TimeInterval) {
        // The release countdown has started, so the watchdog is pointless (it only guards "onEnded never
        // arrives").
        watchdogWork?.cancel()
        watchdogWork = nil
        releaseWork?.cancel()
        let work = DispatchWorkItem {
            releaseWork = nil
            setPressed(false)
        }
        releaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleWatchdog() {
        watchdogWork?.cancel()
        let work = DispatchWorkItem {
            watchdogWork = nil
            setPressed(false)
        }
        watchdogWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ChipPressDecision.maximumHold,
            execute: work
        )
    }

    private func cancelPending() {
        releaseWork?.cancel()
        releaseWork = nil
        watchdogWork?.cancel()
        watchdogWork = nil
    }

    private func setPressed(_ value: Bool) {
        guard isPressed != value else { return }
        isPressed = value
        onEvent(value)
    }
}
