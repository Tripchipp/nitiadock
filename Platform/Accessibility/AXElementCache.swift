import ApplicationServices
import CoreGraphics
import Foundation

/// Side cache for `pid + cgWindowID -> AXUIElement`.
///
/// **What it solves** (2026-08-11: "clicking a minimized window back is the slowest"): `AppTracker` reads the
/// full `AXWindows` in the background every 0.5s and on every AX event, so it **already holds** each window's
/// AX element; yet the action path asks the target app for the handle again on every click: the fast path is
/// capped at 100ms, and on a miss it falls to the full enumeration with a 500ms timeout. Minimized windows
/// hit the slow path especially often (neither focused nor main window, so the fast path must reach the full
/// `AXWindows` step), and a minimized app is often napping, which makes the AX query itself slow.
///
/// **Why not put it in `DockSnapshot` / `WindowRecord`**: equality of those two types gates taskbar rendering
/// (project rule: "`DockSnapshot` publications are equality-gated"). An `AXUIElement` that changes every
/// round would break the equality gate and re-render the whole taskbar every 0.5s, exactly the problem
/// `4120119` just fixed. Hence a side cache: not one snapshot field changes.
///
/// **Invalidation deliberately matches the seat release rules** (project rule):
/// - window destroyed (destroy notification) -> remove that entry
/// - process gone / app entry removed -> remove everything for that pid
/// - each reconcile intersects with the full CG list -> remove cgIDs CG no longer has
///
/// **Never remove just because "AX no longer returns it"**: Safari-family windows vanish from `AXWindows`
/// entirely once minimized (the premise of the phantom seat self-heal rule), and that is exactly when this
/// cache matters most: the element stored before minimizing still points at the same window and
/// `setMinimized(false)` can use it.
final class AXElementCache: @unchecked Sendable {
    static let shared = AXElementCache()

    /// `DOCK_AX_ELEMENT_CACHE=0` turns off the fastest tier and returns to the existing fast / fallback
    /// tiers.
    static let isEnabled = DebugSwitch.axElementCache.isEnabled(in: ProcessInfo.processInfo.environment)

    struct Key: Hashable {
        let pid: pid_t
        let cgWindowID: CGWindowID
    }

    private let lock = NSLock()
    private var elements: [Key: AXUIElement] = [:]

    init() {}

    func store(pid: pid_t, cgWindowID: CGWindowID, element: AXUIElement) {
        guard pid > 0, cgWindowID != 0 else { return }
        lock.lock()
        elements[Key(pid: pid, cgWindowID: cgWindowID)] = element
        lock.unlock()
    }

    func element(pid: pid_t, cgWindowID: CGWindowID) -> AXUIElement? {
        guard pid > 0, cgWindowID != 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return elements[Key(pid: pid, cgWindowID: cgWindowID)]
    }

    func remove(pid: pid_t, cgWindowID: CGWindowID) {
        lock.lock()
        elements.removeValue(forKey: Key(pid: pid, cgWindowID: cgWindowID))
        lock.unlock()
    }

    func removeAll(pid: pid_t) {
        lock.lock()
        elements = elements.filter { $0.key.pid != pid }
        lock.unlock()
    }

    /// Intersect with the full CG list: a window CG no longer has is really closed, so it leaves the cache.
    /// This is the gate against cgWindowID reuse, from the same hygiene rule as `formerCgIDs`.
    func retain(pid: pid_t, liveCGWindowIDs: Set<CGWindowID>) {
        lock.lock()
        elements = elements.filter { $0.key.pid != pid || liveCGWindowIDs.contains($0.key.cgWindowID) }
        lock.unlock()
    }

    #if DEBUG
    /// For unit tests: reads the current entry count directly.
    var countForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return elements.count
    }

    func containsForTesting(pid: pid_t, cgWindowID: CGWindowID) -> Bool {
        element(pid: pid, cgWindowID: cgWindowID) != nil
    }
    #endif
}

/// **Retention decision** for cache entries, extracted as a pure function for unit tests: a mistake in this
/// rule either leaves stale elements pointing at destroyed windows (possibly acting on the wrong window) or
/// wrongly removes windows that left AX when minimized (making the cache pointless).
enum AXElementCacheRetention {
    /// - Parameters:
    ///   - cachedCGWindowIDs: windows currently cached for this pid
    ///   - liveCGWindowIDs: the **full** CG list (not the on-screen set, not the AX list)
    /// - Returns: the windows to remove
    static func expired(
        cachedCGWindowIDs: Set<CGWindowID>,
        liveCGWindowIDs: Set<CGWindowID>
    ) -> Set<CGWindowID> {
        cachedCGWindowIDs.subtracting(liveCGWindowIDs)
    }
}
