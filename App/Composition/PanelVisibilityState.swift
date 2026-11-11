import ApplicationServices
import CoreGraphics

enum PanelVisibilityReason: Hashable {
    case fullscreen
    case fullscreenTransitionPending
    case edgeAutoHide
}

enum FullscreenSpaceHoldDisposition: Equatable {
    case apply
    case hold
    case stale
}

enum FullscreenSpaceHoldDecision {
    static let postSpaceConfirmationDelay: TimeInterval = 0.12
    static let activationFallbackDelay: TimeInterval = 0.5

    static func shouldBegin(isFullscreen: Bool, hasInputIntent: Bool) -> Bool {
        isFullscreen && !hasInputIntent
    }

    static func disposition(
        isFullscreenVerdict: Bool,
        expectedGeneration: UInt64?,
        activeGeneration: UInt64?,
        isFinalWindowedConfirmation: Bool
    ) -> FullscreenSpaceHoldDisposition {
        guard let activeGeneration else {
            return expectedGeneration == nil ? .apply : .stale
        }
        guard expectedGeneration == activeGeneration else { return .stale }
        // While the hold is alive, **no non-final verdict is let through**, not even true. The old code
        // (true means .apply) let the false true that CG reports 0.4~0.8s late on leaving fullscreen
        // destroy the 120ms confirmation hold; the correct AX false that followed was then judged .stale
        // (hold already dead) and silently dropped, leaving the bar to the 5s reconcile fallback: "bar
        // returns 2~3s after leaving fullscreen" (measured 2026-08-30; fingerprint: no space-ax line after
        // space-cg true, reveal line 5.098s after the previous ax line). During the hold the
        // state is already .fullscreen, so true has nothing to do; wait 120ms for the final CG+AX verdict.
        // A fullscreen→fullscreen switch is only confirmed 120ms later, and the bar is hidden then anyway.
        if isFinalWindowedConfirmation { return .apply }
        return .hold
    }
}

/// Membership repair for "on all desktops" (issue #19).
///
/// The moment **a fullscreen Space is destroyed, macOS re-attaches any `.canJoinAllSpaces` window
/// that is hidden at that time to the current desktop only**, and the other desktops never see it
/// again. Reproduced on 2026-08-28 with an 80-line standalone experiment unrelated to this project
/// (`scratch/space_membership_lab2.swift`), so it is not a NitiaDock bug, but it hits exactly our
/// "orderOut on entering fullscreen / orderFrontRegardless on leaving" yielding mechanism.
///
/// What does not fix it (all measured): `orderFrontRegardless`, assigning the same `collectionBehavior`
/// again, `orderOut` + reset + `orderFront`. **The only shape that works: set a different value → let
/// one runloop turn pass → assign it back**, and **a single attempt is not guaranteed** (1 of 3
/// experiment rounds needed two repairs), so it must read back to verify and retry, not fire once.
enum AllSpacesMembership {
    static let maxRepairAttempts = 3
    /// How long to wait after assigning back before the read-back
    /// check. Measured: 120ms is enough for WindowServer to settle.
    static let verifyDelay: TimeInterval = 0.12

    /// Which regular desktops this window is still missing from (fullscreen Spaces do not count: the
    /// window should not sit on someone else's fullscreen Space anyway). Empty array = healthy. Always
    /// empty when `desktopSpaceIDs` has fewer than 2: a single desktop cannot "lose a desktop".
    static func missingSpaceIDs(windowSpaceIDs: [Int], desktopSpaceIDs: [Int]) -> [Int] {
        guard desktopSpaceIDs.count > 1 else { return [] }
        let owned = Set(windowSpaceIDs)
        return desktopSpaceIDs.filter { !owned.contains($0) }.sorted()
    }

    static func shouldRetry(attempt: Int) -> Bool { attempt < maxRepairAttempts }
}

enum EdgeAutoHideInhibitor: Hashable {
    case dragging
    case drawerOpen
    case folderPopupOpen
    /// A NitiaDock menu (the one from the status bar icon or from right-clicking
    /// the taskbar) is open. Without this block the idle timer keeps running in
    /// auto-hide mode and the taskbar slides away under the menu.
    case taskbarMenuOpen
}

