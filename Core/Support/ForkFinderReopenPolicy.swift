import CoreGraphics
import Foundation

/// fork: when NitiaDock should open a window for a Finder that was just started from outside.
///
/// A Finder that was quit and is then opened from Spotlight or Raycast starts without a window and
/// only shows up as a Dock icon; the user has to click it again before anything appears. The real
/// Dock gets away with it because a click on its icon sends Finder a "reopen" event. NitiaDock
/// already opens the home folder when its own Finder card is clicked; this covers the launch that
/// does not come from the bar.
enum ForkFinderReopenPolicy {
    /// A Finder that is relaunched at login, or right after NitiaDock itself started, is not the user
    /// asking for a window, and Finder restores its own windows then.
    static let minimumAppUptime: TimeInterval = 15

    static func shouldOpenWindow(isActive: Bool, onScreenWindowCount: Int, secondsSinceAppStart: TimeInterval) -> Bool {
        isActive && onScreenWindowCount == 0 && secondsSinceAppStart >= minimumAppUptime
    }

    /// On-screen, normal-level windows of `pid` in a `CGWindowListCopyWindowInfo` result. The desktop
    /// window sits below normal level (and `.excludeDesktopElements` drops it as well); the menu bar
    /// and helper windows are other levels or tiny.
    static func onScreenWindowCount(in windowInfos: [[String: Any]], pid: pid_t) -> Int {
        windowInfos.filter { info in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue
            else { return false }
            return width >= 100 && height >= 100
        }.count
    }
}
