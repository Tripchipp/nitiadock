import Foundation

/// Pure decision for the unit set of multi-display taskbars (③④, 2026-09-02). The orchestration layer uses it
/// to decide which `PanelCoordinator` units to create / tear down. **Displays are tracked by display UUID,
/// never by `NSScreen.screens` index.**
enum TaskbarDisplaySet {
    struct Diff: Equatable {
        /// Same order as `current`.
        let added: [String]
        /// Same order as `previous`.
        let removed: [String]
        /// Same order as `current`.
        let kept: [String]
    }

    static func diff(previous: [String], current: [String]) -> Diff {
        let previousSet = Set(previous)
        let currentSet = Set(current)
        return Diff(
            added: current.filter { !previousSet.contains($0) },
            removed: previous.filter { !currentSet.contains($0) },
            kept: current.filter { previousSet.contains($0) }
        )
    }

    /// Unit keys that should exist: ①② exactly one "follow settings" unit (nil), ③④ one per present display.
    /// When `connectedKeys` is empty (all displays unplugged, or no UUID readable) it degrades to a single
    /// unit, so the taskbar never vanishes.
    static func desiredUnitKeys(placement: TaskbarScreenPlacement, connectedKeys: [String]) -> [String?] {
        guard placement.showsOnEveryDisplay, !connectedKeys.isEmpty else { return [nil] }
        return connectedKeys
    }
}
