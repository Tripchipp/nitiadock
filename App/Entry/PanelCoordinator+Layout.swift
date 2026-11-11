import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

// PanelCoordinator · Layout: content width subscription, target frame computation and commit, size change,
// screen parameter changes.
// Split out of PanelCoordinator.swift as an extension on 2026-09-05, moved without changes.
extension PanelCoordinator {
    // MARK: - Content Width via fittingSize

    func subscribeSnapshotWidth() {
        snapshotWidthSubscription = runtime.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                // The `receive(on:)` hop already comes after the snapshot write, and `fittingSize` lays
                // SwiftUI out synchronously for the new snapshot, so no extra main-queue round is needed.
                // Cards added or removed (id set changed) still use the window animation; when only labels
                // changed and the follow window is open, no animation starts: content width changes every
                // frame then, the panel follows per frame via `labelFollowTick`, and what is measured here is
                // only an in-between value.
                let ids = Set(snapshot.orderedWindowIDs)
                let idsChanged = self.lastSnapshotWindowIDs != ids
                self.lastSnapshotWindowIDs = ids
                if idsChanged {
                    self.relayout(animated: true)   // layoutPanels includes drawer repositioning
                } else if !self.isLabelFollowActive {
                    self.relayout(animated: true)
                }
                // Follow window open and only labels changed: do nothing, `labelFollowTick` drives the panel
                // along the curve.
            }
    }

    func subscribeDrawerStoreWidth() {
        drawerStoreWidthSubscription = drawerStore.$bundleIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.syncDrawerOrder()
                    self?.relayout(animated: true)
                }
            }
    }

    /// Close up on drag-out (2026-09-03): when the card on the bar leaves / returns to the taskbar, the
    /// projection layer drops / restores it, and the panel width has to animate along. The taskbar width is
    /// **no longer clamped** (the width-freeze mechanism from the two rounds 2026-06-22 -> 08-20 was removed
    /// with this):
    /// the bar width always equals the width of the currently rendered content, so the bar is already narrow
    /// when a stow drag is released, and the capsule / drawer no longer slide mid-flight.
    /// Same pattern as the store subscription (receive(on:) first, then one async round so SwiftUI lays out
    /// the new projection first; only then is `fittingSize` the new width).
    func subscribeStripSlotCollapse() {
        stripSlotCollapseSubscription = dragController.$stripSlotCollapsed
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // In a size-change transaction cancelDrag() also gets here and queues one animated layout;
                // swallow it with the generation, otherwise it animates once with the new metrics and then
                // jumps once from the transaction's non-animated layout.
                let generation = self.dockSizeChangeGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.dockSizeChangeGeneration else { return }
                    self.relayout(animated: true)
                }
            }
    }

    /// Drawer order converges on the full placement set, not trimmed to the currently visible items. Synced
    /// even when the drawer is closed, so hidden members return to their relative position on the next
    /// launch.
    private func syncDrawerOrder() {
        let members = AppMembershipProjection.drawerMembers(drawerIDs: drawerStore.bundleIDs)
        drawerOrderStore.sync(members: members)
    }

    func subscribeMessagingStoreWidth() {
        messagingStoreWidthSubscription = messagingStore.$bundleIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.relayout(animated: true)
                }
            }
    }

    func subscribeKeptAppStore() {
        keptAppStoreSubscription = keptAppStore.$bundleIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.relayout(animated: true)
                }
            }
    }

    func subscribeRunningApplicationStore() {
        runningApplicationStoreSubscription = runningApplicationStore.$runningBundleIDs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.relayout(animated: true) }
            }
    }

    func subscribeSettings() {
        edgeDelaySubscription = settingsStore.$edgeAutoHideDelay
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reconcilePanelVisibility()
                self?.onHoverMonitorsNeedReconcile?()  // edge-hide toggle changed: whether the monitors are still needed
            }
        // Display placement changed: dwell is void; switching to the fixed mode moves to the fixed screen
        // immediately; monitors and wake arming are re-evaluated for the new mode.
        // dropFirst: the launch path setupDockPanel already consumed the persisted mode.
        taskbarScreenPlacementSubscription = settingsStore.$taskbarScreenPlacement
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.cancelHoverSwitch()
                if let home = self.resolvedPinnedScreen(), let panel = self.dockPanel,
                   self.panelCurrentScreen(panel: panel) != home {
                    self.layoutPanels(contentWidth: self.lastDesiredWidth, on: home, animated: false)
                }
                self.onHoverMonitorsNeedReconcile?()
                self.reconcilePanelVisibility()
                // ③↔④ does not rebuild units, it only swaps the projection layer's filter set: after SwiftUI
                // redraws, no other path comes back here to measure the width (found in the first acceptance
                // round, 2026-09-02: after switching modes the bar length did not change until a window was
                // clicked). Measure after this layout round finishes.
                DispatchQueue.main.async { [weak self] in self?.relayout(animated: true) }
            }
        // Screen list changed (plug/unplug / main screen changed): under ④ the rendered set changes (cards
        // from other screens fall back to the main screen), so re-measure the width as well.
        displayTopologySubscription = displayTopologyStore.$table
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.relayout(animated: true) }
            }
        // Showing/hiding the shelf changes the taskbar content width: if the chip just disappears without a
        // relayout, the panel stays at the old width, and the capsule and an open drawer stay at their old
        // positions too. relayout must wait for this SwiftUI layout round to finish (only then is fittingSize
        // the new value), hence one more main-queue round.
        showShelfSubscription = settingsStore.$showShelf
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.folderPopupWantsOpen, self.openPopupContent == .shelf { self.closeFolderPopup() }
                DispatchQueue.main.async { [weak self] in self?.relayout(animated: true) }
            }
        // fork: drawer capsule shown / hidden. Same deferred relayout as the shelf above: the strip's
        // content changes too (stashed apps come back onto it), so `fittingSize` is only right after
        // SwiftUI's next pass.
        showDrawerSubscription = settingsStore.$showDrawer
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.applyDrawerCapsulePresence()
                DispatchQueue.main.async { [weak self] in self?.relayout(animated: true) }
            }
        // fork: Appearance overrides can change card widths (title font size, and the width options).
        forkAppearanceSubscription = settingsStore.$appearance
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.relayoutAfterForkAppearanceChange() }
        showTrashSubscription = settingsStore.$showTrash
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.folderPopupWantsOpen, self.openPopupContent == .trash { self.closeFolderPopup() }
                DispatchQueue.main.async { [weak self] in self?.relayout(animated: true) }
            }
        dockSizeSubscription = settingsStore.$dockSize
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.beginDockSizeChange() }
    }

    /// A size change is a **transaction**, not an ordinary content change: panel height, capsule width and
    /// the size of every chip in the bar change together, and any animated layout in between would put the
    /// three panels on half-new, half-old geometry.
    ///
    /// The order matters:
    /// 1. First tear down everything attached to the old geometry: the drag carrier (sized by the dock size),
    ///    the drawer (`maxContentHeight` is passed into the root view once when the drawer opens; moving only
    ///    the outer frame would clip the content), popups and the tooltip (anchors are void).
    /// 2. `cancelDrag()` queues an **animated** relayout through `subscribeStripSlotCollapse`; gate it out
    ///    with the generation, otherwise it animates once with the new metrics and then jumps instantly once.
    /// 3. Wait for SwiftUI to finish a layout round with the new size (only then is `fittingSize` the new
    ///    width), then commit once without animation.
    ///    A size change is instant, with no transition animation.
    ///
    /// Maximize lift avoidance needs nothing here: `taskbarTop` is derived from `panelHeight` and lives in
    /// the Equatable `WindowLiftAvoidanceContext`, so as soon as the size changes `reconcileContext` takes
    /// the existing restore -> re-lift path.
    func beginDockSizeChange() {
        dockSizeChangeGeneration &+= 1
        let generation = dockSizeChangeGeneration

        dragController.cancelDrag()
        dismissWindowTitleTooltip()
        closeFolderPopup(immediately: true)
        if drawerWantsOpen { closeDrawer() }

        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.dockSizeChangeGeneration else { return }
            self.relayout(animated: false)
        }
    }

    /// Taskbar target frame (by content width, centered, width-limited).
    func dockTargetFrame(contentWidth: CGFloat, on screen: NSScreen) -> NSRect {
        // fork: the plate hugs narrow content (see `PanelLayoutMetrics.huggingContent`).
        let emptyWidth = 2 * settingsStore.appearance.resolvedEdgePadding() * settingsStore.dockSize.scale
        return PanelGeometry.dockTargetFrame(contentWidth: contentWidth, on: Self.screenGeometry(screen),
                                             metrics: layoutMetrics.huggingContent(contentWidth: contentWidth,
                                                                                   emptyContentWidth: emptyWidth),
                                             reservesCapsule: showsDrawerCapsule)
    }

    /// Capsule target frame (against the taskbar's right edge, vertically centered). Depends only on the dock
    /// **target** frame passed in.
    private func capsuleTargetFrame(forDock dockFrame: NSRect, on screen: NSScreen) -> NSRect {
        PanelGeometry.capsuleTargetFrame(forDock: dockFrame, on: Self.screenGeometry(screen), metrics: layoutMetrics)
    }

    /// Drawer target frame (right edge on the capsule's right edge, **bottom edge hard-anchored above the
    /// capsule, growing upward**). Depends only on the capsule **target** frame passed in + the drawer size.
    /// Key point: the bottom edge never moves down. Beyond the space available above, the **height is
    /// capped** (content scrolls inside DrawerView); never fit it by "pushing the bottom edge down", which
    /// presses into the capsule/taskbar (seen 2026-06-21).
    func drawerTargetFrame(forCapsule capsuleFrame: NSRect, size: CGSize, on screen: NSScreen) -> NSRect {
        // Bottom/left/right positioning uses screen.frame, decoupling from the native Dock's visibleFrame;
        // the top height is still capped by topUsableY so the menu bar and notch do not cover it.
        PanelGeometry.drawerTargetFrame(forCapsule: capsuleFrame, size: size, on: Self.screenGeometry(screen), metrics: layoutMetrics)
    }

    /// Single layout entry point: computes all three target frames, stores them (read by the drop zones /
    /// drawer open), and animates the three panels to target as one group.
    /// Launch/screen switch/multi-screen hover pass animated:false; content changes, stow/move back and
    /// drawer size changes pass animated:true.
    func layoutPanels(contentWidth: CGFloat, on screen: NSScreen, animated: Bool, batched: Bool = false) {
        guard let dock = dockPanel, let capsule = capsulePanel else { return }
        let panelScreenCGFrame = Self.toCGRect(screen)
        if let transaction = fullscreenIntentTransaction,
           transaction.screenCGFrame != panelScreenCGFrame {
            cancelFullscreenIntent(generation: transaction.generation, reason: "panel-screen-changed")
        }
        let anim = animated && didInitialLayout   // first frame is instant, do not slide in from the initial position
        didInitialLayout = true
        onPanelScreenChanged?()

        let dockT = dockTargetFrame(contentWidth: contentWidth, on: screen)
        // The capsule (and the drawer positioned from it) **always** sits against the bar's current target
        // frame, during a drag too: closing up on drag-out shrinks the bar symmetrically and the capsule
        // moves with it (the native Dock re-centers the whole bar the same way). On 2026-09-03 the capsule
        // was briefly pinned to the old target frame during drags:
        // with multiple screens every unit got pinned, bar B widened into the capsule and bar A narrowed
        // leaving a big gap (seen the same day). Do not add anchoring again.
        // fork: with the drawer hidden there is no capsule target at all. `.zero` is the value every
        // reader of `lastCapsuleTargetFrame` already treats as "no capsule" (drop zones, spring-load).
        let capsuleT = showsDrawerCapsule ? capsuleTargetFrame(forDock: dockT, on: screen) : .zero
        // Any change of the taskbar target frame (width / screen switch) closes the popup: no chasing of an
        // anchor mid-animation (matches the native Dock, keeps target-frame purity).
        if dockT != lastDockTargetFrame {
            if folderPopupWantsOpen { closeFolderPopup() }
            dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
        }
        lastDockTargetFrame = dockT
        lastCapsuleTargetFrame = capsuleT

        var pairs: [(NSPanel, NSRect)] = []
        if let background = dockGlassBackgroundPanel {
            dockGlassBackgroundView?.apply(
                cornerRadius: taskbarPlateCornerRadius,
                configuration: DockGlassPresentation.configuration
            )
            // The background window sits against the visible backplate (content window minus the 20pt
            // transparent shadow margin).
            pairs.append((
                background,
                DockLiquidGlassPanelGeometry.backgroundFrame(
                    for: dockT,
                    shadowPadding: Self.shadowPadding
                )
            ))
        }
        pairs.append((dock, dockT))
        if showsDrawerCapsule { pairs.append((capsule, capsuleT)) }
        if let drawer = drawerPanel, drawer.isVisible, let hosting = drawerContentHost {
            let fitting = hosting.fittingSize
            let drawerSize = CGSize(width: max(fitting.width, 60), height: max(fitting.height, 60))
            lastDrawerSize = drawerSize
            let drawerT = drawerTargetFrame(forCapsule: capsuleT, size: drawerSize, on: screen)
            lastDrawerTargetFrame = drawerT
            pairs.append((drawer, drawerT))
        }
        setFrames(pairs, animated: anim, batched: batched)
    }

    /// Measures the current content width, then lays out (single entry point for content changes).
    func relayout(animated: Bool) {
        guard let panel = dockPanel, let hosting = dockContentHost else { return }
        // `fittingSize` **lays out the whole taskbar synchronously on the main thread**; it does not read a
        // cached value.
        // The probe measures exactly that + whether the width actually changed (animating when it did not is
        // pure waste).
        let measureStart = CACurrentMediaTime()
        let measured = hosting.fittingSize.width - 2 * Self.shadowPadding
        HoverTrace.relayout(measureMs: CACurrentMediaTime() - measureStart,
                            width: measured,
                            changed: measured != lastDesiredWidth,
                            animated: animated,
                            timing: (isLabelFollowActive ? "follow" : "standard") + ":" + String(stripSurfaceID.suffix(4)))
        lastDesiredWidth = measured
        // Cross-panel promotion in progress -> the taskbar width is clamped to its pre-drag value (window
        // cards overflow / leave a gap instead of changing the panel width, 2026-06-22); once release/restore
        // unclamps it, the next relayout takes the taskbar to its final length using the real measurement.
        layoutPanels(contentWidth: measured, on: panelCurrentScreen(panel: panel), animated: animated)
    }

    /// The three panels commit in one animation group on a shared timeline (avoids jitter from each running
    /// its own timeline).
    ///
    /// **Returns immediately, without running a single frame, when the target frames equal the current state
    /// exactly.** Measured 2026-08-17 (`DOCK_HOVER_TRACE=1`): 10 `relayout` calls in the 6 seconds after
    /// launch, **8** of them with no width change at all yet still `animated: true`, and 6 in a row packed
    /// into 1.1ms. Each one starts a group of window-size animations that "animate" the three panels to
    /// exactly their current size, **and every frame of a window-size animation redraws the glass backplate
    /// and its stroke**. The measurement itself is cheap (`fittingSize` 0.2ms); the empty animation is what
    /// costs.
    ///
    /// The criterion is **final frames fully equal**, not "width unchanged": screen changes, size changes and
    /// edge hiding all really move the panels with the width unchanged, and comparing widths alone would
    /// swallow them too.
    /// `batched` (only the per-frame label-follow tick passes true): `display: false`, the three panels'
    /// frame changes are held until the end of this main-loop pass and committed together with the SwiftUI
    /// content. `display: true` one by one flushes each immediately, landing capsule, backplate and content
    /// on different frames (screen burst capture 2026-09-13: mid-growth the capsule touched the backplate
    /// edge).
    func setFrames(_ pairs: [(NSPanel, NSRect)], animated: Bool, batched: Bool = false) {
        // **Compare against the previous target, not the panels' live frames.** Mid-animation a live frame is
        // an interpolated in-between value and never equals the target, so this short-circuit would never hit
        // (measured: 0 times). The project rule says the same: relayout is driven by target frames; do not
        // read a panel's live frame during an animation.
        let targets = pairs.map(\.1)
        guard targets != lastCommittedFrames else {
            HoverTrace.framesUnchanged()
            return
        }
        lastCommittedFrames = targets
        guard animated else {
            for (p, f) in pairs { p.setFrame(f, display: !batched) }
            if let dock = dockPanel { HoverTrace.width("panel:" + String(stripSurfaceID.suffix(4)), dock.frame.width) }
            return
        }
        animatedFramesUntil = CACurrentMediaTime() + Self.layoutAnimationDuration
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.layoutAnimationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for (p, f) in pairs { p.animator().setFrame(f, display: true) }
        }
    }

    // MARK: - Label width follow

    var isLabelFollowActive: Bool { labelFollowTimer != nil }

    /// A label in the bar grew or shrank (`DockStripView.onLabelWidthChange`, called synchronously within
    /// that SwiftUI update).
    /// `starting` = the starting width of the label box that begins moving now. If the follow window is
    /// already open, only the new box is registered; the starting width is not re-measured.
    func beginLabelWidthFollow(starting: [String: CGFloat]) {
        let now = CACurrentMediaTime()
        if !isLabelFollowActive {
            labelFollowRestWidth = lastDesiredWidth
            labelBoxStart = [:]
            labelBoxLive = [:]
        }
        for (id, from) in starting where labelBoxStart[id] == nil {
            labelBoxStart[id] = from
            labelBoxLive[id] = from
        }
        labelFollowDeadline = now + LabelWidthAnimation.curve.duration + 0.1
        guard labelFollowTimer == nil else { return }
        // The timer only handles the wrap-up: after the deadline measure the final value once and clear
        // state. Per-frame frames are set by `labelBoxWidthDidTick`.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            guard CACurrentMediaTime() >= self.labelFollowDeadline else { return }
            t.invalidate()
            self.labelFollowTimer = nil
            self.labelBoxStart = [:]
            self.labelBoxLive = [:]
            self.relayout(animated: false)   // final measurement at wrap-up, absorbs the fraction of a pt from the starting-width estimate
        }
        RunLoop.main.add(timer, forMode: .common)
        labelFollowTimer = timer
    }

    /// Reported every frame by `LabelBoxWidthDriver`: only boxes registered in the follow window count; does
    /// not compete while the window animation for card add/remove is still in flight.
    /// `batched`: the three panels use `display: false` and commit together with this frame's SwiftUI
    /// content.
    func labelBoxWidthDidTick(chipID: String, width: CGFloat) {
        guard isLabelFollowActive, labelBoxStart[chipID] != nil, labelBoxLive[chipID] != width else { return }
        labelBoxLive[chipID] = width
        guard CACurrentMediaTime() >= animatedFramesUntil, let panel = dockPanel else { return }
        let delta = labelBoxStart.reduce(CGFloat(0)) { acc, entry in
            acc + ((labelBoxLive[entry.key] ?? entry.value) - entry.value)
        }
        layoutPanels(contentWidth: labelFollowRestWidth + delta,
                     on: panelCurrentScreen(panel: panel), animated: false, batched: true)
    }

    /// Forwarded by the orchestration layer on `didChangeScreenParametersNotification` (it first builds /
    /// tears down units per screen set, then forwards to the survivors).
    /// Cancelling cross-panel drags and re-evaluating monitors is also done once by the orchestration layer,
    /// not repeated here.
    func screenParametersChanged() {
        cancelHoverSwitch()
        closeFolderPopup()             // screen parameters changed, old anchor coordinates are void
        dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
        guard dockPanel != nil else { return }
        // Pinned to a screen: when the screen set changes, relocate first (pinned screen unplugged -> fall
        // back to the main screen; reconnected -> move back).
        // Must precede relayout: relayout derives the screen from the panel coordinates via
        // panelCurrentScreen.
        if let home = resolvedPinnedScreen(), let panel = dockPanel,
           panelCurrentScreen(panel: panel) != home {
            layoutPanels(contentWidth: lastDesiredWidth, on: home, animated: false)
        }
        relayout(animated: false)      // screen switch is instant, no slide
        cancelFullscreenIntentIfContextChanged()
        reconcilePanelVisibility()
    }

    static func screenGeometry(_ screen: NSScreen) -> PanelScreenGeometry {
        PanelScreenGeometry(frame: screen.frame, visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaInsets.top)
    }
}
