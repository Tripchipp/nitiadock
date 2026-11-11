import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// DockStripView · Click / gesture actions: folders, shelf, content preview, messaging app fallback.
// Split out of DockStripView.swift as an extension on 2026-09-05, moved without changes.
/// Finder previews run one at a time: `NSAppleScript` is not thread-safe, and the consent prompt
/// must not be asked twice at once.
private let finderPreviewQueue = DispatchQueue(label: "no.thilip.nitiadock.finder-preview", qos: .userInitiated)

extension DockStripView {
    /// Kept launcher uses the same shared membership projection (strip surface).
    func keptAppMembershipItems(bundleID: String) -> [LauncherMembershipItem] {
        LauncherMembershipItem.items(
            surface: .strip,
            bundleID: bundleID,
            isKept: keptAppStore.contains(bundleID),
            isMessaging: messagingStore.contains(bundleID),
            controller: appMembershipController
        )
    }

    /// Single entry for left-click on a pinned folder: dispatches by `FolderInteraction.primaryAction`
    /// (currently fixed = content preview).
    /// The A/B "left-click previews vs left-click opens Finder" only changes the policy enum, not this call
    /// site.
    func folderPrimaryTap(_ path: String) {
        switch FolderInteraction.primaryAction {
        case .openFinderWindow: openFolderInFinder(path)
        case .preview: folderShowPreview(path)
        }
    }

