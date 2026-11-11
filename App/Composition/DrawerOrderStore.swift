import Foundation

/// Drawer display-order layer (drag reordering inside the drawer, 2026-06-21). The
/// drawer is **app-centric**: one icon per bundleID, order remembered permanently by
/// bundleID. bundleID is stable across restarts (unlike the taskbar's cgWindowID,
/// which is tied to a boot cycle), so drawer order is persisted unconditionally.
///
/// **Key invariant: order is recorded over the full placement set, not trimmed
/// to the visible icons.** A member that is not kept is hidden on quit, but its
/// placement and relative order stay, so it returns to its slot on next launch.
///
/// Same shape as `StripOrderStore` but simpler: no boot-cycle guard (bundleIDs are not reused) and no absence
/// grace (the member set is stable, unlike windows, which can blink out).
@MainActor
final class DrawerOrderStore: ObservableObject {
    @Published private(set) var order: [String] = []
    private let key = "drawerDisplayOrder"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        order = defaults.stringArray(forKey: key) ?? []
    }

    /// Display order = remembered order ∩ current full member set, new
    /// members appended at the end. Pure function, safe to read in body.
    func reconciled(members: [String]) -> [String] {
        let memberSet = Set(members)
        var result = order.filter { memberSet.contains($0) }
        let known = Set(result)
        for m in members where !known.contains(m) { result.append(m) }
        return result
    }

    /// Converges the persisted order when the full member set changes.
    /// **Call as a side effect, never during body evaluation.**
    func sync(members: [String]) {
        let next = reconciled(members: members)
        if next != order { order = next; persist() }
    }

    /// Mirrors MessagingAppStore.reorder: operate on the full persisted order so
    /// hidden placements keep their relative order while visible peers move.
    func reorder(draggedID: String, relativeTo targetID: String, after: Bool) {
        guard draggedID != targetID,
              let from = order.firstIndex(of: draggedID) else { return }
        var next = order
        next.remove(at: from)
        guard let target = next.firstIndex(of: targetID) else { return }
        next.insert(draggedID, at: after ? target + 1 : target)
        if next != order { order = next; persist() }
    }

    private func persist() {
        defaults.set(order, forKey: key)
    }
}
