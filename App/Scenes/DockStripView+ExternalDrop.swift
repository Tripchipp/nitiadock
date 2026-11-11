import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// DockStripView · External files dragged onto the taskbar: highlight, hover target, drop dispatch.
// Split out of DockStripView.swift as an extension on 2026-09-05, moved without changes.
extension DockStripView {
    /// Whole-bar highlight: serves **only** "external directory drag hovering the folder zone (pin)".
    ///
    /// **Dragging a drawer icon back to the taskbar no longer lights it** (2026-08-20, matching the native
    /// Dock): when an icon is dragged into the native Dock,
    /// the Dock itself gets no stroke or glow; all feedback is icons making room, and we already have that
    /// (`updateDrawerToStripConvert` converts the card as soon as it enters the taskbar and neighbors make
    /// room live), and its hit box is even larger than
    /// this highlight's hit box (exactly the visible bar rect), so the two carry fully redundant information.
    /// The external directory drag path has no make-room feedback; the whole-bar highlight is its only "can
    /// drop here" signal, so it stays.
    /// **The bar's edge does not change at all while an app is dragged in** (decided 2026-09-08).
    /// An app drag already has the make-room gap as feedback, so the whole-bar highlight is redundant, and it
    /// was the most conspicuous flickering surface.
    /// An edge that doesn't change with state can't flicker, and this doesn't depend on hover enter/exit
    /// being fully reset.
    /// The external **folder** pin drag path still lights up: it has no make-room feedback, and the whole-bar
    /// highlight is its only "can drop here" signal.
    var stripHighlighted: Bool {
        if case .pin = externalDropTarget { return true }
        return false
    }

    /// The three lifecycle entries of the external drop highlight + the watchdog. `externalDropTarget` is
    /// only changed in this group.
    /// dropEntered: a hover session begins -> lighting allowed.
    func externalDropHoverBegan(_ target: StripDropRouting.Target) {
        externalDropHoverActive = true
        // **Must be captured before the first gap insertion**, otherwise the frozen value is the one already
        // widened by the gap and the loop still holds.
        // This is the only starting point of the whole hover session, so the capture can only be here.
        if frozenStripWidth == nil, stripRootScreenRect != .zero {
            frozenStripWidth = stripRootScreenRect.width
        }
        setExternalDropTarget(target)
    }

    /// dropUpdated: only updates while a session is active; a stray dropUpdated the system sends after
    /// landing/exit (hoverActive=false) is ignored -> no re-flash.
    func externalDropHoverMoved(_ target: StripDropRouting.Target) {
        guard externalDropHoverActive else { return }
        setExternalDropTarget(target)
    }

    /// performDrop/dropExited: session ends -> clear the highlight at once, invalidate the watchdog, close
    /// the gate (cleared synchronously, off on landing, no tail).
    ///
    /// **The make-room gap is not cleared here**: `performDrop` also takes this path, and the real icon only
    /// enters the projection after `actionQueue` has resolved
    /// the bundleID; removing the gap in between would flash "gap closes -> icon pops in".
    /// The gap is cleared by `keepDroppedApplications` once the real icon is in place, with
    /// `armExternalDropGhostTimeout` as fallback.
    /// - Parameter isLanding: `true` is only passed by `performDrop`, the branch that keeps the gap for the
    ///   landing handoff.
    ///   All other endings (`dropExited`, shelf toggle change) pass `false`: no landing to hand off to, so
    ///   the gap must close on the spot,
    ///   otherwise the bar keeps an empty slot that never goes away.
    func externalDropHoverEnded(isLanding: Bool) {
        externalDropHoverActive = false
        externalDropGeneration &+= 1
        externalDropWatchdog?.invalidate()
        externalDropWatchdog = nil
        externalDropTarget = nil
        if isLanding, externalDropGhost != nil {
            // The handoff fallback is armed here rather than deep in the landing path: after this point
            // `performDrop` still has
            // several early returns (target is .none, no provider, empty URL, no app resolved at all),
            // none of which reaches landing. Armed here, every one of them self-heals within 1s.
            armExternalDropGhostTimeout()
        } else {
            // No gap to hand off (an ordinary file was dragged, or nothing made room) -> close at once,
            // **including unfreezing the bar width**.
            // Without this branch the bar width stays frozen at its hover-time value after a file drop lands.
            clearExternalDropGhost()
        }
    }