    /// Opens a Finder window for the path (best-effort; shared by left-click and the "Open in Finder" context
    /// menu item).
    func openFolderInFinder(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// Single entry for pinned folder content preview (the preview branch of the left-click A/B, the "Preview
    /// Contents" context menu item, and later middle-click / force click all go through it).
    /// Converts a "strip"-space frame (top-left, y-down) to screen coordinates (bottom-left) for the popup.
    /// Mirrors the inverse mapping of stripPoint(from:). If the frame isn't ready (first frame) nothing pops
    /// up; the next trigger will.
    func folderShowPreview(_ path: String) {
        let entryID = StripEntry.pinnedFolder(path: path).id
        guard let frame = folderChipFrames[entryID], stripRootScreenRect != .zero else { return }
        let screenRect = CGRect(
            x: stripRootScreenRect.minX + frame.minX,
            y: stripRootScreenRect.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
        onFolderPopupToggle(path, screenRect)
    }

    /// strip-space frame -> screen rect (inverse of stripPoint(from:); for popup anchors).
    func stripFrameToScreen(_ frame: CGRect) -> CGRect {
        CGRect(x: stripRootScreenRect.minX + frame.minX,
               y: stripRootScreenRect.maxY - frame.maxY,
               width: frame.width, height: frame.height)
    }

    /// Gesture (force click / middle-click) hit callback: global screen coordinates -> strip space -> hit a
    /// pinned folder / a concrete Finder window -> preview.
    /// Silently ignored when no previewable chip is hit.
    func handleGesturePreview(atScreen global: CGPoint) {
        guard let p = stripPoint(from: global) else { return }
        for path in pinnedFolderStore.folderPaths {
            let entryID = StripEntry.pinnedFolder(path: path).id
            if let frame = folderChipFrames[entryID], frame.contains(p) {
                onFolderPopupToggle(path, stripFrameToScreen(frame))
                return
            }
        }
        for (cid, frame) in chipFrames where frame.contains(p) {
            guard let item = StripItem.items(from: runtime.snapshot).first(where: { $0.id == cid }),
                  FinderTaskbarPolicy.isFinder(item.bundleIdentifier), item.isAppLevelFallback == false else { return }
            chipPulseNonces[cid, default: 0] += 1   // instant "got the click" feedback, covers the ~200ms reverse lookup
            previewFinderWindow(item, anchor: stripFrameToScreen(frame))
            return
        }
    }

    /// Concrete Finder window -> reverse-look up the path -> preview. AX lookup + permission flow run on the
    /// main thread, AppleEvents enumeration in the background,
    /// and on success the preview opens back on the main thread; permission denied / no unique match /
    /// timeout -> beep + log, no empty window (verified in a spike).
    private func previewFinderWindow(_ item: StripItem, anchor: CGRect) {
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "no.thilip.nitiadock", category: "FinderWindowPreview")
        let ref = FinderWindowReference(pid: item.pid, cgWindowID: item.cgWindowID, title: item.title, bounds: item.bounds)
        let reader = FinderWindowContentsReader()
        let onToggle = onFolderPopupToggle

        func resolveViaAppleEvents(_ aeTarget: FinderWindowAppleEventsTarget) {
            finderPreviewQueue.async {
                do {
                    let url = try FinderWindowContentsReader.folderURLViaAppleEvents(for: aeTarget)
                    DispatchQueue.main.async { onToggle(url.path, anchor) }
                } catch {
                    logger.error("finder-window-preview AppleEvents failed: \(String(describing: error), privacy: .public)")
                    DispatchQueue.main.async { NSSound.beep() }
                }
            }
        }
        // A minimized window can't be located in AX by cgWindowID (missing / mismatched) -> use the
        // title+frame carried by StripItem
        // for an AppleEvents unique match directly (AppleScript's `Finder windows` includes minimized windows
        // and reports restored-state bounds).
        func resolveFromItem() {
            guard let bounds = item.bounds else { NSSound.beep(); return }
            resolveViaAppleEvents(FinderWindowAppleEventsTarget(title: item.title, cocoaFrame: bounds))
        }

        do {
            switch try reader.target(for: ref) {
            case .folderURL(let url):
                onToggle(url.path, anchor)
            case .appleEvents(let aeTarget):
                resolveViaAppleEvents(aeTarget)
            }
        } catch FinderWindowContentsError.windowNotFound {
            resolveFromItem()
        } catch FinderWindowContentsError.missingWindowID {
            resolveFromItem()
        } catch FinderWindowContentsError.automationPermissionRequired {
            // The consent prompt blocks its caller until the user answers; off the main thread so
            // the bar stays alive meanwhile.
            finderPreviewQueue.async {
                let granted = FinderWindowContentsReader.requestFinderAutomationPermission()
                DispatchQueue.main.async {
                    if granted { resolveFromItem() } else { NSSound.beep() }
                }
            }
        } catch {
            logger.error("finder-window-preview target failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
        }
    }

    /// Shelf click: same coordinate conversion as folderShowPreview, anchored on the separate shelfFrame.
    func shelfChipTapped() {
        guard shelfFrame != .zero, stripRootScreenRect != .zero else { return }
        let screenRect = CGRect(
            x: stripRootScreenRect.minX + shelfFrame.minX,
            y: stripRootScreenRect.maxY - shelfFrame.maxY,
            width: shelfFrame.width,
            height: shelfFrame.height
        )
        onShelfPopupToggle(screenRect)
    }

    /// Dock-icon-click equivalent: unhide + reopen. The app recreates its main window
    /// even when other windows are visible (verified with WeChat, 2026-06-12).
    /// Left-click when the message-zone icon **can't identify the main window** (fallback rule 3, 2026-08-23):
    /// - the app has no real window at all -> bring back the main window (the daily "close main window ->
    ///   click the icon to bring it back" flow must not change);
    /// - it has windows but the main one can't be identified -> **toggle the whole app**: hide it if
    ///   frontmost, otherwise bring it to the front. The icon always
    ///   responds, at the cost of standalone chat windows hiding too, which beats the previous "can only
    ///   summon, never hide". The logic reuses the drawer icon's
    ///   `LauncherChip.performDefaultTap` instead of copying "hide if frontmost, otherwise summon" again.
    static func messagingFallbackTap(bundleID: String, hasRealWindow: Bool) {
        guard hasRealWindow else {
            reopenMainWindow(bundleID: bundleID)
            return
        }
        LauncherChip.performDefaultTap(bundleID: bundleID, isRunning: true,
                                       finderHasRealWindow: false,   // Finder can't enter the message zone
                                       launch: {}, onOpen: nil)
    }

    static func reopenMainWindow(bundleID: String) {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter {
                $0.activationPolicy == .regular
                    && ProcessLiveness.isAlive(pid: $0.processIdentifier)
            }
        for app in runningApps { _ = app.unhide() }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
    }
}
