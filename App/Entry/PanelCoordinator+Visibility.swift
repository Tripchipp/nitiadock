import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

// PanelCoordinator · Visibility: multi-screen hover screen switch, edge auto-hide / wake, applying the
// visibility state machine.
// Split out of PanelCoordinator.swift as an extension on 2026-09-05, moved without changes.
extension PanelCoordinator {
    /// In fixed mode, resolves the display UUID to the current NSScreen (falls back to the main / first
    /// screen when the fixed screen is absent); returns nil in follow-mouse mode. Deliberately **no
    /// persistent runtime state**: re-resolved on every screen parameter / settings change, so the fixed
    /// screen moves back naturally once reconnected, with no "remember where it was" state machine.
    /// The `.fixed` units of ③④ go through here too: in the instant after a screen is unplugged and before
    /// the orchestration layer tears the unit down, it falls back to the main screen instead of ending up
    /// nil.
    func resolvedPinnedScreen() -> NSScreen? {
        guard let pinnedUUID = fixedDisplayUUID else { return nil }
        let screens = NSScreen.screens
        let outcome = TaskbarScreenResolution.resolve(
            pinnedUUID: pinnedUUID,
            screenUUIDs: screens.map { DisplayIdentity.uuidString(for: $0) },
            mainIndex: NSScreen.main.flatMap { screens.firstIndex(of: $0) }
        )
        switch outcome {
        case .matched(let index), .fallback(let index):
            return screens[index]
        case nil:
            return nil
        }
    }

    // The mouse-move monitor (install / throttle / suspend during menu tracking) lives entirely in the
    // orchestration layer `TaskbarScreenOrchestrator`:
    // one per process, with callbacks forwarded to each unit's `pollMousePosition()`. Units keep only the
    // probing and arming logic.

    func logScreenMap() {
        let screens = NSScreen.screens
        for (i, screen) in screens.enumerated() {
            let f = screen.frame
            let vf = screen.visibleFrame
            hoverLogger.info("screen-map index=\(i, privacy: .public) name=\(screen.localizedName, privacy: .public) frame=(\(f.minX, privacy: .public),\(f.minY, privacy: .public),\(f.width, privacy: .public),\(f.height, privacy: .public)) visibleFrame=(\(vf.minX, privacy: .public),\(vf.minY, privacy: .public),\(vf.width, privacy: .public),\(vf.height, privacy: .public)) isMain=\(screen == NSScreen.main, privacy: .public) isScreens0=\(i == 0, privacy: .public)")
        }
    }

    /// Every (throttled) mouse move enters here, forwarded by the orchestration layer. Moves on other screens
    /// exit early and cheaply in `handleBottomEdgeProbe`.
    func pollMousePosition() {
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens

        var curScreenIdx: Int? = nil
        var curScreen: NSScreen? = nil
        for (i, s) in screens.enumerated() {
            if s.frame.contains(mouse) { curScreenIdx = i; curScreen = s; break }
        }

        let dyFromBottom: CGFloat
        let inHotZone: Bool
        if let s = curScreen {
            dyFromBottom = mouse.y - s.frame.minY
            inHotZone = dyFromBottom <= Self.hoverHotZone
        } else {
            dyFromBottom = -1
            inHotZone = false
        }

        handleBottomEdgeProbe(screen: curScreen, inHotZone: inHotZone)
        updateEdgeIdleTimerFromMouse()

        guard curScreenIdx != hoverLastScreenIndex || inHotZone != hoverLastInHotZone else { return }
        hoverLastScreenIndex = curScreenIdx
        hoverLastInHotZone = inHotZone

        if Self.hoverVerboseLogging {
            let panelScreenIdx = dockPanel.map { p -> String in
                let ps = panelCurrentScreen(panel: p)
                return screens.firstIndex(of: ps).map { "\($0)" } ?? "?"
            } ?? "nil"
            if let s = curScreen, let idx = curScreenIdx {
                let f = s.frame
                let vf = s.visibleFrame
                hoverLogger.info("cursor screen=\(idx, privacy: .public) name=\(s.localizedName, privacy: .public) mouse=(\(mouse.x, privacy: .public),\(mouse.y, privacy: .public)) frame=(\(f.minX, privacy: .public),\(f.minY, privacy: .public),\(f.width, privacy: .public),\(f.height, privacy: .public)) visibleFrame=(\(vf.minX, privacy: .public),\(vf.minY, privacy: .public),\(vf.width, privacy: .public),\(vf.height, privacy: .public)) dyFromBottom=\(dyFromBottom, privacy: .public) inHotZone=\(inHotZone, privacy: .public) panelScreen=\(panelScreenIdx, privacy: .public)")
            } else {
                hoverLogger.info("cursor screen=none mouse=(\(mouse.x, privacy: .public),\(mouse.y, privacy: .public)) dyFromBottom=none inHotZone=false panelScreen=\(panelScreenIdx, privacy: .public)")
            }
        }

    }

