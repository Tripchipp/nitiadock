import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

// PanelCoordinator · Folder / shelf popup: single-panel reuse, open/close animation, click-away monitoring.
// Split out of PanelCoordinator.swift as an extension on 2026-09-05, moved without changes.
/// Numeric solver version of CAMediaTimingFunction: CALayer implicit animations can only interpolate a
/// "single property" as a whole, while a popup switch has to interpolate the four semantic quantities
/// centerX/bottomY/width/height separately and reassemble the frame, so progress has to be computed by
/// stepping time ourselves. Takes the caller's existing CAMediaTimingFunction directly instead of redefining
/// control points (the two call sites use different curves: PopoverAnimation.curve() and .easeInEaseOut).
/// Same as WebKit's UnitBezier: Newton iteration solves x(t)=elapsed, then y(t) is the eased progress, with
/// bisection as fallback when the iteration does not converge.
private struct UnitBezierEase {
    private let ax, bx, cx: Double
    private let ay, by, cy: Double

    init(_ timingFunction: CAMediaTimingFunction) {
        var p1 = [Float](repeating: 0, count: 2)
        var p2 = [Float](repeating: 0, count: 2)
        timingFunction.getControlPoint(at: 1, values: &p1)
        timingFunction.getControlPoint(at: 2, values: &p2)
        let (p1x, p1y, p2x, p2y) = (Double(p1[0]), Double(p1[1]), Double(p2[0]), Double(p2[1]))
        cx = 3 * p1x; bx = 3 * (p2x - p1x) - cx; ax = 1 - cx - bx
        cy = 3 * p1y; by = 3 * (p2y - p1y) - cy; ay = 1 - cy - by
    }

