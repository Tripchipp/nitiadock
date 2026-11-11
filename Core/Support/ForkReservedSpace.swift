import CoreGraphics
import Foundation

/// fork: "Reserve screen space for the taskbar". Pure geometry and policy; the Accessibility
/// plumbing is `ForkReservedSpaceController`.
///
/// macOS has no public API to shrink a screen's `visibleFrame`, so the reservation is enforced
/// after the fact: a window whose bottom edge dips into the band the bar occupies is moved up, or,
/// when it is too tall to fit between the band and the menu bar, shrunk to fit.
///
/// The reserved band spans the **full width** of the screen, like a work area, not just the bar's
/// own rect. The bar is centred and changes width every time a window opens or closes; a rule tied
/// to its rect would make the same window legal or illegal depending on how many other windows
/// exist, and enforcement only runs on window events, so the two would drift apart.
///
/// All frames here are AppKit global coordinates (bottom-left origin), like `WindowLiftAvoidance`.
enum ForkReservedSpace {
    /// Same gap upstream leaves above the bar for a lifted maximized window.
    static let clearance: CGFloat = WindowLiftAvoidance.clearance
    /// A bottom edge this close to the band's top counts as clear (AX frames round to whole points).
    static let tolerance: CGFloat = 1
    /// Never shrink a window below this height; a screen with less room than this is left alone.
    static let minimumWindowHeight: CGFloat = 160

    enum Decision: Equatable {
        /// The window is not in the band.
        case clear
        /// Move the window up; its size is unchanged.
        case move(to: CGRect)
        /// The window is taller than the room above the band: pin its top under the menu bar and
        /// shrink it to fit.
        case resize(to: CGRect)
        case skip(SkipReason)

        var target: CGRect? {
            switch self {
            case let .move(frame), let .resize(frame): return frame
            case .clear, .skip: return nil
            }
        }
    }

    enum SkipReason: Equatable {
        case invalidGeometry
        /// Less than half of the window is on the bar's screen; it belongs to another display.
        case notOnThisScreen
        /// The window covers the whole screen frame (a full-screen-style window that AX does not
        /// report as full screen). Moving it would fight the app.
        case coversScreen
        /// There is not `minimumWindowHeight` of room between the band and the menu bar.
        case noRoom
    }

    static func decision(
        window: CGRect,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        barTop: CGFloat
    ) -> Decision {
        guard isValid(window), isValid(screenFrame), isValid(visibleFrame), barTop.isFinite else {
            return .skip(.invalidGeometry)
        }
        let overlap = window.intersection(screenFrame)
        guard !overlap.isNull, overlap.width * overlap.height >= window.width * window.height * 0.5 else {
            return .skip(.notOnThisScreen)
        }

        // The Dock may already reserve more than the bar does (a visible Dock at the bottom).
        let bandTop = max(barTop + clearance, visibleFrame.minY)
        guard window.minY < bandTop - tolerance else { return .clear }

        if abs(window.minX - screenFrame.minX) <= tolerance, abs(window.minY - screenFrame.minY) <= tolerance,
           abs(window.width - screenFrame.width) <= tolerance, abs(window.height - screenFrame.height) <= tolerance {
            return .skip(.coversScreen)
        }

        let ceiling = visibleFrame.maxY
        let room = ceiling - bandTop
        guard room >= minimumWindowHeight else { return .skip(.noRoom) }

        if window.height <= room + tolerance {
            // Fits: slide it up until the bottom edge sits on the band. The top cannot pass the
            // ceiling because height <= room.
            return .move(to: CGRect(x: window.minX, y: bandTop, width: window.width, height: window.height))
        }
        return .resize(to: CGRect(x: window.minX, y: bandTop, width: window.width, height: room))
    }

    private static func isValid(_ frame: CGRect) -> Bool {
        frame.minX.isFinite && frame.minY.isFinite && frame.width.isFinite && frame.height.isFinite
            && frame.width > 0 && frame.height > 0
    }

    // MARK: - Never fight the user (or the app)

    /// Remembers what was done to each window, to stop after two rounds.
    ///
    /// A **strike** is recorded when the window needs moving again within `fightWindow` of the last
    /// time we moved it, or when a move did not get it out of the band. Both mean somebody disagrees:
    /// the app put it back or clamps its size, or the user dragged it back down on purpose. Two
    /// strikes and the window is left alone until it is closed or the setting is toggled. A window
    /// that stays clear for longer than `fightWindow` starts again from zero.
    struct Ledger: Equatable {
        static let fightWindow: TimeInterval = 8
        static let maximumStrikes = 2

        struct Entry: Equatable {
            var strikes = 0
            var lastActionAt: TimeInterval
            var gaveUp = false
        }

        private(set) var entries: [WindowLiftAvoidance.WindowKey: Entry] = [:]

        /// Call when a window is found in the band, before acting. `false` = leave it alone.
        mutating func shouldAct(on key: WindowLiftAvoidance.WindowKey, now: TimeInterval) -> Bool {
            guard var entry = entries[key] else { return true }
            if entry.gaveUp { return false }
            if now - entry.lastActionAt <= Self.fightWindow {
                entry.strikes += 1
            } else {
                entry.strikes = 0
            }
            entry.gaveUp = entry.strikes >= Self.maximumStrikes
            entries[key] = entry
            return !entry.gaveUp
        }

        /// Call after acting. `cleared` = the window verifiably left the band.
        mutating func recordAction(on key: WindowLiftAvoidance.WindowKey, now: TimeInterval, cleared: Bool) {
            var entry = entries[key] ?? Entry(lastActionAt: now)
            entry.lastActionAt = now
            if !cleared { entry.strikes += 1 }
            entry.gaveUp = entry.strikes >= Self.maximumStrikes
            entries[key] = entry
        }

        func hasGivenUp(on key: WindowLiftAvoidance.WindowKey) -> Bool { entries[key]?.gaveUp ?? false }

        mutating func forget(pid: pid_t) { entries = entries.filter { $0.key.pid != pid } }
        mutating func reset() { entries = [:] }
    }
}