    func cancelHoverSwitch() {
        hoverSwitchTimer?.invalidate()
        hoverSwitchTimer = nil
        hoverSwitchTargetScreen = nil
    }

    private func commitHoverSwitch() {
        hoverSwitchTimer = nil
        // Safety: within the 350ms dwell window the setting may flip to fixed mode, making the decision at
        // arming time stale.
        guard hoverScreenSwitchingEnabled else {
            hoverSwitchTargetScreen = nil
            return
        }
        guard let targetScreen = hoverSwitchTargetScreen, let panel = dockPanel else {
            hoverSwitchTargetScreen = nil
            return
        }
        hoverSwitchTargetScreen = nil
        // Confirm the cursor is still on the target screen (it may have left within the last poll gap).
        guard targetScreen.frame.contains(NSEvent.mouseLocation) else { return }
        let panelScreen = panelCurrentScreen(panel: panel)
        guard targetScreen != panelScreen else { return }   // panel already moved (e.g. screenParametersChanged)
        let screens = NSScreen.screens
        let fromIdx = screens.firstIndex(of: panelScreen).map { "\($0)" } ?? "?"
        let toIdx = screens.firstIndex(of: targetScreen).map { "\($0)" } ?? "?"
        let actualWidth = PanelGeometry.dockTargetFrame(
            contentWidth: lastDesiredWidth,
            on: Self.screenGeometry(targetScreen),
            metrics: layoutMetrics
        ).width - Self.shadowPadding * 2
        closeFolderPopup()   // after a screen switch the old anchor is on the old screen, dismiss the popup
        dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
        layoutPanels(contentWidth: lastDesiredWidth, on: targetScreen, animated: false)
        hoverLogger.info("switch toScreen=\(toIdx, privacy: .public) name=\(targetScreen.localizedName, privacy: .public) actualWidth=\(actualWidth, privacy: .public) fromScreen=\(fromIdx, privacy: .public)")
        armEdgeWakeIfNeeded(on: targetScreen, requiresHotZone: false)
    }

    private func handleBottomEdgeProbe(screen: NSScreen?, inHotZone: Bool) {
        guard let screen, let panel = dockPanel else {
            cancelHoverSwitch()
            cancelEdgeWake()
            return
        }

        let panelScreen = panelCurrentScreen(panel: panel)
        if screen != panelScreen {
            // Pinned to a screen: bottom-edge hot zones on other screens arm nothing, the dwell timer should
            // never start.
            guard hoverScreenSwitchingEnabled else {
                cancelEdgeWake()
                cancelHoverSwitch()
                return
            }
            cancelEdgeWake()
            if hoverSwitchTargetScreen == screen {
                return
            }
            if inHotZone {
                hoverSwitchTimer?.invalidate()
                hoverSwitchTargetScreen = screen
                let timer = Timer(timeInterval: Self.hoverSwitchDwell, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.commitHoverSwitch() }
                }
                RunLoop.main.add(timer, forMode: .common)
                hoverSwitchTimer = timer
            } else {
                cancelHoverSwitch()
            }
            return
        }