    /// Updates the make-room gap during hover. `bundleID == nil` (not an app drop / bundle id unreadable) ->
    /// close the gap.
    ///
    /// **Change gating is the reason this function exists**: `dropUpdated` is called every ~50ms, and one
    /// `@State` write
    /// recomputes the whole taskbar (measured: "46 whole-bar recomputes in a 1.2s drag"). If the anchor is
    /// unchanged, nothing is written.
    func updateExternalDropGhost(bundleID: String?, atX x: CGFloat) {
        // **The gate has the same source and reason as the whole-bar highlight's**: ~330ms after a successful
        // drop the system sends one stray
        // `dropUpdated`. Without this gate it would reopen the gap just closed on landing and also invalidate
        // the fallback Timer, leaving an empty slot on the bar that never goes away (measured 2026-09-08:
        // after dragging "Find" into the bar
        // an extra empty slot stayed on the right, even after removing "Find"). After the session ends the
        // gap may neither be reopened nor, while
        // it is being handed off, wiped, so this returns directly instead of clearing.
        guard externalDropHoverActive else { return }
        guard let bundleID else {
            if externalDropGhost != nil { clearExternalDropGhost() }
            return
        }
        // Landing decision is shared with drawer conversion (`StripBlockLanding`). The gap reports no card
        // frame, so `chipFrames`
        // holds only real cards, but their **positions** have already been pushed apart by the gap, so the
        // result is only stable when folded into an insertion index
        // (reason at `StripDropGhost`). Display order sorts by the frames' left edge, same source as render
        // order.
        let orderedLiveIDs = chipFrames.sorted { $0.value.minX < $1.value.minX }.map(\.key)
        let target = blockTarget(atX: x, excluding: [])
        let index = StripDropRouting.ghostInsertionIndex(orderedIDs: orderedLiveIDs,
                                                         targetID: target?.id,
                                                         after: target?.after ?? false)
        let next = StripDropGhost(bundleID: bundleID, insertIndex: index)
        guard next != externalDropGhost else { return }
        externalDropGhostTimeout?.invalidate()
        externalDropGhostTimeout = nil
        externalDropGhost = next
    }

