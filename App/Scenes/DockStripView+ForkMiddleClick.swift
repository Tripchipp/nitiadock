import AppKit
import SwiftUI

// fork: middle-click on a Finder or browser card opens a window / closes the clicked one.
extension DockStripView {
    /// Anything that is not a Finder or browser card falls through to upstream's middle-click, the
    /// content preview for pinned folders. (Finder's window preview stays on force-click.)
    func forkHandleMiddleClick(atScreen global: CGPoint) {
        if settingsStore.middleClickActions,
           let p = stripPoint(from: global),
           let (cid, _) = chipFrames.first(where: { $0.value.contains(p) }) {
            let items = StripItem.items(from: runtime.snapshot)
            if let item = items.first(where: { $0.id == cid }) {
                let windowCount = items.filter {
                    $0.bundleIdentifier == item.bundleIdentifier && !$0.isAppLevelFallback
                }.count
                switch ForkMiddleClickPolicy.action(
                    enabled: true,
                    bundleID: item.bundleIdentifier,
                    isAppLevelFallback: item.isAppLevelFallback,
                    appWindowCount: windowCount
                ) {
                case .newWindow:
                    runtime.newWindow(windowID: item.actionWindowID)
                    return
                case .closeWindow:
                    for windowID in item.memberWindowIDs { runtime.close(windowID: windowID) }
                    return
                case .fallThrough:
                    break
                }
            }
        }
        handleGesturePreview(atScreen: global)
    }
}