        cancelHoverSwitch()
        if inHotZone {
            armEdgeWakeIfNeeded(on: screen)
        } else if edgeWakeTargetScreen == screen, edgeWakeRequiresHotZone {
            cancelEdgeWake()
        }
    }

    /// Pauses edge auto-hide while the NitiaDock menu is open; otherwise the idle timer keeps running and the
    /// taskbar retracts from under the menu.
    func setTaskbarMenuOpen(_ open: Bool) {
        setAutoHideInhibitor(.taskbarMenuOpen, active: open)
    }

    func setAutoHideInhibitor(_ inhibitor: EdgeAutoHideInhibitor, active: Bool) {
        let before = visibilityState
        visibilityState.setInhibitor(inhibitor, active: active)
        if visibilityState != before { reconcilePanelVisibility() }
    }

    func reconcilePanelVisibility() {
        edgeIdleHideTimer?.invalidate()
        edgeIdleHideTimer = nil

        let edgeDelay = settingsStore.edgeAutoHideDelay
        let edgeEnabled = edgeDelay != AppSettingsStore.neverHideDelay
        visibilityState.reconcileEdgeAutoHide(isEnabled: edgeEnabled)

        if edgeDelay == AppSettingsStore.neverHideDelay {
            cancelEdgeWake()
        } else if visibilityState.autoHideInhibitors.isEmpty,
                  !visibilityState.hideReasons.contains(.fullscreen),
                  !visibilityState.hideReasons.contains(.fullscreenTransitionPending) {
            if visibilityState.hideReasons.contains(.edgeAutoHide) {
                if EdgeAutoHideRuntimeRules.canArmWake(state: visibilityState, delay: edgeDelay),
                   let screen = screenContainingMouse(),
                   isMouseInBottomHotZone(on: screen) {
                    armEdgeWakeIfNeeded(on: screen)
                }
            } else if EdgeAutoHideRuntimeRules.canArmIdleHide(state: visibilityState, delay: edgeDelay),
                      isMouseOutsideInteractivePanels() {
                armEdgeIdleHideTimer()
            }
        } else {
            cancelEdgeWake()
        }

        applyPanelVisibility()
    }

    private func updateEdgeIdleTimerFromMouse() {
        guard EdgeAutoHideRuntimeRules.canArmIdleHide(state: visibilityState, delay: settingsStore.edgeAutoHideDelay) else { return }

        if isMouseOutsideInteractivePanels() {
            if edgeIdleHideTimer == nil {
                armEdgeIdleHideTimer()
            }
        } else {
            edgeIdleHideTimer?.invalidate()
            edgeIdleHideTimer = nil
        }
    }

    private func armEdgeIdleHideTimer() {
        guard let interval = EdgeAutoHideRuntimeRules.idleHideInterval(for: settingsStore.edgeAutoHideDelay) else { return }
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.edgeIdleHideTimerFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        edgeIdleHideTimer = timer
    }

    private func edgeIdleHideTimerFired() {
        edgeIdleHideTimer = nil
        guard EdgeAutoHideRuntimeRules.canArmIdleHide(state: visibilityState, delay: settingsStore.edgeAutoHideDelay),
              isMouseOutsideInteractivePanels() else { return }
        visibilityState.setEdgeAutoHidden(true)
        reconcilePanelVisibility()
    }

    private func armEdgeWakeIfNeeded(on screen: NSScreen, requiresHotZone: Bool = true) {
        // Pinned to a screen: wake probing honors only **the screen the panel is actually on** (not the
        // stored fixed screen: when the fixed screen is unplugged and the bar sits on the fallback screen,
        // the fallback screen wakes as usual). This is the single choke point for all arming paths, including
        // the one in reconcilePanelVisibility that goes by screenContainingMouse().
        if !hoverScreenSwitchingEnabled,
           let panel = dockPanel, panelCurrentScreen(panel: panel) != screen {
            return
        }
        guard EdgeAutoHideRuntimeRules.canArmWake(state: visibilityState, delay: settingsStore.edgeAutoHideDelay) else { return }
        if edgeWakeTargetScreen == screen,
           edgeWakeTimer != nil,
           edgeWakeRequiresHotZone == requiresHotZone { return }
        cancelEdgeWake()
        edgeWakeTargetScreen = screen
        edgeWakeRequiresHotZone = requiresHotZone
        let timer = Timer(timeInterval: settingsStore.edgeAutoHideDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.edgeWakeTimerFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        edgeWakeTimer = timer
    }

    private func edgeWakeTimerFired() {
        edgeWakeTimer = nil
        guard let screen = edgeWakeTargetScreen,
              edgeWakeShouldStillFire(on: screen),
              EdgeAutoHideRuntimeRules.canArmWake(state: visibilityState, delay: settingsStore.edgeAutoHideDelay) else {
            edgeWakeTargetScreen = nil
            edgeWakeRequiresHotZone = true
            return
        }
        edgeWakeTargetScreen = nil
        edgeWakeRequiresHotZone = true
        // Moving screens along the way belongs to follow-mouse mode only; in fixed mode arming is already
        // stopped at the choke point above, and this adds a guard against the screen set changing between arm
        // and fire.
        if hoverScreenSwitchingEnabled, let panel = dockPanel, panelCurrentScreen(panel: panel) != screen {
            layoutPanels(contentWidth: lastDesiredWidth, on: screen, animated: false)
        }
        visibilityState.setEdgeAutoHidden(false)
        reconcilePanelVisibility()
    }

    func cancelEdgeWake() {
        edgeWakeTimer?.invalidate()
        edgeWakeTimer = nil
        edgeWakeTargetScreen = nil
        edgeWakeRequiresHotZone = true
    }

    private func edgeWakeShouldStillFire(on screen: NSScreen) -> Bool {
        if edgeWakeRequiresHotZone {
            return isMouseInBottomHotZone(on: screen)
        }
        return screen.frame.contains(NSEvent.mouseLocation)
    }

    func applyPanelVisibility() {
        guard !isSuspendedForPermissionLoss else { return }
        let shouldShow = visibilityState.isVisible
        guard shouldShow != panelsAreVisible else { return }
        panelsAreVisible = shouldShow
        // Badge polling gating follows the taskbar's logical visibility (the orchestration layer merges by
        // "any unit visible"); on resume BadgeStore reads once immediately.
        onLogicalVisibilityChanged?(shouldShow)
        if Self.edgeHoverTraceEnabled { logEdgeHoverTrace(shouldShow: shouldShow) }
        if shouldShow {
            // Fade-in on return from fullscreen (2026-08-30: hard pop-in vs the native entrance animation).
            // Only for reveals that were "hidden because of fullscreen"; the edge auto-hide reveal keeps its
            // instant feel.
            let fadeIn = lastHideWasForFullscreen
            lastHideWasForFullscreen = false
            let fadingPanels = [dockGlassBackgroundPanel, dockPanel, capsulePanel].compactMap { $0 }
            if fadeIn { for panel in fadingPanels { panel.alphaValue = 0 } }
            orderDockSurfaceFront()
            shownCapsulePanel?.orderFrontRegardless()
            if drawerWantsOpen { drawerPanel?.orderFrontRegardless() }
            // Measured: orderOut/orderFront does not drop private Space membership, so this is just a
            // read-back; it is restored only if actually lost.
            pinResidentPanelsIfNeeded()
            if fadeIn {
                NSAnimationContext.runAnimationGroup { ctx in
                    // 0.32s + ease-out (2026-08-31: fade-in slower and softer):
                    // clearly visible in the first half already (feels more prompt), light finish. The
                    // fade-out stays at 0.15s.
                    ctx.duration = 0.32
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    for panel in fadingPanels { panel.animator().alphaValue = 1 }
                }
            }
            // While hidden, a fullscreen Space may have been destroyed, and the system then also removes the
            // panels from other desktops (issue #19). When healthy this is just one SkyLight read and does
            // nothing.
            repairAllSpacesMembershipIfNeeded()
        } else {
            lastHideWasForFullscreen = visibilityState.hideReasons.contains(.fullscreen)
            if lastHideWasForFullscreen { closeDrawer() }
            closeFolderPopup()
            dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
            orderDockSurfaceOut()
            capsulePanel?.orderOut(nil)
            // If the fade-in is interrupted, alpha may be stuck midway; reset to 1 while hidden so the next
            // show carries no leftover value.
            for panel in [dockGlassBackgroundPanel, dockPanel, capsulePanel] { panel?.alphaValue = 1 }
        }
    }

    /// With `DOCK_EDGEHOVER_TRACE=1`, logs one line per actual SHOW/HIDE switch: monotonic clock
    /// (`CACurrentMediaTime`, unaffected by wall-clock adjustments, for measuring switch intervals) + mouse
    /// coordinates + whether in the bottom-edge hot zone + whether inside the taskbar/capsule rect + the
    /// current wake delay setting. Enough to see "why" it switched from this one log line, not just "that" it
    /// switched.
    private func logEdgeHoverTrace(shouldShow: Bool) {
        let mouse = NSEvent.mouseLocation
        let inHotZone = dockPanel.map { isMouseInBottomHotZone(on: panelCurrentScreen(panel: $0)) } ?? false
        let inPanelRect = (dockPanel?.frame.contains(mouse) ?? false) || (capsulePanel?.frame.contains(mouse) ?? false)
        print(String(
            format: "[edgehover] %@ t=%.4f mouse=(%.1f,%.1f) hotZone=%@ panelRect=%@ delay=%.2f reasons=%@",
            shouldShow ? "SHOW" : "HIDE",
            CACurrentMediaTime(),
            mouse.x, mouse.y,
            inHotZone ? "1" : "0",
            inPanelRect ? "1" : "0",
            settingsStore.edgeAutoHideDelay,
            "\(visibilityState.hideReasons)"
        ))
    }

    private func screenContainingMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
    }

    private func isMouseInBottomHotZone(on screen: NSScreen) -> Bool {
        let mouse = NSEvent.mouseLocation
        guard screen.frame.contains(mouse) else { return false }
        return mouse.y - screen.frame.minY <= Self.hoverHotZone
    }

    func isMouseOutsideInteractivePanels() -> Bool {
        let mouse = NSEvent.mouseLocation
        if let dock = dockPanel, dock.frame.contains(mouse) { return false }
        if let capsule = shownCapsulePanel, capsule.frame.contains(mouse) { return false }
        if drawerWantsOpen, let drawer = drawerPanel, drawer.frame.contains(mouse) { return false }
        if folderPopupWantsOpen, let popup = folderPopupPanel, popup.frame.contains(mouse) { return false }
        if forkApproachCorridorContains(mouse) { return false }   // fork: raised bar, see ForkBottomMargin
        // The wake hot zone spans the whole bottom edge of the screen, much wider than the centered narrow
        // taskbar/capsule rect; treating a pointer inside the hot zone but outside the taskbar as "left"
        // would arm idle-hide immediately and fight the wake just triggered (wake -> hide -> wake...
        // flicker).
        // Suppressed only with a finite wake delay: the 999/-1 modes have no such fight and should not change
        // behavior (see the rule comment).
        if EdgeAutoHideRuntimeRules.bottomHotZoneSuppressesIdleHide(delay: settingsStore.edgeAutoHideDelay),
           let dock = dockPanel, isMouseInBottomHotZone(on: panelCurrentScreen(panel: dock)) {
            return false
        }
        return true
    }
}
