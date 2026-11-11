import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

// PanelCoordinator · Fullscreen: observers, synchronous CG probe, asynchronous AX probe, predictive hide and
// rollback for the green button / Space switch.
// Split out of PanelCoordinator.swift as an extension on 2026-09-05, moved without changes.
struct FullscreenIntentTransaction {
    let generation: UInt64
    let pid: pid_t
    let focusedWindowID: CGWindowID
    let screenCGFrame: CGRect
}
struct FullscreenSpaceHold {
    let generation: UInt64
    let pid: pid_t?
    let screenCGFrame: CGRect?
}

extension PanelCoordinator {
    // MARK: - Fullscreen Monitor

    func setupFullscreenMonitor() {
        let nc = NSWorkspace.shared.notificationCenter
        // Token-based observers (the repo-wide convention; selector-based ones are unowned-unsafe). queue nil
        // = runs synchronously on the posting thread; both notifications are posted on the main thread
        // anyway, so timing is identical to the old selector path. assumeIsolated only tells the compiler
        // that fact and adds no extra hop (the fullscreen predictive hide is sensitive to that hop).
        workspaceObserverTokens.append(nc.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSpaceChange() }
        })
        workspaceObserverTokens.append(nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleAppActivated(note) }
        })
        lastActiveApplicationPID = NSWorkspace.shared.runningApplications.first(where: { $0.isActive })?.processIdentifier
        fullscreenReconcileTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.fullscreenReconcileIfNeeded() }
        }
        fullscreenReconcileTimer?.tolerance = 0.5
    }

    /// The orchestration layer connects / disconnects fullscreen intent routing. Disconnecting cancels
    /// in-flight predictions (setting turned off, permission suspended, unit torn down).
    func setFullscreenIntentRouting(enabled: Bool) {
        fullscreenIntentRoutingEnabled = enabled && !isSuspendedForPermissionLoss
        guard !fullscreenIntentRoutingEnabled else { return }
        if let transaction = fullscreenIntentTransaction {
            cancelFullscreenIntent(generation: transaction.generation, reason: "disabled")
        }
        if let spaceGeneration = fullscreenSpaceIntentGeneration {
            cancelFullscreenSpaceArrowIntent(generation: spaceGeneration, reason: "disabled")
        }
    }

    private func handleSpaceChange() {
        let spaceHoldGeneration = beginFullscreenSpaceHold(
            pid: lastActiveApplicationPID,
            confirmationDelay: FullscreenSpaceHoldDecision.postSpaceConfirmationDelay
        )
        // Sync CG check: fires before the panel has a chance to appear, no AX = no main-thread risk
        let cgFullscreen = checkFullscreenViaCGSync()
        applyFullscreenVisibility(
            cgFullscreen,
            source: "space-cg",
            expectedIntentGeneration: fullscreenIntentTransaction?.generation,
            pid: lastActiveApplicationPID,
            screenCGFrame: currentPanelScreenCGFrame(),
            expectedSpaceHoldGeneration: spaceHoldGeneration
        )
        // Async AX secondary check: catches edge cases CG misses (e.g. games on a non-zero layer)
        if !cgFullscreen || fullscreenIntentTransaction == nil {
            triggerAsyncFullscreenCheck(
                expectedSpaceHoldGeneration: spaceHoldGeneration,
                source: "space-ax"
            )
        }
        // Fallback: membership can also be lost outside the show/hide path (issue #19), and a desktop switch
        // is the only moment the user would notice.
        repairAllSpacesMembershipIfNeeded()
    }

    private func handleAppActivated(_ note: Notification) {
        // Use the "just activated app" carried by the notification, not the lagging frontmostApplication
        // (project rule)
        let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        lastActiveApplicationPID = activated?.processIdentifier
        let spaceHoldGeneration = beginFullscreenSpaceHold(
            pid: lastActiveApplicationPID,
            confirmationDelay: FullscreenSpaceHoldDecision.activationFallbackDelay
        )
        cancelFullscreenIntentIfContextChanged(activePID: activated?.processIdentifier)
        triggerAsyncFullscreenCheck(
            pid: lastActiveApplicationPID,
            expectedSpaceHoldGeneration: spaceHoldGeneration,
            source: "app-activation-ax"
        )
    }

    // MARK: - Sync CG fullscreen probe (main thread only, no AX)

    private func checkFullscreenViaCGSync() -> Bool {
        guard let panel = dockPanel else { return false }
        let screen = panelCurrentScreen(panel: panel)
        let screenCGFrame = Self.toCGRect(screen)
        let ourPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard let candidate = WindowLiftCGWindowProbe.frontmostLargeWindow(
            on: screenCGFrame,
            excludingPID: ourPID
        ) else { return false }

        let cgBounds = candidate.quartzFrame
        let t: CGFloat = 8
        return abs(cgBounds.width  - screenCGFrame.width)  < t
            && abs(cgBounds.height - screenCGFrame.height) < t
            && abs(cgBounds.minX   - screenCGFrame.minX)   < t
            && abs(cgBounds.minY   - screenCGFrame.minY)   < t
    }

    // MARK: - Async AX fullscreen probe (secondary / fallback)

    private func triggerAsyncFullscreenCheck(
        pid explicitPID: pid_t? = nil,
        expectedSpaceHoldGeneration explicitSpaceHoldGeneration: UInt64? = nil,
        isFinalSpaceHoldWindowedConfirmation: Bool = false,
        isFinalSpaceIntentVerdict: Bool = false,
        source: String = "ax"
    ) {
        guard let panel = dockPanel else { return }
        // Convert to CG coords on main thread; AX kAXPositionAttribute also uses CG (top-left origin)
        let screenCGFrame = Self.toCGRect(panelCurrentScreen(panel: panel))
        let frontPID = explicitPID ?? lastActiveApplicationPID
        fullscreenProbeGeneration &+= 1
        let probeGeneration = fullscreenProbeGeneration
        let expectedIntentGeneration = fullscreenIntentTransaction?.generation
        let expectedSpaceHoldGeneration = explicitSpaceHoldGeneration ?? fullscreenSpaceHold?.generation
        Task.detached { [weak self] in
            let verdict = Self.detectFullscreenViaAX(pid: frontPID, screenCGFrame: screenCGFrame)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard probeGeneration == self.fullscreenProbeGeneration else {
                    return
                }
                // Tri-state -> what is handed to the existing `applyFullscreenVisibility` is still a boolean;
                // the hold / 120ms confirmation / final-verdict sequence is unchanged. What changes is only
                // where that boolean comes from when "the focused window is on another screen":
                // with multiple screens (③④, and when the fixed-mode bar is not on the focused screen) AX has
                // nothing to say about this screen, so ask SkyLight for this screen's current Space instead;
                // unreadable means no information, **not false**, otherwise screen B's bar would pop up over
                // B's fullscreen Space. The final-verdict call must conclude, so with no information fall
                // back to this screen's synchronous CG probe.
                let fullscreen: Bool
                let resolvedSource: String
                switch verdict {
                case .fullscreen:
                    fullscreen = true
                    resolvedSource = source
                case .windowed:
                    fullscreen = false
                    resolvedSource = source
                case .notOnThisScreen:
                    guard Self.slsVerdictEnabled else {
                        fullscreen = false
                        resolvedSource = source
                        break
                    }
                    if let fromSpace = self.fullscreenVerdictFromSpaceLayout() {
                        fullscreen = fromSpace
                        resolvedSource = "\(source)-sls"
                    } else if isFinalSpaceHoldWindowedConfirmation || isFinalSpaceIntentVerdict {
                        fullscreen = self.checkFullscreenViaCGSync()
                        resolvedSource = "\(source)-cgfallback"
                    } else {
                        return
                    }
                }
                self.applyFullscreenVisibility(
                    fullscreen,
                    source: resolvedSource,
                    expectedIntentGeneration: expectedIntentGeneration,
                    pid: frontPID,
                    screenCGFrame: screenCGFrame,
                    expectedSpaceHoldGeneration: expectedSpaceHoldGeneration,
                    isFinalSpaceHoldWindowedConfirmation: isFinalSpaceHoldWindowedConfirmation,
                    isFinalSpaceIntentVerdict: isFinalSpaceIntentVerdict
                )
            }
        }
    }

    private func fullscreenReconcileIfNeeded() {
        guard visibilityState.hideReasons.contains(.fullscreen) else { return }
        triggerAsyncFullscreenCheck()
    }

    private func applyFullscreenVisibility(
        _ isFullscreen: Bool,
        source: String,
        expectedIntentGeneration: UInt64? = nil,
        pid: pid_t? = nil,
        screenCGFrame: CGRect? = nil,
        expectedSpaceHoldGeneration: UInt64? = nil,
        isFinalSpaceHoldWindowedConfirmation: Bool = false,
        isFinalSpaceIntentVerdict: Bool = false
    ) {
        // Arrow-key prediction in progress: the prediction concludes this stretch itself, skipping the
        // regular decision below.
        if let spaceGeneration = fullscreenSpaceIntentGeneration {
            if isFullscreen {
                guard visibilityState.confirmFullscreenTransition(generation: spaceGeneration) else {
                    return
                }
                clearFullscreenSpaceArrowIntent()
                fullscreenIntentLogger.notice(
                    "space-confirmed source=\(source, privacy: .public) generation=\(spaceGeneration, privacy: .public)"
                )
                closeDrawer()
                closeFolderPopup()
                dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
                reconcilePanelVisibility()
                logFullscreenVerdict(true, source: source)
                return
            }
            // **The false verdict at the moment of the Space switch cannot be trusted.** Measured 2026-08-09:
            // going desktop -> fullscreen, `space-cg` always returns false at notification time (a false
            // transitional verdict); undoing on that basis puts the just-hidden taskbar back over the
            // fullscreen picture. Both the flicker and "taskbar stays on top of the fullscreen app" come from
            // this.
            // `FullscreenSpaceHold` waits 120ms before deciding in order to dodge the same trap, and the same
            // cadence is reused here.
            guard isFinalSpaceIntentVerdict else {
                if source == "space-cg" {
                    scheduleFullscreenSpaceIntentVerdict(generation: spaceGeneration)
                }
                return
            }
            cancelFullscreenSpaceArrowIntent(generation: spaceGeneration, reason: "space-windowed")
        }
        switch FullscreenSpaceHoldDecision.disposition(
            isFullscreenVerdict: isFullscreen,
            expectedGeneration: expectedSpaceHoldGeneration,
            activeGeneration: fullscreenSpaceHold?.generation,
            isFinalWindowedConfirmation: isFinalSpaceHoldWindowedConfirmation
        ) {
        case .stale:
            return
        case .hold:
            return
        case .apply:
            if let hold = fullscreenSpaceHold {
                finishFullscreenSpaceHold(generation: hold.generation)
            }
        }
        if isFullscreen {
            if let transaction = fullscreenIntentTransaction {
                guard expectedIntentGeneration == transaction.generation,
                      pid == transaction.pid,
                      screenCGFrame == transaction.screenCGFrame,
                      isFullscreenIntentContextCurrent(transaction),
                      visibilityState.confirmFullscreenTransition(generation: transaction.generation) else {
                    return
                }
                finishFullscreenIntentTransaction()
                fullscreenIntentLogger.notice(
                    "confirmed source=\(source, privacy: .public) generation=\(transaction.generation, privacy: .public)"
                )
            } else {
                visibilityState.setFullscreen(true)
            }
            closeDrawer()
            closeFolderPopup()
            dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
        } else {
            if fullscreenIntentTransaction != nil { return }
            visibilityState.setFullscreen(false)
        }
        reconcilePanelVisibility()
        logFullscreenVerdict(isFullscreen, source: source)
    }

    /// The only forensic line when the taskbar is hidden/shown. **Must carry the source and the hide
    /// reason**: when a user reports "the taskbar is gone", only those two can tell which decision did it
    /// (issue #19 was intractable because only active= was logged).
    private func logFullscreenVerdict(_ isFullscreen: Bool, source: String) {
        let reasons = visibilityState.hideReasons
        var parts: [String] = []
        if reasons.contains(.fullscreen) { parts.append("fullscreen") }
        if reasons.contains(.fullscreenTransitionPending) { parts.append("pending") }
        if reasons.contains(.edgeAutoHide) { parts.append("edge") }
        let reasonText = parts.isEmpty ? "none" : parts.joined(separator: "+")
        logger.info(
            "[fullscreen] active=\(isFullscreen, privacy: .public) source=\(source, privacy: .public) reasons=\(reasonText, privacy: .public) pid=\(self.lastActiveApplicationPID ?? -1, privacy: .public)"
        )
    }

    /// The orchestration layer **broadcasts** the tap's request to every unit; the `screenCGFrame` guard
    /// makes only that screen's unit act (one screen entering fullscreen hides only that screen's bar).
    func beginFullscreenIntent(_ request: FullscreenIntentRequest) {
        guard fullscreenIntentRoutingEnabled,
              fullscreenIntentTransaction == nil,
              request.screenCGFrame == currentPanelScreenCGFrame(),
              lastActiveApplicationPID == request.pid else {
            return
        }
        fullscreenIntentGeneration &+= 1
        let generation = fullscreenIntentGeneration
        fullscreenProbeGeneration &+= 1
        fullscreenIntentTransaction = FullscreenIntentTransaction(
            generation: generation,
            pid: request.pid,
            focusedWindowID: request.focusedWindowID,
            screenCGFrame: request.screenCGFrame
        )
        fullscreenIntentTimeoutTimer?.invalidate()
        visibilityState.beginFullscreenTransition(generation: generation)

        edgeIdleHideTimer?.invalidate()
        edgeIdleHideTimer = nil
        cancelEdgeWake()

        orderOutPanelsForFullscreenPrediction()
        fullscreenIntentLogger.notice(
            "pending source=\(request.source.rawValue, privacy: .public) generation=\(generation, privacy: .public) pid=\(request.pid, privacy: .public)"
        )

        let timer = Timer(timeInterval: 1.2, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelFullscreenIntent(generation: generation, reason: "timeout")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fullscreenIntentTimeoutTimer = timer

        DispatchQueue.main.async { [weak self] in
            guard let self, self.fullscreenIntentTransaction?.generation == generation else { return }
            self.reconcilePanelVisibility()
        }
    }

    func cancelFullscreenIntent(generation: UInt64, reason: String) {
        guard fullscreenIntentTransaction?.generation == generation,
              visibilityState.timeoutFullscreenTransition(generation: generation) else {
            return
        }
        finishFullscreenIntentTransaction()
        fullscreenProbeGeneration &+= 1
        fullscreenIntentLogger.notice(
            "cancelled reason=\(reason, privacy: .public) generation=\(generation, privacy: .public)"
        )
        reconcilePanelVisibility()
    }

    private func finishFullscreenIntentTransaction() {
        fullscreenIntentTransaction = nil
        fullscreenIntentTimeoutTimer?.invalidate()
        fullscreenIntentTimeoutTimer = nil
    }

    /// After a prediction hits, move every panel out of WindowServer. The drawer/popups must take the
    /// "immediate" path: input is already held by the tap and cannot wait for a fade-out.
    private func orderOutPanelsForFullscreenPrediction() {
        edgeIdleHideTimer?.invalidate()
        edgeIdleHideTimer = nil
        cancelEdgeWake()

        dragController.cancelDrag()
        closeDrawerImmediately()
        closeFolderPopup(immediately: true)
        dismissWindowTitleTooltip(suppressCurrentUntilExit: true)

        panelsAreVisible = false
        // The prediction path is also "hidden because of fullscreen": the later reveal fades in as well.
        lastHideWasForFullscreen = true
        // The fullscreen prediction's fast hide path bypasses applyPanelVisibility, so badge gating has to be
        // notified separately.
        onLogicalVisibilityChanged?(false)
        orderDockSurfaceOut()
        capsulePanel?.orderOut(nil)
        drawerPanel?.orderOut(nil)
        folderPopupPanel?.orderOut(nil)
        windowTitleTooltipPanel?.orderOut(nil)
    }

    // MARK: - Predictive hide when switching to a fullscreen Space (Control+Left/Right and three-finger horizontal swipe)

    /// When switching from a regular desktop to a fullscreen Space, the system's Space-change notification
    /// arrives after WindowServer captures the transition snapshot, so hiding after the fact is always too
    /// late (measured). Hide here **before the input is delivered**:
    /// arrow keys lead the Space switch by about `550ms`, three-finger swipes by about `950–1130ms`; both
    /// measured as sufficient.
    ///
    /// The trigger condition "the adjacent Space in the target direction must be a fullscreen Space" is
    /// already gated in `FullscreenIntentMonitor`, so whatever reaches here is really entering a fullscreen
    /// Space.
    func beginFullscreenSpaceIntent(direction: SpaceSwitchDirection) {
        guard fullscreenIntentRoutingEnabled,
              fullscreenIntentTransaction == nil,
              fullscreenSpaceIntentGeneration == nil,
              !isSuspendedForPermissionLoss,
              // Already in a fullscreen Space (taskbar already hidden) -> nothing to flicker, stay out.
              !visibilityState.hideReasons.contains(.fullscreen) else {
            return
        }
        fullscreenIntentGeneration &+= 1
        let generation = fullscreenIntentGeneration
        fullscreenSpaceIntentGeneration = generation
        fullscreenProbeGeneration &+= 1
        visibilityState.beginFullscreenTransition(generation: generation)

        // Fade out, then hide (the enter/exit animation request of 2026-08-30). **Only this Space path may
        // fade**:
        // arrow keys lead the Space switch by ~550ms, three-finger swipes by ~950–1130ms (measured), so when
        // the 0.15s fade-out ends there is ample margin before WindowServer captures the transition snapshot;
        // the green-button path leads by only tens of ms and must stay a synchronous instant orderOut. The
        // handoff returns right after scheduling the fade-out, so input is not blocked.
        // The logical state is set to "hidden" immediately: otherwise the async reconcile at the end of this
        // function would see shouldShow=false, panelsAreVisible=true and take the hard orderOut, bypassing
        // the fade. The visual orderOut waits for the fade to finish.
        panelsAreVisible = false
        lastHideWasForFullscreen = true
        onLogicalVisibilityChanged?(false)
        let fadingPanels = [dockGlassBackgroundPanel, dockPanel, capsulePanel].compactMap { $0 }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            for panel in fadingPanels { panel.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // The prediction may have been cancelled during the fade (timeout / rejected by the final
                // verdict); then the bar should not hide, restoring alpha is enough.
                guard self.fullscreenSpaceIntentGeneration == generation else {
                    for panel in fadingPanels { panel.alphaValue = 1 }
                    return
                }
                self.orderOutPanelsForFullscreenPrediction()
                // Reset alpha once hidden: the next show (by any path) carries no leftover value.
                for panel in fadingPanels { panel.alphaValue = 1 }
            }
        })
        fullscreenIntentLogger.notice(
            "space-pending generation=\(generation, privacy: .public) direction=\(direction.rawValue, privacy: .public)"
        )

        // 2s rather than 1.2s: measured input-to-fullscreen confirmation takes 1.05s, leaving 1.2s only 130ms
        // of margin; one slow turn of the system would time out and pop the taskbar back over the fullscreen
        // picture, exactly the glitch this feature removes.
        let timer = Timer(timeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelFullscreenSpaceArrowIntent(generation: generation, reason: "timeout")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fullscreenSpaceIntentTimer = timer

        DispatchQueue.main.async { [weak self] in
            guard let self, self.fullscreenSpaceIntentGeneration == generation else { return }
            self.reconcilePanelVisibility()
        }
    }

    private func cancelFullscreenSpaceArrowIntent(generation: UInt64, reason: String) {
        guard fullscreenSpaceIntentGeneration == generation,
              visibilityState.timeoutFullscreenTransition(generation: generation) else {
            return
        }
        clearFullscreenSpaceArrowIntent()
        fullscreenProbeGeneration &+= 1
        fullscreenIntentLogger.notice(
            "space-cancelled reason=\(reason, privacy: .public) generation=\(generation, privacy: .public)"
        )
        reconcilePanelVisibility()
    }

    func clearFullscreenSpaceArrowIntent() {
        fullscreenSpaceIntentGeneration = nil
        fullscreenSpaceIntentTimer?.invalidate()
        fullscreenSpaceIntentTimer = nil
        fullscreenSpaceIntentVerdictTimer?.invalidate()
        fullscreenSpaceIntentVerdictTimer = nil
    }

    /// The Space switch is complete, but the CG verdict at that moment is not trustworthy. Wait the same
    /// 120ms as `FullscreenSpaceHold`, then take the final verdict from CG (AX as fallback); the prediction
    /// is only undone if the final verdict says "not fullscreen".
    private func scheduleFullscreenSpaceIntentVerdict(generation: UInt64) {
        guard fullscreenSpaceIntentVerdictTimer == nil else { return }
        let timer = Timer(
            timeInterval: FullscreenSpaceHoldDecision.postSpaceConfirmationDelay,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resolveFullscreenSpaceArrowIntent(generation: generation)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fullscreenSpaceIntentVerdictTimer = timer
    }

    private func resolveFullscreenSpaceArrowIntent(generation: UInt64) {
        guard fullscreenSpaceIntentGeneration == generation else { return }
        fullscreenSpaceIntentVerdictTimer = nil
        if checkFullscreenViaCGSync() {
            applyFullscreenVisibility(true, source: "space-intent-delayed-cg")
            return
        }
        triggerAsyncFullscreenCheck(
            isFinalSpaceIntentVerdict: true,
            source: "space-intent-final-ax"
        )
    }

    @discardableResult
    private func beginFullscreenSpaceHold(
        pid: pid_t?,
        confirmationDelay: TimeInterval
    ) -> UInt64? {
        guard FullscreenSpaceHoldDecision.shouldBegin(
            isFullscreen: visibilityState.hideReasons.contains(.fullscreen),
            hasInputIntent: fullscreenIntentTransaction != nil || fullscreenSpaceIntentGeneration != nil
        ) else {
            return nil
        }

        let screenCGFrame = currentPanelScreenCGFrame()
        let hold: FullscreenSpaceHold
        if let current = fullscreenSpaceHold,
           current.pid == pid,
           current.screenCGFrame == screenCGFrame {
            hold = current
        } else {
            fullscreenSpaceHoldGeneration &+= 1
            fullscreenProbeGeneration &+= 1
            hold = FullscreenSpaceHold(
                generation: fullscreenSpaceHoldGeneration,
                pid: pid,
                screenCGFrame: screenCGFrame
            )
            fullscreenSpaceHold = hold
        }
        scheduleFullscreenSpaceHoldConfirmation(
            generation: hold.generation,
            after: confirmationDelay
        )
        return hold.generation
    }

    private func scheduleFullscreenSpaceHoldConfirmation(
        generation: UInt64,
        after delay: TimeInterval
    ) {
        fullscreenSpaceHoldTimer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.confirmFullscreenSpaceHoldWindowed(generation: generation)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fullscreenSpaceHoldTimer = timer
    }

    private func confirmFullscreenSpaceHoldWindowed(generation: UInt64) {
        guard let hold = fullscreenSpaceHold,
              hold.generation == generation else {
            return
        }
        guard hold.pid == lastActiveApplicationPID,
              hold.screenCGFrame == currentPanelScreenCGFrame() else {
            finishFullscreenSpaceHold(generation: generation)
            triggerAsyncFullscreenCheck(pid: lastActiveApplicationPID)
            return
        }
        fullscreenSpaceHoldTimer = nil
        // A CG true at 120ms is no longer final: when exiting fullscreen CG lags by 0.4~0.8s (measured
        // 2026-08-30), so a true now is likely still a transitional afterimage, and concluding on
        // it brings back "wait 5 seconds for reconciliation".
        // Always let the final AX check decide: AX already flips to false when the exit animation starts
        // (measured the same day, earlier than CG) and is the only trustworthy signal in this direction. The
        // cost for fullscreen -> fullscreen switches is one more AX read and confirmation ~100 ms later,
        // during which the bar is hidden anyway. The CG reading is kept in source so forensics can tell the
        // two paths apart.
        let cgFullscreen = checkFullscreenViaCGSync()
        triggerAsyncFullscreenCheck(
            pid: hold.pid,
            expectedSpaceHoldGeneration: generation,
            isFinalSpaceHoldWindowedConfirmation: true,
            source: cgFullscreen ? "space-hold-final-ax-cgtrue" : "space-hold-final-ax"
        )
    }

    private func finishFullscreenSpaceHold(generation: UInt64) {
        guard fullscreenSpaceHold?.generation == generation else { return }
        fullscreenSpaceHoldTimer?.invalidate()
        fullscreenSpaceHoldTimer = nil
        fullscreenSpaceHold = nil
    }

    func cancelFullscreenIntentIfContextChanged(activePID: pid_t? = nil) {
        guard let transaction = fullscreenIntentTransaction else { return }
        let currentPID = activePID ?? lastActiveApplicationPID
        guard currentPID != transaction.pid || currentPanelScreenCGFrame() != transaction.screenCGFrame else {
            return
        }
        cancelFullscreenIntent(generation: transaction.generation, reason: "context-changed")
    }

    private func isFullscreenIntentContextCurrent(_ transaction: FullscreenIntentTransaction) -> Bool {
        NSRunningApplication(processIdentifier: transaction.pid)?.isActive == true
            && currentPanelScreenCGFrame() == transaction.screenCGFrame
    }

    func handleFullscreenIntentContextChange(
        _ change: FullscreenIntentMonitor.ContextChange
    ) {
        if case let .activeApplication(pid) = change {
            lastActiveApplicationPID = pid
        }
        guard let transaction = fullscreenIntentTransaction else { return }
        switch change {
        case let .activeApplication(pid):
            if pid != transaction.pid {
                cancelFullscreenIntent(generation: transaction.generation, reason: "app-changed")
            }
        case .focusedWindow:
            cancelFullscreenIntent(generation: transaction.generation, reason: "focus-changed")
        case let .windowDestroyed(windowID):
            if windowID == nil || windowID == transaction.focusedWindowID {
                cancelFullscreenIntent(generation: transaction.generation, reason: "window-destroyed")
            }
        }
    }

    func currentPanelScreenCGFrame() -> CGRect? {
        guard let panel = dockPanel else { return nil }
        return Self.toCGRect(panelCurrentScreen(panel: panel))
    }

    /// An unreadable focused window (nil pid / no focused window) is still `.windowed`, exactly equivalent to
    /// the false from before the tri-state.
    nonisolated private static func detectFullscreenViaAX(pid: pid_t?, screenCGFrame: CGRect) -> FullscreenAXVerdict {
        guard let pid else { return .windowed }
        // Own process: never fullscreen, and AX against ourselves must not run off the main thread.
        guard pid != ProcessInfo.processInfo.processIdentifier else { return .windowed }
        let reader = AXWindowReader()
        let appElement = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(appElement, 0.5)

        guard let focused = reader.elementAttribute(kAXFocusedWindowAttribute as CFString, from: appElement) else {
            return .windowed
        }
        _ = AXUIElementSetMessagingTimeout(focused, 0.5)

        let role = reader.stringAttribute(kAXRoleAttribute as CFString, from: focused, maxAttempts: 1)
        let isAXFullscreen = reader.boolAttribute("AXFullScreen" as CFString, from: focused, maxAttempts: 1) ?? false
        // AX kAXPositionAttribute uses CG coordinates (top-left origin); matches screenCGFrame directly
        let windowFrame = reader.frame(of: focused, maxAttempts: 1)

        return FullscreenWindowClassifier.classify(
            role: role,
            isAXFullscreen: isAXFullscreen,
            windowFrame: windowFrame,
            screenCGFrame: screenCGFrame
        )
    }

    /// When the focused window is on another screen, this screen's bar asks SkyLight "is this screen's
    /// current Space a native fullscreen Space" (`type == 4`, isolated per display, 0.13ms per call,
    /// measured). Unreadable -> nil = "no information".
    private func fullscreenVerdictFromSpaceLayout() -> Bool? {
        guard let panel = dockPanel,
              let uuid = DisplayIdentity.uuidString(for: panelCurrentScreen(panel: panel)),
              let layout = ManagedSpaceLayoutReader.layout(forDisplayUUID: uuid) else { return nil }
        return layout.fullscreenSpaceIDs.contains(layout.currentSpaceID)
    }
}