    private func sampleX(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
    private func sampleY(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
    private func sampleDX(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }

    private func solveX(_ x: Double) -> Double {
        var t = x
        for _ in 0..<8 {
            let dx = sampleX(t) - x
            if abs(dx) < 1e-6 { return t }
            let d = sampleDX(t)
            if abs(d) < 1e-6 { break }
            t -= dx / d
        }
        var lo = 0.0, hi = 1.0
        t = x
        while lo < hi {
            let cur = sampleX(t)
            if abs(cur - x) < 1e-6 { return t }
            if x > cur { lo = t } else { hi = t }
            t = (hi - lo) / 2 + lo
        }
        return t
    }

    func progress(at t: Double) -> Double { sampleY(solveX(t)) }
}

extension PanelCoordinator {
    // MARK: - Folder/Trash popup (clones the drawer template: lazy panel + plain container wrapping hosting + fade in/out + click-away monitor)

    /// Chip click entry point: clicking the same folder again = dismiss; another folder = instant target
    /// switch. anchorVisibleRect is the chip's visible rect (screen coordinates).
    func toggleFolderPopup(path: String, anchorVisibleRect: CGRect) {
        if folderPopupWantsOpen, openPopupContent == .folder(path: path) {
            closeFolderPopup()
        } else {
            openFolderPopup(path: path, anchorVisibleRect: anchorVisibleRect)
        }
    }

    /// Shelf click entry point: clicking again = dismiss; coming from a folder popup = switch in place (same
    /// single-panel semantics).
    func toggleShelfPopup(anchorVisibleRect: CGRect) {
        if folderPopupWantsOpen, openPopupContent == .shelf {
            closeFolderPopup()
        } else {
            openShelfPopup(anchorVisibleRect: anchorVisibleRect)
        }
    }

    private func openFolderPopup(path: String, anchorVisibleRect: CGRect) {
        let rootURL = URL(fileURLWithPath: path)
        let sortOrder = pinnedFolderStore.sortOrder(for: path)
        // Hybrid fallback: check the hot cache first (0ms, with sort consistency verified); on a miss fall
        // back to a short preload (blocks at most 150ms) so the first frame is complete.
        let preloadedEntries = folderCoverStore.cachedEntries(for: path, order: sortOrder)
            ?? FolderContentsLoader.preload(url: rootURL, timeout: 0.15, order: sortOrder)
        // A complete first frame **includes icons**: prewarm the icon cache for the first batch of visible
        // cells (8 columns × grid height cap ≈ 40 cells, 48 for headroom), otherwise cells show first and
        // icons appear one by one from the top-left in resolve order (real cause of the 2026-07-07 "appears
        // from the top-left" report).
        if let entries = preloadedEntries {
            FolderIconResolver.warm(paths: entries.prefix(48).map(\.url.path), timeout: 0.1)
        }

        presentPopup(content: .folder(path: path), anchorVisibleRect: anchorVisibleRect) { [weak self] maxContentHeight in
            NSHostingView(rootView: FolderGridPopupView(
                rootURL: rootURL,
                initialEntries: preloadedEntries,
                sortOrder: sortOrder,
                maxContentHeight: maxContentHeight,
                usesLiquidGlass: usesLiquidGlass,
                onFileOpened: { [weak self] in self?.closeFolderPopup() },
                onContentResize: { [weak self] in self?.repositionFolderPopup(animated: true) },
                onPinFolder: { [weak self] url in self?.pinnedFolderStore.add(url.path) },
                isFolderPinned: { [weak self] url in self?.pinnedFolderStore.contains(url.path) ?? true }
            ))
        }
    }

    private func openShelfPopup(anchorVisibleRect: CGRect) {
        shelfStore.prune()   // on open, prune references that are no longer valid (file moved/deleted)
        // Same as openFolderPopup: all icons present on the first frame, not appearing one by one.
        FolderIconResolver.warm(paths: Array(shelfStore.itemPaths.prefix(48)), timeout: 0.1)

        presentPopup(content: .shelf, anchorVisibleRect: anchorVisibleRect) { [weak self, shelfStore] maxContentHeight in
            NSHostingView(rootView: ShelfGridPopupView(
                shelfStore: shelfStore,
                maxContentHeight: maxContentHeight,
                usesLiquidGlass: usesLiquidGlass,
                onClosePopup: { [weak self] in self?.closeFolderPopup() },
                onContentResize: { [weak self] in self?.repositionFolderPopup(animated: true) },
                onPinFolder: { [weak self] url in self?.pinnedFolderStore.add(url.path) },
                isFolderPinned: { [weak self] url in self?.pinnedFolderStore.contains(url.path) ?? true }
            ))
        }
    }

    /// Shared popup presentation path (folder/shelf use the same panel, animations and monitors). Content is
    /// built by makeHosting (argument = max available grid height); callers do their own preloading first
    /// (complete first frame, project rule).
    func toggleTrashPopup(anchorVisibleRect: CGRect) {
        if folderPopupWantsOpen, openPopupContent == .trash {
            closeFolderPopup()
        } else {
            openTrashPopup(anchorVisibleRect: anchorVisibleRect)
        }
    }

    /// Opens on whatever listing the store still holds and refreshes from Finder behind it: a loaded
    /// Finder answers the listing in ~1s, far too long to hold the first frame for.
    private func openTrashPopup(anchorVisibleRect: CGRect) {
        let store = TrashStateStore.shared
        presentPopup(content: .trash, anchorVisibleRect: anchorVisibleRect) { [weak self, runtime] maxContentHeight in
            NSHostingView(rootView: TrashGridPopupView(
                trashStore: store,
                maxContentHeight: maxContentHeight,
                usesLiquidGlass: usesLiquidGlass,
                onClosePopup: { [weak self] in self?.closeFolderPopup() },
                onContentResize: { [weak self] in self?.repositionFolderPopup(animated: true) },
                onOpenInFinder: { [weak self] in
                    self?.closeFolderPopup()
                    TrashStateStore.openTrashWindow(runtime: runtime, store: store)
                }
            ))
        }
        // After presenting: the popup that just went away cleared the listing (see
        // `clearTrashListingIfShowing`), and the view's own `onDisappear` would fire too late
        // (the old hosting view dies only when this one replaces it) and cancel this load.
        store.loadItems()
    }

    /// The Trash listing lives exactly as long as the Trash popup shows; every way the popup
    /// stops showing Trash content passes through here.
    private func clearTrashListingIfShowing() {
        if openPopupContent == .trash { TrashStateStore.shared.clearListing() }
    }

    private func presentPopup(content: PopupContent, anchorVisibleRect: CGRect, makeHosting: (CGFloat) -> NSView) {
        guard let mainPanel = dockPanel else { return }
        onAccessoryWillOpen?(self, .popup)
        // Interruptible: swapping content while the panel is visible **switches in place**, with no orderOut
        // (eliminates the black blink); only the old monitors are removed (reinstalled right after), content
        // swaps instantly and the frame slides to the new target. Only mid fade-out / not open takes the
        // close path.
        let isSwitching = folderPopupWantsOpen && (folderPopupPanel?.isVisible ?? false)
        if folderPopupWantsOpen {
            if isSwitching {
                if let m = popupLocalMonitor  { NSEvent.removeMonitor(m); popupLocalMonitor  = nil }
                if let m = popupGlobalMonitor { NSEvent.removeMonitor(m); popupGlobalMonitor = nil }
            } else {
                closeFolderPopup(immediately: true)
            }
        }

        if folderPopupPanel == nil {
            let panel = makeFloatingPanel(
                contentRect: NSRect(origin: .zero, size: lastPopupSize),
                usesLiquidGlass: usesLiquidGlass
            )
            configurePanel(panel, backgroundColor: NSColor(white: 1.0, alpha: 0.0), appliesLevelOverride: false)
            folderPopupPanel = panel
        }
        guard let panel = folderPopupPanel else { return }

        let screen = panelCurrentScreen(panel: mainPanel)
        let screenGeometry = Self.screenGeometry(screen)
        let maxContentHeight = PanelGeometry.maxFolderPopupContentHeight(
            anchorVisibleRect: anchorVisibleRect, on: screenGeometry, metrics: layoutMetrics)

        let hosting = makeHosting(maxContentHeight)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.0).cgColor

        popupAnchorVisibleRect = anchorVisibleRect
        if content != .trash { clearTrashListingIfShowing() }
        openPopupContent = content
        folderPopupWantsOpen = true
        setAutoHideInhibitor(.folderPopupOpen, active: true)

        // Same as the drawer: plain NSView container + pinned hosting, so NSHostingView as contentView cannot
        // grow top-anchored downward (project rule).
        let container = NSView(frame: NSRect(origin: .zero, size: lastPopupSize))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        folderPopupContentHost = hosting

        // In place on the first frame (a main cause of the open not feeling smooth, 2026-07-06): measure the
        // real size synchronously **before** orderFront, so the first frame is already the final size, no
        // more "pop up at the old size, then snap". If no sane value can be measured, fall back to
        // lastPopupSize; the double-defer re-measure below is still there as a fallback correction.
        panel.layoutIfNeeded()
        let sync = hosting.fittingSize
        if sync.width >= 160, sync.height >= 100 {
            lastPopupSize = sync
        }
        let initialFrame = PanelGeometry.folderPopupTargetFrame(
            anchorVisibleRect: anchorVisibleRect, size: lastPopupSize, on: screenGeometry, metrics: layoutMetrics)
        lastPopupTargetFrame = initialFrame

        if isSwitching {
            // Switch in place: alpha stays 1, the frame slides from its current position to the new target,
            // content already swapped. Can switch again at any time (interruptible).
            animateFolderPopupFrame(
                panel: panel, to: initialFrame,
                duration: PopoverAnimation.openDuration, timingFunction: PopoverAnimation.curve())
        } else {
            // Once the first frame is in place, fade in as a whole: panel.alphaValue 0 -> 1 fades
            // background/grid/shadow in as one piece (the content layer no longer scales/fades separately,
            // see FolderGridPopupView).
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                panel.setFrame(initialFrame, display: false)
            }
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            pinOverlappingPanelIfNeeded(panel)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = PopoverAnimation.openDuration
                ctx.timingFunction = PopoverAnimation.curve()
                panel.animator().alphaValue = 1
            }
        }
        popupOpenedAt = Date()
        // After showing, re-measure fittingSize (double defer waits for SwiftUI layout to finish): instant
        // fallback correction when the synchronous measurement was off.
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.repositionFolderPopup(animated: false)
            }
        }

        popupLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.dismissFolderPopupIfOutside()
            return event
        }
        popupGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.dismissFolderPopupIfOutside()
        }
    }

    /// Content size change (first measurement / drill-down / live refresh) -> recompute the target frame from
    /// the anchor. Width and height both derive from the content (column count fixes the width).
    private func repositionFolderPopup(animated: Bool) {
        guard folderPopupWantsOpen,
              let panel = folderPopupPanel,
              let hosting = folderPopupContentHost,
              let dock = dockPanel else { return }
        // During the entrance window always correct instantly, so it does not stack with the entrance fade-in
        // and wobble (fix for the pieces looking disjointed).
        let animated = animated && Date().timeIntervalSince(popupOpenedAt) > 0.25
        let fitting = hosting.fittingSize
        let size = CGSize(width: max(fitting.width, 160), height: max(fitting.height, 120))
        lastPopupSize = size
        let screen = panelCurrentScreen(panel: dock)
        let target = PanelGeometry.folderPopupTargetFrame(
            anchorVisibleRect: popupAnchorVisibleRect, size: size, on: Self.screenGeometry(screen), metrics: layoutMetrics)
        lastPopupTargetFrame = target

        if folderPopupFrameTimer != nil {
            // A hand-rolled tween is in flight (most likely the switch animation just triggered): the
            // double-defer fallback correction must not cut it off instantly, only correct its end point to
            // the latest measurement and let it continue (otherwise the switch animation gets welded to its
            // end point right at the start).
            animateFolderPopupFrame(
                panel: panel, to: target,
                duration: PopoverAnimation.openDuration, timingFunction: PopoverAnimation.curve())
        } else if animated {
            animateFolderPopupFrame(
                panel: panel, to: target,
                duration: Self.layoutAnimationDuration, timingFunction: CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            panel.setFrame(target, display: true)
        }
    }

    /// Single cancel entry point for the popup switch/reposition tween: invalidate cannot stop the one
    /// callback that "already fired but whose Task has not run yet", so incrementing the token turns stale
    /// queued tasks into no-ops in tick.
    private func cancelFolderPopupFrameTween() {
        folderPopupFrameTimer?.invalidate()
        folderPopupFrameTimer = nil
        folderPopupTweenTarget = nil
        folderPopupTweenToken &+= 1
    }

    /// Per-frame frame computation for the popup switch/reposition tween: it does not interpolate directly
    /// between two end positions that were each computed and clamped separately (that would treat "clamp or
    /// not" as a straight move between two points and ignore the non-linearity that clamping only kicks in at
    /// sufficient width: wide content hugs the edge, narrow content does not, and linear interpolation slides
    /// in an unnatural direction midway).
    /// Instead it interpolates the "desired center" (unclamped anchor center) + width and height, and reruns
    /// the centering + clamping formula every frame, the same rules as
    /// `PanelGeometry.folderPopupTargetFrame`, so every intermediate size behaves as if "really anchored to
    /// this chip at this size".
    /// The first-frame start uses `start.midX`/`start.minY` rather than the "old anchor": start itself is
    /// always a currently valid frame already on screen, and deriving back from its own center always equals
    /// start exactly, so p=0 never teleports; the end uses `popupAnchorVisibleRect` (the raw position of the
    /// current/new anchor) with the width interpolated to target, which likewise guarantees p=1 lands exactly
    /// on target (the "grow upward only" design intent).
    private func animateFolderPopupFrame(
        panel: NSPanel, to target: NSRect, duration: TimeInterval, timingFunction: CAMediaTimingFunction
    ) {
        // Already flying to the same target -> do not restart, let it finish on its original clock (the
        // common case of the double-defer fallback correction; a restart interrupts the animation right after
        // it starts and resets the progress clock, creating a speed jump + longer duration out of nothing).
        if folderPopupFrameTimer != nil, folderPopupTweenTarget == target { return }
        cancelFolderPopupFrameTween()
        let token = folderPopupTweenToken

        let start = panel.frame
        guard start != target, duration > 0, let dock = dockPanel else {
            panel.setFrame(target, display: true)
            return
        }
        let screen = Self.screenGeometry(panelCurrentScreen(panel: dock))

        let ease = UnitBezierEase(timingFunction)
        let (w0, w1) = (start.width, target.width)
        let (h0, h1) = (start.height, target.height)
        let startCenterX = start.midX
        let endCenterX = popupAnchorVisibleRect.midX
        let startBottomY = start.minY
        let endBottomY = popupAnchorVisibleRect.maxY + 8
        let clockStart = CACurrentMediaTime()

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            Task { @MainActor [weak self] in
                guard let self, self.folderPopupTweenToken == token, let panel = self.folderPopupPanel else {
                    t.invalidate()
                    return
                }
                let raw = min(max((CACurrentMediaTime() - clockStart) / duration, 0), 1)
                if raw >= 1 {
                    panel.setFrame(target, display: true)   // land on the exact target value, not relying on float error hitting exactly 1.0
                    self.folderPopupFrameTimer = nil
                    self.folderPopupTweenTarget = nil
                    t.invalidate()
                } else {
                    let p = ease.progress(at: raw)
                    let width = w0 + (w1 - w0) * p
                    let height = h0 + (h1 - h0) * p
                    // Every frame reruns PanelGeometry's centering + clamping formula with the current size
                    // (same source of truth as first frame / reposition).
                    let origin = PanelGeometry.folderPopupClampedOrigin(
                        desiredCenterX: startCenterX + (endCenterX - startCenterX) * p,
                        desiredBottomY: startBottomY + (endBottomY - startBottomY) * p,
                        size: CGSize(width: width, height: height), on: screen)
                    panel.setFrame(NSRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
                }
            }
        }
        folderPopupFrameTimer = timer
        folderPopupTweenTarget = target
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Interruptible fade-out close (same as closeDrawer). immediately=true is for instant switches when
    /// changing target.
    func closeFolderPopup(immediately: Bool = false) {
        guard folderPopupWantsOpen else { return }
        clearTrashListingIfShowing()
        folderPopupWantsOpen = false
        openPopupContent = nil
        setAutoHideInhibitor(.folderPopupOpen, active: false)
        if let m = popupLocalMonitor  { NSEvent.removeMonitor(m); popupLocalMonitor  = nil }
        if let m = popupGlobalMonitor { NSEvent.removeMonitor(m); popupGlobalMonitor = nil }
        cancelFolderPopupFrameTween()   // any in-flight tween must stop on close, so it does not keep moving the frame after orderOut
        guard let panel = folderPopupPanel else { return }

        if immediately {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = PopoverAnimation.closeDuration
            ctx.timingFunction = PopoverAnimation.curve()
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.folderPopupWantsOpen else { return }   // reopened mid-fade -> do not orderOut
                panel.orderOut(nil)
            }
        })
    }

    /// click-away: no close inside the popup; **no close inside the anchor chip (+4pt tolerance) either**.
    /// The monitor closes on mouseDown and the chip's onTapGesture reopens on mouseUp; without excluding the
    /// anchor, clicking the same chip would flap open/close forever (race confirmed in review, do not
    /// remove).
    private func dismissFolderPopupIfOutside() {
        guard folderPopupWantsOpen, let panel = folderPopupPanel else { return }
        let mouse = NSEvent.mouseLocation
        guard !panel.frame.contains(mouse),
              !popupAnchorVisibleRect.insetBy(dx: -4, dy: -4).contains(mouse) else { return }
        closeFolderPopup()
    }

    /// Pinned folder list changed: sync the cover watchers, close the popup of a removed folder, re-lay out
    /// the taskbar width.
    func subscribePinnedFolderStore() {
        pinnedFolderStoreSubscription = pinnedFolderStore.$folderPaths
            .receive(on: DispatchQueue.main)
            .sink { [weak self] paths in
                guard let self else { return }
                self.folderCoverStore.sync(paths: paths)
                if let openPath = self.openPopupPath, !paths.contains(openPath) {
                    self.closeFolderPopup()
                }
                DispatchQueue.main.async { [weak self] in self?.relayout(animated: true) }
            }
        // A folder's sort order changed: the cover becomes the first file in the new order; if that folder's
        // popup is open -> take the in-place switch path and reopen with the new order (panel stays up,
        // content swaps instantly; resetting drill-down state is an accepted edge, same as native Stacks).
        pinnedFolderSortSubscription = pinnedFolderStore.$sortOrders
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                self.folderCoverStore.sync(paths: self.pinnedFolderStore.folderPaths)
                if let openPath = self.openPopupPath {
                    self.openFolderPopup(path: openPath, anchorVisibleRect: self.popupAnchorVisibleRect)
                }
            }
    }
}