    /// Arms a bounded fallback for the gap after landing: when the real icon should have entered the
    /// projection but didn't (broken bundle / canKeep fails /
    /// resolution failed), the gap must still go away on its own.
    func armExternalDropGhostTimeout() {
        guard externalDropGhost != nil else { return }
        externalDropGhostTimeout?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: false) { _ in
            clearExternalDropGhost()
        }
        RunLoop.main.add(timer, forMode: .common)
        externalDropGhostTimeout = timer
    }

    /// Unfreezes the bar width when the gap is removed. They share a lifetime: the landing branch waits for
    /// the real icon to enter the projection before unfreezing,
    /// so the bar grows cleanly to its final length once, instead of snapping back to the old width first.
    func clearExternalDropGhost() {
        externalDropGhostTimeout?.invalidate()
        externalDropGhostTimeout = nil
        externalDropGhost = nil
        frozenStripWidth = nil
    }

    /// Sets the drop target + resets the drop-end watchdog. During hover `dropUpdated` arrives every ~50ms
    /// and keeps pushing the 0.35s Timer back
    /// -> neither moving nor stationary hover clears by mistake; once the drop ends without an ending
    /// callback (dropUpdated stops), the Timer fires and clears the leftover highlight.
    /// Clears only if generation still matches, so an already queued old Timer can't clear a new drop. Only
    /// touches `externalDropTarget`, not the drawer unstash highlight.
    func setExternalDropTarget(_ target: StripDropRouting.Target) {
        externalDropTarget = target
        externalDropGeneration &+= 1
        externalDropWatchdog?.invalidate()
        let gen = externalDropGeneration
        let timer = Timer(timeInterval: 0.35, repeats: false) { _ in
            guard externalDropGeneration == gen else { return }
            externalDropHoverActive = false
            externalDropTarget = nil
            externalDropWatchdog = nil
            // This is the "drop ended without a single ending callback" path. The session is dead,
            // so the gap and the frozen bar width must go with it, otherwise the bar stays stuck at its
            // hover-time width.
            clearExternalDropGhost()
        }
        RunLoop.main.add(timer, forMode: .common)
        externalDropWatchdog = timer
    }

    /// External drop landing (called on the main thread after the DropDelegate has gathered the URLs
    /// asynchronously).
    /// The shelf accepts everything; a hit chip moves into it; gap / tail pinning accepts directories only.
    ///
    /// **`urls` never contains an app bundle**: `StripFileDropDelegate` has already diverted those to
    /// `handleExternalApplicationDrop`, and `.keepApp` never gets here either.
    func handleExternalDrop(_ target: StripDropRouting.Target, urls: [URL]) {
        switch target {
        case .trash:
            let files = urls.filter { !StripFileDropDelegate.DragPasteboardInspector.isApplication($0) }
            trashStore.trash(files)
        case .stash:
            shelfStore.stash(paths: urls.map(\.path))
        case .moveInto(let path):
            // The second gate guards this branch too: this is a real file move (move within a volume, copy
            // across volumes), and letting one
            // app through means moving it out of "Applications". The diverting gate is in
            // `StripFileDropDelegate`.
            let files = urls.filter { !StripFileDropDelegate.DragPasteboardInspector.isApplication($0) }
            guard !files.isEmpty else { break }
            onMoveExternalFiles(files, path)
        case .pin(let insertIndex):
            var index = insertIndex
            for url in urls where isPinnableDirectory(url) {
                pinnedFolderStore.insert(url.path, at: index)
                index += 1
            }
        case .keepApp, .none:
            break
        }
    }

    /// Dragging an app from Finder onto the taskbar: checks "Keep in Dock" + lands it at the cursor position
    /// (2026-09-07).
    /// Semantics parallel "dragging into the drawer also checks Keep": only handles entering, not
    /// leaving, and re-checks on every drag-in,
    /// so dragging an already kept app again = changing its position, not an error.
    ///
    /// - Parameter x: landing x ("strip" space); the landing decision shares `StripBlockLanding` with drawer
    ///   conversion.
    func handleExternalApplicationDrop(_ urls: [URL], atX x: CGFloat) {
        let paths = urls.map(\.path)
        // Reading Info.plist is disk I/O. Hard rule: user actions go through `actionQueue`, neither
        // `Task.detached`
        // nor the Swift cooperative pool (AppTracker's blocking AX reads run there).
        AppRuntime.actionQueue.async {
            let bundleIDs = paths.compactMap { path in
                Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier
            }
            DispatchQueue.main.async {
                // Broken bundle / no Info.plist -> silently ignored, but the gap must close at once (before
                // the fallback Timer).
                guard !bundleIDs.isEmpty else { return clearExternalDropGhost() }
                keepDroppedApplications(bundleIDs, atX: x)
            }
        }
    }

    /// Checks Keep + lands each one. The second and later apps land to the right of the previous one, keeping
    /// the drag-in order.
    private func keepDroppedApplications(_ bundleIDs: [String], atX x: CGFloat) {
        // The gap is removed only in the last statement: the landing is computed with it as the anchor, and
        // removing it early makes `blockTarget` count back
        // the width it made room for, so the icon lands next door.
        defer { clearExternalDropGhost() }
        var previousAnchor: (id: String, after: Bool)?
        for bundleID in bundleIDs where keptAppStore.canKeep(bundleID) {
            // Landing: when the dragged item is its own existing card, exclude itself, otherwise the whole
            // block anchors on itself and stays put.
            let ownIDs = Set(freshProjection().liveEntryIDs(bundleID: bundleID))
            let target = previousAnchor ?? blockTarget(atX: x, excluding: ownIDs)
            stripOrderStore.stageExternalBlock(bundleID: bundleID,
                                               relativeTo: target?.id,
                                               after: target?.after ?? false)
            appMembershipController.setKept(bundleID, enabled: true)
            // Run one sync **synchronously** to consume the landing block just staged. Can't wait for
            // `onChange(of: keptAppStore.bundleIDs)`:
            // when that pass runs is undetermined; committing first drops the staging (icon lands at the
            // end), and not committing makes every later
            // sync move this block again, overriding the user's later manual reorders.
            reconcileLiveOrder(freshProjection())
            stripOrderStore.commitExternalBlock()
            // Several apps in one drag: the next lands to the right of this one, keeping the drag-in order.
            // The anchor is taken from the post-landing projection
            // (a running app has no `app-<bid>` placeholder card, only window cards, so a hand-built
            // placeholder id would anchor to a chip that doesn't exist).
            let landed = freshProjection().liveEntryIDs(bundleID: bundleID).last
            previousAnchor = (landed ?? "app-\(bundleID)", true)
        }
    }

    /// Whether it can be pinned as a folder tile. **An app bundle is a directory in the file system**, so
    /// checking only `isDirectoryKey`
    /// would pin an app as a tile that expands the inside of the `.app`; that was a real bug before 2026-09-07.
    /// The diverting gate is in `StripFileDropDelegate`; this is the second one: `.moveInto` is a real file
    /// move
    /// (move within a volume, copy across volumes), and anything that slips through would move the user's app
    /// out of "Applications".
    private func isPinnableDirectory(_ url: URL) -> Bool {
        guard !StripFileDropDelegate.DragPasteboardInspector.isApplication(url) else { return false }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
    }
}
