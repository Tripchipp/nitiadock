import Foundation
import CoreGraphics

struct WindowRecord: Hashable, Sendable {
    let id: WindowID
    let appID: AppID
    let pid: Int32
    let bundleIdentifier: String?
    var title: String
    var bounds: CGRect?
    var status: WindowStatus
    var cgWindowID: CGWindowID?
    var isOnDesktop: Bool
    /// Stable group identity (root fix for tab groups). All native tab seats of one physical window share one
    /// token, which once assigned **does not change with the CGWindowID of the currently active tab**; a
    /// plain single window is a token forming its own group. The taskbar merges by it and uses it as the
    /// card's stable id (switching tabs / background tabs coming and going never change the identity -> the
    /// card neither jumps nor splits). Default empty string = degrades to each `id` standing alone
    /// (compatible with paths that do not assign it).
    var groupID: String
    /// Which display the window is on (display UUID, coarse ownership key; multi-display ④ filters window
    /// cards by it). nil = the list has no position (fallback card, frame not read yet); landing on the main
    /// display is decided by the projection layer, no guessing here. Frozen at the last visible display while
    /// minimized / hidden.
    var displayUUID: String?

    init(
        id: WindowID,
        appID: AppID,
        pid: Int32,
        bundleIdentifier: String?,
        title: String,
        bounds: CGRect?,
        status: WindowStatus,
        cgWindowID: CGWindowID? = nil,
        isOnDesktop: Bool = false,
        groupID: String = "",
        displayUUID: String? = nil
    ) {
        self.id = id
        self.appID = appID
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.bounds = bounds
        self.status = status
        self.cgWindowID = cgWindowID
        self.isOnDesktop = isOnDesktop
        self.groupID = groupID.isEmpty ? id.rawValue : groupID
        self.displayUUID = displayUUID
    }
}

enum WindowStatus: String, Hashable, Codable, Sendable {
    case active
    case inactive
    case minimized
    case hidden
    case closedPending
    case disappeared
}

/// Optimistic state overlay (interaction polish 2026-06-13): the moment a click sends a show/hide action
/// (activate / minimize / hide), assume locally that the window is already in the target state; the UI and
/// the next toggle plan read it first without waiting for the snapshot round trip. This is the root of
/// "interruptible / chained clicks". Cleared when the real snapshot fulfills the prediction or on timeout
/// (silent snap-back). close / quit write no optimistic state (the window is going away, and a snap-back on
/// failure would flash).
///
/// Predicts status only, not the frontmost axis (2026-07-05): the frontmost axis has an immediate, accurate
/// system reading (isActive on a freshly created NSRunningApplication instance, which flips right after a
/// SkyLight switch), so predicting it only goes wrong: an isAppFrontmost=true that lingered the full 4s once
/// planned "clicking a card while another app is frontmost" as minimize.
struct OptimisticWindowState: Hashable, Sendable {
    let status: WindowStatus
    let createdAt: Date
    /// This .active prediction describes "focus is arriving at this window through a system transition": a
    /// restore animation (clicking a minimized window to restore it) or a minimize handoff (the successor the
    /// system promotes after the focused window is minimized). During the transition the snapshot may briefly
    /// confirm a sibling as .active (afterimage); takeover clearing gives such predictions a 1.5s grace (see
    /// `supersededByActiveSibling`). Omitted = false (ordinary activation by a user click on a visible
    /// window).
    let focusHandoffGrace: Bool
    /// This prediction was inferred by the system (the successor prediction of a minimize handoff), not
    /// caused by a user click. A system prediction is weaker evidence than a user action: it is cleared
    /// immediately when the snapshot falsifies it (the window is actually minimized/hidden), see
    /// `systemPredictionFalsified`. Omitted = false (originating from a user action, semantically correct).
    let systemPredicted: Bool

    init(status: WindowStatus, createdAt: Date, focusHandoffGrace: Bool = false, systemPredicted: Bool = false) {
        self.status = status
        self.createdAt = createdAt
        self.focusHandoffGrace = focusHandoffGrace
        self.systemPredicted = systemPredicted
    }
}

extension OptimisticWindowState {
    /// Cleared on sibling takeover (2026-08-22): the predicted .active is still unfulfilled while the
    /// snapshot has confirmed another window of the same app as .active. The sibling has taken focus, and
    /// keeping this prediction for the full 4 seconds would only plan the next click as minimize. macOS 26
    /// once silently disabled SkyLight make-key, and the mistaken minimizes came from exactly this kind of
    /// leftover; this defense stays so that if the focus channel silently fails again, the symptom degrades
    /// to a "redundant activate" instead of a "mistaken minimize". Clears .active predictions only:
    /// fulfillment of minimize / hidden (including disappeared) is independent of sibling state. Transition
    /// grace (2026-08-26, the former "restore grace" extended to minimize handoff): an .active prediction
    /// originating from a focus transition is not cleared by sibling takeover within this window. Measured in
    /// Finder: during the transition the app is already frontmost while focus still sits on a visible
    /// sibling, the snapshot briefly confirms the sibling as .active and knocks the prediction out within
    /// 10-530ms, and then every minimize click in the next ~1s is downgraded to an empty activate ("click
    /// does not minimize"). The 1.5s cap covers Finder's 887ms animation.
    static let handoffSupersessionGrace: TimeInterval = 1.5

