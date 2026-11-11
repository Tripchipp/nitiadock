import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

// PanelCoordinator · Drawer: open/close, host reuse, drag drop-zone geometry, spring-loaded folder auto-open.
// Split out of PanelCoordinator.swift as an extension on 2026-09-05, moved without changes.
extension PanelCoordinator {
    func openDrawer() {
        guard let mainPanel = dockPanel, shownCapsulePanel != nil else { return }   // fork: hidden drawer never opens
        onAccessoryWillOpen?(self, .drawer)
        drawerActionCloseToken += 1  // a delayed close queued by an earlier click captured the old token; a mismatch discards it
        drawerWantsOpen = true
        setAutoHideInhibitor(.drawerOpen, active: true)
        drawerSpringOpened = false   // manual open by default; the spring path sets it back to true in springOpenDrawer

        let screen = panelCurrentScreen(panel: mainPanel)
        let (capsuleRef, maxContentHeight) = drawerAnchor(on: screen)

        // The host is built once; later opens only swap rootView when the available height changed.
        // Each phase logs a `HoverTrace.action("drawerOpen")` marker: only that can tell which phase
        // contributes to the main-thread stall of an open.
        HoverTrace.action("drawerOpen", phase: "begin")
        guard let host = ensureDrawerHost(maxContentHeight: maxContentHeight) else { return }
        let (panel, hosting) = host
        HoverTrace.action("drawerOpen", phase: "host")

        // In place on the first frame (a main cause of the open not feeling smooth, 2026-07-06): measure the
        // real size synchronously **before** orderFront, so the first frame is already the final size, no
        // more "pop up at the old size, then snap". If no sane value can be measured, fall back to
        // lastDrawerSize; the double-defer re-measure below is still there as a fallback correction.
        panel.layoutIfNeeded()
        HoverTrace.action("drawerOpen", phase: "layout")
        let sync = hosting.fittingSize
        HoverTrace.action("drawerOpen", phase: "fitting")
        if sync.width >= 60, sync.height >= 60 {
            lastDrawerSize = sync
        }
        let initialFrame = drawerTargetFrame(forCapsule: capsuleRef, size: lastDrawerSize, on: screen)
        lastDrawerTargetFrame = initialFrame

        panel.setFrame(initialFrame, display: false)
        // Opens without animation (2026-09-04, rationale in `DrawerView`): goes on screen at
        // alpha 1 directly.
        // Reopening mid fade-out also goes straight back to 1; the `closeDrawer` completion has a
        // `!drawerWantsOpen` guard, so it will not orderOut.
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        HoverTrace.action("drawerOpen", phase: "ordered")
        pinOverlappingPanelIfNeeded(panel)
        HoverTrace.action("drawerOpen", phase: "shown")
        // After showing, re-measure fittingSize and lay out again (instant, no slide right after showing):
        // fallback correction when the synchronous measurement was off.
        DispatchQueue.main.async { [weak self] in
            HoverTrace.action("drawerOpen", phase: "turn1")
            DispatchQueue.main.async { [weak self] in
                HoverTrace.action("drawerOpen", phase: "turn2")
                self?.relayout(animated: false)
            }
        }

        drawerLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.dismissDrawerIfOutside()
            return event
        }
        drawerGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.dismissDrawerIfOutside()
        }
    }

    /// Positioning inputs for the drawer: the capsule's **target** frame (not live: the user may spring-open
    /// the drawer during the taskbar width animation) and the drawer's max content height = available height
    /// from the anchor above the capsule to the top of the screen. Overflow scrolls inside DrawerView; never
    /// fit it by pushing the bottom edge down (that presses into the capsule/taskbar = overlap).
    /// The top limit still avoids the menu bar / notch; the bottom anchor does not avoid the native Dock, so
    /// Command+Option+D or a side Dock cannot push the drawer.
    private func drawerAnchor(on screen: NSScreen) -> (capsuleRef: NSRect, maxContentHeight: CGFloat) {
        let screenGeometry = Self.screenGeometry(screen)
        let capsuleRef = lastCapsuleTargetFrame == .zero ? (capsulePanel?.frame ?? .zero) : lastCapsuleTargetFrame
        return (capsuleRef, PanelGeometry.maxDrawerContentHeight(forCapsule: capsuleRef, on: screenGeometry))
    }

    private func makeDrawerRootView(maxContentHeight: CGFloat) -> DrawerRootView {
        DrawerRootView(maxContentHeight: maxContentHeight,
                       usesLiquidGlass: usesLiquidGlass,
                       isDrawerOpen: { [weak self] in self?.drawerPanel?.isVisible == true },
                       onPrimaryAction: { [weak self] in self?.closeDrawerAfterAction() },
                       runtime: runtime, drawerStore: drawerStore, messagingStore: messagingStore,
                       drawerOrderStore: drawerOrderStore, dragController: dragController,
                       keptAppStore: keptAppStore, runningApplicationStore: runningApplicationStore,
                       appMembershipController: appMembershipController)
    }

    /// Drawer panel + SwiftUI host, **built once**; afterwards rootView is only swapped when the available
    /// height changed.
    /// Before 2026-09-04 every open built a fresh view tree, and a 55-135ms main-thread stall landed at the
    /// start of the fade-in (main cause of dropped frames on open).
    private func ensureDrawerHost(maxContentHeight: CGFloat) -> (NSPanel, NSHostingView<DrawerRootView>)? {
        if drawerPanel == nil {
            let panel = makeFloatingPanel(
                contentRect: NSRect(origin: .zero, size: lastDrawerSize),
                usesLiquidGlass: usesLiquidGlass
            )
            configurePanel(panel, backgroundColor: NSColor(white: 1.0, alpha: 0.0), appliesLevelOverride: false)
            drawerPanel = panel
        }
        guard let panel = drawerPanel else { return nil }

        if let hosting = drawerHosting {
            if drawerHostedMaxContentHeight != maxContentHeight {
                hosting.rootView = makeDrawerRootView(maxContentHeight: maxContentHeight)
                drawerHostedMaxContentHeight = maxContentHeight
            }
            return (panel, hosting)
        }

        let hosting = NSHostingView(rootView: makeDrawerRootView(maxContentHeight: maxContentHeight))
        drawerHostedMaxContentHeight = maxContentHeight
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.0).cgColor

        // Key point: use a plain NSView as contentView with hosting as an auto-resizing subview. **Do not
        // make NSHostingView the contentView directly**.
        // Otherwise, when the content grows taller, macOS uses the content size to grow the window **anchored
        // at the top, downward** (logs show cur(y=24 h=194), top always =218), and only afterwards does our
        // layout correct it to bottom-anchored upward growth (y=68). That back-and-forth is the real cause of
        // the visible "expands down, then moves up" (2026-06-22). A plain NSView does not pass its subview's
        // content size to the window, so the window height is controlled only by layoutPanels/setFrames;
        // fittingSize is read from hosting instead (stored in drawerContentHost).
        let container = NSView(frame: NSRect(origin: .zero, size: lastDrawerSize))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        drawerContentHost = hosting
        drawerHosting = hosting
        return (panel, hosting)
    }

    /// Prewarms the drawer host after launch (no orderFront, no open/close state touched), so the **first**
    /// open of the session does not build it on demand either.
    /// Scheduled 1 second after the launch first-frame transaction, without touching it. A live view for a
    /// closed drawer is not a new state (already the case under ③④); drag callbacks all ask `isDrawerOpen()`
    /// first.
    func prewarmDrawerHost() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, !self.isSuspendedForPermissionLoss, self.drawerHosting == nil,
                  let mainPanel = self.dockPanel, self.capsulePanel != nil else { return }
            let anchor = self.drawerAnchor(on: self.panelCurrentScreen(panel: mainPanel))
            guard let host = self.ensureDrawerHost(maxContentHeight: anchor.maxContentHeight) else { return }
            let (panel, hosting) = host
            panel.layoutIfNeeded()
            _ = hosting.fittingSize
        }
    }

    /// Delayed close after clicking an app's primary action in the drawer. Captures the token and closes only
    /// after a triple check when it fires:
    /// 1. the token matches (rules out the drawer being reopened during the delay); 2. the drawer is still
    ///    logically open; 3. no drag in progress.
    func closeDrawerAfterAction() {
        let token = drawerActionCloseToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self,
                  self.drawerActionCloseToken == token,
                  self.drawerWantsOpen,
                  self.dragController.draggingPayload == nil else { return }
            self.closeDrawer()
        }
    }

    /// Interruptible fade-out close: remove the monitors immediately, animate alpha -> 0, and orderOut in the
    /// completion only if it should still close (not if it was reopened mid-fade).
    func closeDrawer() {
        guard drawerWantsOpen else { return }
        drawerWantsOpen = false
        setAutoHideInhibitor(.drawerOpen, active: false)
        drawerSpringOpened = false
        if let m = drawerLocalMonitor  { NSEvent.removeMonitor(m); drawerLocalMonitor  = nil }
        if let m = drawerGlobalMonitor { NSEvent.removeMonitor(m); drawerGlobalMonitor = nil }
        guard let panel = drawerPanel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = PopoverAnimation.closeDuration
            ctx.timingFunction = PopoverAnimation.curve()
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.drawerWantsOpen else { return }   // reopened mid-fade -> do not orderOut
                panel.orderOut(nil)
            }
        })
    }

    /// Fullscreen input delivery is already paused by the tap, so the fade-out cannot be awaited; state and
    /// monitors are torn down as usual, then the panel leaves WindowServer immediately.
    func closeDrawerImmediately() {
        guard drawerWantsOpen || drawerPanel?.isVisible == true else { return }
        drawerWantsOpen = false
        setAutoHideInhibitor(.drawerOpen, active: false)
        drawerSpringOpened = false
        if let monitor = drawerLocalMonitor {
            NSEvent.removeMonitor(monitor)
            drawerLocalMonitor = nil
        }
        if let monitor = drawerGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            drawerGlobalMonitor = nil
        }
        drawerPanel?.alphaValue = 0
        drawerPanel?.orderOut(nil)
    }

    private func dismissDrawerIfOutside() {
        guard dragController.draggingPayload == nil else { return }   // do not close by mistake mid-drag
        guard let drawer = drawerPanel, drawer.isVisible,
              let dock   = dockPanel else { return }
        let mouse = NSEvent.mouseLocation
        guard !drawer.frame.contains(mouse),
              !dock.frame.contains(mouse),
              !(shownCapsulePanel?.frame.contains(mouse) ?? false) else { return }
        closeDrawer()
    }

    func dragDropZones(for source: DragSource) -> [CGRect] {
        // Read the **target** frame: mid-animation the live frame is an in-between value and briefly
        // disagrees with the visuals/landing. Fall back to live when the target is uninitialized.
        func target(_ stored: NSRect, _ live: NSRect?) -> NSRect? { stored != .zero ? stored : live }
        switch source {
        case .strip, .messaging:
            var zones: [CGRect] = []
            if let c = target(lastCapsuleTargetFrame, shownCapsulePanel?.frame) {
                zones.append(c.insetBy(dx: Self.shadowPadding - 8, dy: Self.shadowPadding - 8))
            }
            if let drawer = drawerPanel, drawer.isVisible, let d = target(lastDrawerTargetFrame, drawer.frame) {
                // The drawer only grows upward: the drop zone's **top edge is pulled to the top of the
                // screen**, honoring only the fixed bottom edge and width, regardless of the panel growing or
                // shrinking.
                // Otherwise "drop-zone size -> whether a gap is inserted -> panel grows -> drop-zone size"
                // forms a feedback loop: the gap flickers, the panel animation gets interrupted at high
                // frequency and overshoots downward (real cause of the 2026-06-21 "expands down, then moves
                // up").
                let inset = d.insetBy(dx: Self.shadowPadding, dy: Self.shadowPadding)
                // The drop zone extends up to the same top limit as the drawer: avoids the menu bar/notch,
                // but not the native Dock.
                let top = Self.screenGeometry(panelCurrentScreen(panel: drawer)).topUsableY
                zones.append(CGRect(x: inset.minX, y: inset.minY, width: inset.width, height: max(inset.height, top - inset.minY)))
            }
            return zones
        case .drawer:
            guard let d = target(lastDockTargetFrame, dockPanel?.frame) else { return [] }
            return [d.insetBy(dx: Self.shadowPadding, dy: Self.shadowPadding)]
        case .folder:
            // Folder chips have no drop zone (canExternalDrop=false means it is never queried; in-zone
            // reorder, drag-out removal and drag-back-to-open are all decided in DockStripView with
            // FolderChipDropZone). Kept separate from the strip/drawer stow semantics (review decision).
            return []
        }
    }

    // MARK: - Spring-loaded folder: hovering a dragged card over the capsule auto-opens the drawer

    /// A strip card held over the capsule (with the drawer closed, the capsule is the only drop zone) for
    /// about 0.4s auto-opens the drawer; moving into the drawer then picks up precise positioning.
    /// Releasing on the capsule without waiting still means "stow at the end". Moving away or releasing
    /// cancels the timer.
    func subscribeDragSpringLoad() {
        // Subscribe to globalLocation (not isOverDropZone): the cursor returning to the taskbar does not
        // change isOverDropZone, so only the position can retract the drawer in real time (2026-06-21:
        // dragging back to the taskbar retracts, moving back to the capsule reopens).
        dragSpringSubscription = dragController.pointerMoves
            .combineLatest(dragController.$draggingPayload)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] location, payload in
                self?.updateSpringLoad(location: location, payload: payload)
            }
    }

    func subscribeDragInhibitor() {
        dragInhibitorSubscription = dragController.$draggingPayload
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dragging in
                if dragging { self?.dismissWindowTitleTooltip(suppressCurrentUntilExit: true) }
                self?.setAutoHideInhibitor(.dragging, active: dragging)
            }
    }

    /// Region hit test: the target frame is the visible content area + 6pt hysteresis (prevents flapping at
    /// the capsule/taskbar boundary).
    func springZone(_ target: NSRect) -> CGRect {
        target.insetBy(dx: Self.shadowPadding - 6, dy: Self.shadowPadding - 6)
    }

    private func updateSpringLoad(location: CGPoint, payload: DragPayload?) {
        // Any drag that started on the taskbar gets the spring for its whole duration (the flag still counts
        // after promotion to .drawer). Message-zone chips get it too:
        // only auto-opening the drawer over the capsule gives a precise stow landing.
        if let p = payload, p.source == .strip || p.source == .messaging {
            dragOriginatedFromStrip = true; springDragBundleID = p.bundleID
        }

        // Fallback on release: if a spring-opened drawer did not take the card in -> retract it. (Live hover
        // handles most cases; this is the fallback.)
        if payload == nil {
            cancelSpringTimers()
            if drawerSpringOpened, let bid = springDragBundleID, !drawerStore.contains(bid) {
                closeDrawer()
            }
            drawerSpringOpened = false
            springDragBundleID = nil
            dragOriginatedFromStrip = false
            return
        }
        // Drags not started on the taskbar (pure in-drawer drags / drawer -> taskbar moves back) get no
        // spring.
        guard dragOriginatedFromStrip else { cancelSpringTimers(); return }

        let inDrawer  = drawerWantsOpen && lastDrawerTargetFrame != .zero && springZone(lastDrawerTargetFrame).contains(location)
        let inCapsule = lastCapsuleTargetFrame != .zero && springZone(lastCapsuleTargetFrame).contains(location)

        if inDrawer || inCapsule {
            // Over the drawer or capsule -> cancel the retract; closed and over the capsule -> start the
            // open-drawer timer.
            springCloseTimer?.invalidate(); springCloseTimer = nil
            if !drawerWantsOpen {
                if inCapsule && springOpenTimer == nil { armSpringOpenTimer() }
            } else {
                springOpenTimer?.invalidate(); springOpenTimer = nil      // already open -> keep
            }
        } else {
            // Left the drawer + capsule (over the taskbar or a gap) -> cancel a pending open; if open,
            // retract after a **delay** (2026-06-22).
            springOpenTimer?.invalidate(); springOpenTimer = nil
            if drawerWantsOpen && springCloseTimer == nil { armSpringCloseTimer() }
        }
    }

    private func cancelSpringTimers() {
        springOpenTimer?.invalidate(); springOpenTimer = nil
        springCloseTimer?.invalidate(); springCloseTimer = nil
    }

    private func armSpringOpenTimer() {
        // .common mode: during a drag the main run loop is in event-tracking mode, and a scheduledTimer
        // (default mode) does not fire.
        let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.springOpenDrawer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        springOpenTimer = timer
    }

    /// Retract only ~0.35s after leaving the drawer + capsule (briefly brushing the taskbar/gap does not
    /// retract). Close only if at fire time the drag is ongoing, the drawer is open and the cursor is still
    /// outside.
    private func armSpringCloseTimer() {
        let timer = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.springCloseDrawerIfStillOutside() }
        }
        RunLoop.main.add(timer, forMode: .common)
        springCloseTimer = timer
    }

    private func springCloseDrawerIfStillOutside() {
        springCloseTimer = nil
        guard dragOriginatedFromStrip, drawerWantsOpen else { return }
        let loc = dragController.globalLocation
        let inDrawer  = lastDrawerTargetFrame != .zero && springZone(lastDrawerTargetFrame).contains(loc)
        let inCapsule = lastCapsuleTargetFrame != .zero && springZone(lastCapsuleTargetFrame).contains(loc)
        guard !inDrawer, !inCapsule else { return }   // back over the drawer/capsule -> do not close
        closeDrawer()
    }

    private func springOpenDrawer() {
        springOpenTimer = nil
        // At fire time still dragging, still over the capsule, drawer still closed -> spring open. Uses
        // dragOriginatedFromStrip + a fresh capsule hit test (not isOverDropZone: after promotion to .drawer
        // it refers to the taskbar zone, is false over the capsule, and would wrongly block reopening;
        // 2026-06-22).
        let loc = dragController.globalLocation
        let inCapsule = lastCapsuleTargetFrame != .zero && springZone(lastCapsuleTargetFrame).contains(loc)
        guard dragController.draggingPayload != nil,
              dragOriginatedFromStrip,
              inCapsule,
              !drawerWantsOpen else { return }
        openDrawer()
        drawerSpringOpened = true   // openDrawer set it to false; mark here that this was a spring open
        dragController.bringCarrierToFront()
    }
}
