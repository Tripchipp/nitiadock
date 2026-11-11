import AppKit
import Foundation

/// SkyLight private Space host for all our panels (taskbar / glass backplate / capsule, plus drawer / popover
/// / name bubble / drag carrier).
///
/// **Every window that can overlap the taskbar must be pinned in here.** Windows left in a desktop Space are
/// composited **below** this Space regardless of `level`: a drag carrier looks translucent once it presses
/// into the glass backplate, and the bottom row of the drawer darkens inside the capsule window's shadow edge
/// (confirmed 2026-09-03 by `DOCK_OVERLAY_SPACE=0` A/B). The first version of 2026-09-02 pinned only the
/// three permanent panels.
///
/// Why it is needed: when swiping between desktops WindowServer bakes the permanent `.canJoinAllSpaces`
/// panels into the transition snapshots of both desktops; the Liquid Glass backplate cannot sample what is
/// behind it in the snapshot and degrades to a solid dark gray (the frosted-glass path turns white),
/// recovering only on landing (screenshot 2026-09-02 + measured in `scratch/space_transition_lab`). The
/// system Dock is unaffected because it is not in any desktop Space at all. Move the panels into a Space we
/// create ourselves (`SLSSpaceCreate` →
/// `SLSSpaceSetAbsoluteLevel 0` → `SLSShowSpaces` → `SLSSpaceAddWindowsAndRemoveFromSpaces`),
/// and the panels stay as still as the Dock, with the material following the content beneath in real time.
///
/// Measured limits (`scratch/overlay_space_lab`, macOS 26.5.2, two displays):
/// - Clicks / enter events arrive as usual, before and after switching desktops;
/// - Both displays can **share one** Space, each panel shows only on the display its frame is on;
/// - `orderOut` -> `orderFrontRegardless` does **not** drop membership, nor does switching desktops, so
///   pinning once after a panel's first show is enough, and the re-pin on the show/hide path is just a cheap
///   readback;
/// - The private Space is **not readable** under `SLSCopySpacesForWindows` mask `0x7` (the mask the issue
///   #19 fix uses, which would take a pinned panel for "on no desktop" and repair it repeatedly), so readback
///   must use `0xF`; the return values of `SLSShowSpaces` / `SLSSpaceAddWindowsAndRemoveFromSpaces` are not
///   error codes (measured to return large integers), trust only the readback.
///
/// If any symbol is unavailable (older system / renamed by Apple), `make()` returns nil, the panels keep the
/// old `.canJoinAllSpaces` behavior and the issue #19 fix works as before. Switch: `DOCK_OVERLAY_SPACE=0`.
@MainActor
final class OverlaySpaceHost {
    static let isEnabled = DebugSwitch.overlaySpace.isEnabled(in: ProcessInfo.processInfo.environment)

    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias SpaceCreateFn = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SpaceDestroyFn = @convention(c) (Int32, UInt64) -> Int32
    private typealias SpaceSetAbsoluteLevelFn = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias SpaceListFn = @convention(c) (Int32, CFArray) -> Int32
    private typealias SpaceAddWindowsFn = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> CFArray?

    private struct Symbols {
        let cid: Int32
        let create: SpaceCreateFn
        let destroy: SpaceDestroyFn
        let setAbsoluteLevel: SpaceSetAbsoluteLevelFn
        let show: SpaceListFn
        let hide: SpaceListFn
        let addWindows: SpaceAddWindowsFn
        let copySpaces: CopySpacesForWindowsFn
    }

    private static let symbols: Symbols? = {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        ) else { return nil }
        func load<T>(_ name: String, as: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let cidFn = load("SLSMainConnectionID", as: MainConnectionIDFn.self),
              let create = load("SLSSpaceCreate", as: SpaceCreateFn.self),
              let destroy = load("SLSSpaceDestroy", as: SpaceDestroyFn.self),
              let setLevel = load("SLSSpaceSetAbsoluteLevel", as: SpaceSetAbsoluteLevelFn.self),
              let show = load("SLSShowSpaces", as: SpaceListFn.self),
              let hide = load("SLSHideSpaces", as: SpaceListFn.self),
              let addWindows = load("SLSSpaceAddWindowsAndRemoveFromSpaces", as: SpaceAddWindowsFn.self),
              let copySpaces = load("SLSCopySpacesForWindows", as: CopySpacesForWindowsFn.self)
        else { return nil }
        return Symbols(cid: cidFn(), create: create, destroy: destroy, setAbsoluteLevel: setLevel,
                       show: show, hide: hide, addWindows: addWindows, copySpaces: copySpaces)
    }()

    /// Returns nil when the switch is off or a symbol is missing: callers take the old behavior for "no
    /// host".
    static func make() -> OverlaySpaceHost? {
        guard isEnabled, symbols != nil else { return nil }
        return OverlaySpaceHost()
    }

    private init() {}

    private var spaceID: UInt64?

    /// Moves windows into the private Space. Windows already inside are skipped; returns whether all targets
    /// read back as actually in the Space. The Space is created on the first call, so a host that exists but
    /// is never used does not add a Space for nothing.
    @discardableResult
    func pin(windowNumbers: [Int]) -> Bool {
        guard let symbols = Self.symbols else { return false }
        let targets = windowNumbers.filter { $0 > 0 }
        guard !targets.isEmpty, let sid = ensureSpace(symbols) else { return false }
        let missing = targets.filter { !isPinned(windowNumber: $0) }
        guard !missing.isEmpty else { return true }
        // selector 0x7: remove from all Spaces the window belonged to (otherwise it also stays on every
        // desktop and still gets baked into the snapshot).
        _ = symbols.addWindows(symbols.cid, sid, missing.map { NSNumber(value: $0) } as CFArray, 0x7)
        return missing.allSatisfy { isPinned(windowNumber: $0) }
    }

    /// Readback: whether this window is in our private Space now. Unreadable / Space not created: false.
    func isPinned(windowNumber: Int) -> Bool {
        guard let sid = spaceID, windowNumber > 0, let symbols = Self.symbols,
              let raw = symbols.copySpaces(
                symbols.cid,
                0xF,
                [NSNumber(value: windowNumber)] as CFArray
              ) as? [NSNumber]
        else { return false }
        return raw.contains { $0.uint64Value == sid }
    }

    /// Tear down before exit. WindowServer reclaims it when the process dies; this just avoids leaving a
    /// garbage Space.
    func tearDown() {
        guard let sid = spaceID, let symbols = Self.symbols else { return }
        _ = symbols.hide(symbols.cid, [NSNumber(value: sid)] as CFArray)
        _ = symbols.destroy(symbols.cid, sid)
        spaceID = nil
    }

    private func ensureSpace(_ symbols: Symbols) -> UInt64? {
        if let spaceID { return spaceID }
        // type 1: the created Space measures as `SLSSpaceGetType` 3 (system level), and windows in it do not
        // take part in desktop transitions.
        let sid = symbols.create(symbols.cid, 1, nil)
        guard sid != 0 else { return nil }
        // Absolute level 0: same layer as the desktop, the window's own level (.floating) puts it above
        // normal windows.
        _ = symbols.setAbsoluteLevel(symbols.cid, sid, 0)
        _ = symbols.show(symbols.cid, [NSNumber(value: sid)] as CFArray)
        spaceID = sid
        return sid
    }
}