    /// System prediction falsified (2026-08-26, measured in the Release storm): a handoff prediction can land
    /// on a window that is actually already minimized (snapshot lag + the window is still in the CG on-screen
    /// list during the minimize animation); that wrong .active survives with its grace and plans later
    /// wake-up clicks as minimize, failing repeatedly until the 4s timeout. A snapshot saying the window is
    /// minimized/hidden contradicts "about to become focused" -> clear immediately, and the click goes back
    /// to activate (= restore, which is what the user wants). **Clears system predictions only**: the user's
    /// own alternating "restore -> minimize again" state (optimistic .active + snapshot .minimized) is a
    /// normal in-flight state and must never be cleared.
    static func systemPredictionFalsified(state: OptimisticWindowState, actual: WindowStatus) -> Bool {
        guard state.systemPredicted, state.status == .active else { return false }
        return actual == .minimized || actual == .hidden
    }

    /// Full takeover-clearing decision (used by reconcile).
    ///
    /// A sibling's "confirmed .active" has an **in-flight discount**: when the sibling itself holds an
    /// in-flight optimistic .minimized / .hidden (the user just minimized/hid it), the .active in its
    /// snapshot is an afterimage contradicted by the user action and does not count as the focus successor.
    /// Otherwise, while minimizing window 1 is in flight, its active afterimage would immediately knock out
    /// the prediction just written for successor window 2.
    ///
    /// The grace exemption requires all of: the prediction carries `focusHandoffGrace`, the grace has not
    /// expired, and no sibling with the same pid holds an optimistic .active itself (if one does, the user
    /// really clicked the sibling's card, focus was really taken, and the prediction is cleared as usual,
    /// keeping the bottom line "rather a redundant activate than a wrong minimize").
    static func supersededByActiveSibling(
        windowID: String,
        state: OptimisticWindowState,
        now: Date,
        optimisticStates: [String: OptimisticWindowState],
        snapshot: DockSnapshot,
        handoffGraceEnabled: Bool
    ) -> Bool {
        guard state.status == .active else { return false }
        guard let record = snapshot.windows[WindowID(rawValue: windowID)] else { return false }
        let crediblyActiveSibling = snapshot.windows.values.contains { sibling in
            guard sibling.pid == record.pid, sibling.id != record.id, sibling.status == .active else {
                return false
            }
            let inFlight = optimisticStates[sibling.id.rawValue]?.status
            return inFlight != .minimized && inFlight != .hidden
        }
        guard crediblyActiveSibling else { return false }
        guard handoffGraceEnabled,
              state.focusHandoffGrace,
              now.timeIntervalSince(state.createdAt) <= Self.handoffSupersessionGrace
        else { return true }
        let siblingActivationClicked = optimisticStates.contains { key, sibling in
            guard key != windowID, sibling.status == .active else { return false }
            guard let siblingRecord = snapshot.windows[WindowID(rawValue: key)] else { return false }
            return siblingRecord.pid == record.pid
        }
        return siblingActivationClicked
    }

    /// Sibling activation in flight (2026-08-25): another window of the same app holds an optimistic .active
    /// not yet fulfilled by the snapshot. Focus is mid-handoff, and this window's "active" reading (snapshot
    /// or optimistic leftover) cannot be trusted: clicking back and forth quickly between two visible
    /// windows, a click on the background window used to minimize it by mistake (measured in Release, 6
    /// entries in click-latency of "snapshot inactive yet planned as minimize"). Used to downgrade the
    /// minimize decision in toggle planning (see LifecycleActionPlanner), same philosophy as the previous
    /// one: rather a redundant activate than a wrong minimize.
    static func siblingActivationInFlight(
        windowID: String,
        optimisticStates: [String: OptimisticWindowState],
        snapshot: DockSnapshot
    ) -> Bool {
        guard let record = snapshot.windows[WindowID(rawValue: windowID)] else { return false }
        let ownActivationCreatedAt: Date? = {
            guard let own = optimisticStates[windowID], own.status == .active else { return nil }
            return own.createdAt
        }()
        return optimisticStates.contains { key, state in
            guard key != windowID, state.status == .active else { return false }
            guard let sibling = snapshot.windows[WindowID(rawValue: key)] else { return false }
            guard sibling.pid == record.pid, sibling.status != .active else { return false }
            // Timing arbitration (2026-08-26, measured in Release batch restore): this window's own
            // optimistic .active is newer than the sibling's -> the user's latest activation intent landed on
            // this window, and the second click is a strict alternation on the same window (should minimize),
            // no downgrade; otherwise minimizing window by window after a batch restore is all squashed into
            // empty activates. The sibling's is newer (or this window has no optimistic state, only a
            // snapshot afterimage) -> focus is flowing to the sibling, keep the 08-25 downgrade, and the
            // mistaken-minimize bottom line holds.
            if let own = ownActivationCreatedAt, own > state.createdAt { return false }
            return true
        }
    }
}
