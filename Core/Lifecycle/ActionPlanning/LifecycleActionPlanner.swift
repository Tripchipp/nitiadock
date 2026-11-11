import AppKit
import Foundation

enum UserIntentAction: String, Hashable, Sendable {
    case toggle
    case activate
    case minimize
    case hide
    case close
    case quit
    case newWindow
}

enum UserIntent: Hashable, Sendable {
    case toggle(WindowID)
    case activate(WindowID)
    case minimize(WindowID)
    case hide(WindowID)
    case close(WindowID)
    case quit(WindowID)
    case newWindow(WindowID)

    var windowID: WindowID {
        switch self {
        case let .toggle(id), let .activate(id), let .minimize(id), let .hide(id), let .close(id), let .quit(id), let .newWindow(id):
            return id
        }
    }

    var action: UserIntentAction {
        switch self {
        case .toggle:
            return .toggle
        case .activate:
            return .activate
        case .minimize:
            return .minimize
        case .hide:
            return .hide
        case .close:
            return .close
        case .quit:
            return .quit
        case .newWindow:
            return .newWindow
        }
    }
}

final class LifecycleActionPlanner {
    /// Frontmost-axis check; default = an immediate isActive read on a freshly created NSRunningApplication
    /// instance (measured to flip right after a SkyLight switch; tests inject a
    /// stub).
    private let isAppFrontmost: (pid_t) -> Bool
    /// Kill switch for the stale-active guardrail (on by default). Off restores the old rule
    /// "snapshot/optimistic active + frontmost = minimize".
    private static let staleActiveGuardEnabled =
        DebugSwitch.staleActiveGuard.isEnabled(in: ProcessInfo.processInfo.environment)

    init(isAppFrontmost: @escaping (pid_t) -> Bool = {
        NSRunningApplication(processIdentifier: $0)?.isActive == true
    }) {
        self.isAppFrontmost = isAppFrontmost
    }

    func plan(
        intent: UserIntent,
        snapshot: DockSnapshot,
        optimisticStates: [String: OptimisticWindowState] = [:]
    ) -> PlatformActionRequest {
        switch intent {
        case let .toggle(id):
            guard let record = snapshot.windows[id] else {
                return PlatformActionRequest(kind: .activateWindow, windowID: id)
            }
            // Optimistic state first (status axis only): when the previous action was just sent and the
            // snapshot has not flipped yet, plan from the predicted state, so repeated clicks alternate
            // strictly (minimize -> activate -> ...) instead of repeating the previous action.
            let optimistic = optimisticStates[id.rawValue]
            let status = optimistic?.status ?? record.status
            // The frontmost axis is always read live and must never be overridden by optimistic state
            // (2026-07-05): an optimistic isAppFrontmost=true lingered when the user switched to another app
            // within 4s of activating and then clicked the card again (the snapshot never delivers the
            // .active that would fulfill it), and a click that should activate was planned as minimize. The
            // live read is always correct anyway.
            let appIsFrontmost = isAppFrontmost(record.pid)
            if record.id.rawValue.hasPrefix("app-") {
                // Finder persistent chip: never hide, always open/focus to match system Dock behavior.
                if FinderTaskbarPolicy.isFinder(record.bundleIdentifier) {
                    return PlatformActionRequest(kind: .activateWindow, windowID: id)
                }
                return PlatformActionRequest(kind: appIsFrontmost ? .hideApp : .activateWindow, windowID: id)
            }
            if status == .active && appIsFrontmost {
                // Stale-active guardrail (2026-08-25): while a sibling window's activation is in flight
                // (optimistic .active unfulfilled), this window's active reading is most likely an afterimage
                // of focus handoff lag. Clicking back and forth quickly between two visible windows, a click
                // on the background window used to minimize it by mistake. Downgraded to a redundant
                // activate, same philosophy as supersededByActiveSibling; once the sibling is fulfilled or
                // the 4s timeout clears the optimistic state, the rule restores itself, and alternating
                // clicks on one window are unaffected.
                if Self.staleActiveGuardEnabled,
                   OptimisticWindowState.siblingActivationInFlight(
                       windowID: id.rawValue, optimisticStates: optimisticStates, snapshot: snapshot
                   ) {
                    return PlatformActionRequest(kind: .activateWindow, windowID: id)
                }
                return PlatformActionRequest(kind: .minimizeWindow, windowID: id)
            }
            return PlatformActionRequest(kind: .activateWindow, windowID: id)
        case let .activate(id):
            return PlatformActionRequest(kind: .activateWindow, windowID: id)
        case let .minimize(id):
            return PlatformActionRequest(kind: .minimizeWindow, windowID: id)
        case let .hide(id):
            return PlatformActionRequest(kind: .hideApp, windowID: id)
        case let .close(id):
            return PlatformActionRequest(kind: .closeWindow, windowID: id)
        case let .quit(id):
            return PlatformActionRequest(kind: .quitApp, windowID: id)
        case let .newWindow(id):
            return PlatformActionRequest(kind: .newWindow, windowID: id)
        }
    }
}
