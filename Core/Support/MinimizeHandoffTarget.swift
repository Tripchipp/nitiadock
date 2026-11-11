import CoreGraphics
import Foundation

/// Decides who gets the foreground before minimizing the frontmost window (2026-08-23).
///
/// Rule (decided 2026-08-02, implemented 2026-08-23): **whoever sits
/// right under the target is next, same-app windows included.**
/// Scan down the CG on-screen z-order from just after the target;
/// the first window **in the taskbar snapshot** is the answer:
/// - same pid -> `.siblingTakesOver`: do nothing, AppKit's native
///   promotion for the frontmost app is exactly that window;
/// - different pid -> `.switchTo`: hand the foreground to that app before
///   minimizing, so B is no longer the frontmost app and AppKit will not promote B2.
///
/// Only snapshot members count, **CG titles are not read**: `kCGWindowName` needs Screen
/// Recording permission, which the product never requests. The old implementation used it to
/// guard against "untitled invisible windows as handoff targets", and on installed builds
/// every candidate was blocked and the handoff never took effect (measured 2026-08-23).
/// Snapshot membership is the stronger guard: windows the taskbar has not adopted
/// (Feishu's invisible top-edge strip and the like) are not in the snapshot at all.
enum MinimizeHandoffTarget {
    struct ZOrderedWindow: Equatable {
        let pid: Int32
        let cgWindowID: CGWindowID
    }

    /// Both "has a successor" branches carry the successor window's snapshot identity (2026-08-26):
    /// the successor becomes focused right away, but the snapshot takes 0.5-1s to reflect it.
    /// Clicking the successor's card in that window was misjudged as "not focused" and planned as
    /// an empty activate ("after minimizing window 1, quickly clicking window 2 does not minimize
    /// it"). The identity goes to the optimistic layer to write an .active prediction.
    enum Verdict: Equatable {
        case switchTo(pid: Int32, cgWindowID: CGWindowID, windowID: WindowID)
        case siblingTakesOver(windowID: WindowID)
        case none
    }

    /// - Parameters:
    ///   - zOrder: CG on-screen layer-0 windows, front to back, own process already excluded.
    ///   - target: Record of the window about to be minimized.
    ///   - snapshot: Current taskbar snapshot.
    static func select(zOrder: [ZOrderedWindow], target: WindowRecord, snapshot: DockSnapshot) -> Verdict {
        var start = 0
        if let targetWID = target.cgWindowID,
           let index = zOrder.firstIndex(where: { $0.cgWindowID == targetWID }) {
            start = index + 1
        }
        var recordsByWID: [CGWindowID: WindowRecord] = [:]
        for record in snapshot.windows.values {
            guard let wid = record.cgWindowID, record.id != target.id else { continue }
            recordsByWID[wid] = record
        }
        for entry in zOrder[start...] {
            guard let record = recordsByWID[entry.cgWindowID] else { continue }
            guard record.status != .minimized, record.status != .hidden else { continue }
            if record.pid == target.pid {
                return .siblingTakesOver(windowID: record.id)
            }
            return .switchTo(pid: entry.pid, cgWindowID: entry.cgWindowID, windowID: record.id)
        }
        return .none
    }
}