struct PanelVisibilityState: Equatable {
    var hideReasons: Set<PanelVisibilityReason> = []
    var autoHideInhibitors: Set<EdgeAutoHideInhibitor> = []
    private(set) var fullscreenTransitionGeneration: UInt64?

    var isVisible: Bool { hideReasons.isEmpty }

    mutating func setFullscreen(_ active: Bool) {
        setReason(.fullscreen, active: active)
    }

    mutating func beginFullscreenTransition(generation: UInt64) {
        fullscreenTransitionGeneration = generation
        hideReasons.insert(.fullscreenTransitionPending)
    }

    @discardableResult
    mutating func confirmFullscreenTransition(generation: UInt64) -> Bool {
        guard fullscreenTransitionGeneration == generation else { return false }
        fullscreenTransitionGeneration = nil
        hideReasons.remove(.fullscreenTransitionPending)
        hideReasons.insert(.fullscreen)
        return true
    }

    @discardableResult
    mutating func timeoutFullscreenTransition(generation: UInt64) -> Bool {
        guard fullscreenTransitionGeneration == generation else { return false }
        fullscreenTransitionGeneration = nil
        hideReasons.remove(.fullscreenTransitionPending)
        return true
    }

    mutating func setEdgeAutoHidden(_ active: Bool) {
        setReason(.edgeAutoHide, active: active)
    }

    mutating func setInhibitor(_ inhibitor: EdgeAutoHideInhibitor, active: Bool) {
        if active {
            autoHideInhibitors.insert(inhibitor)
        } else {
            autoHideInhibitors.remove(inhibitor)
        }
    }

    mutating func reconcileEdgeAutoHide(isEnabled: Bool) {
        if !isEnabled || !autoHideInhibitors.isEmpty {
            hideReasons.remove(.edgeAutoHide)
        }
    }

    private mutating func setReason(_ reason: PanelVisibilityReason, active: Bool) {
        if active {
            hideReasons.insert(reason)
        } else {
            hideReasons.remove(reason)
        }
    }
}

@MainActor
enum EdgeAutoHideRuntimeRules {
    static let fixedIdleHideDelay: Double = 0.2

    static func canArmWake(state: PanelVisibilityState, delay: Double) -> Bool {
        state.hideReasons.contains(.edgeAutoHide)
            && !state.hideReasons.contains(.fullscreen)
            && !state.hideReasons.contains(.fullscreenTransitionPending)
            && state.autoHideInhibitors.isEmpty
            && delay != AppSettingsStore.neverHideDelay
            && delay < AppSettingsStore.neverWakeDelay
    }

    static func canArmIdleHide(state: PanelVisibilityState, delay: Double) -> Bool {
        !state.hideReasons.contains(.edgeAutoHide)
            && !state.hideReasons.contains(.fullscreen)
            && !state.hideReasons.contains(.fullscreenTransitionPending)
            && state.autoHideInhibitors.isEmpty
            && delay != AppSettingsStore.neverHideDelay
    }

    static func idleHideInterval(for delay: Double) -> Double? {
        guard delay > AppSettingsStore.neverHideDelay else { return nil }
        return fixedIdleHideDelay
    }

    /// Whether the bottom-edge wake hot zone (spanning the whole bottom edge of the screen) should hold
    /// off idle-hide and block arming the hide timer. True only for a "finite wake delay" (0.1–3.0s): in
    /// this range wake and idle-hide both run, and with the pointer inside the hot zone but outside the
    /// taskbar rect they fight (wake→hide→wake…), so the hot zone itself must count as "not left". 999
    /// (`neverWakeDelay`, auto-hide without wake) has no wake action, so no such fight; hiding proceeds as
    /// usual. -1 (`neverHideDelay`, always shown) never hides anyway, so holding off makes no difference.
    static func bottomHotZoneSuppressesIdleHide(delay: Double) -> Bool {
        delay != AppSettingsStore.neverHideDelay && delay < AppSettingsStore.neverWakeDelay
    }
}
