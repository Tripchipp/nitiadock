import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

// PanelCoordinator · Window title tooltip: display / grace period / watchdog / mouse monitoring of the
// dedicated panel.
// Split out of PanelCoordinator.swift as an extension on 2026-09-05, moved without changes.
extension PanelCoordinator {
    func handleWindowTitleTooltipEvent(_ event: WindowTitleTooltipEvent) {
        switch event {
        case let .update(request):
            // **No ownership check here anymore.** Requests now have a single source: computed from the
            // pointer position by the tracking area covering the whole taskbar (`StripHoverResolution`), so
            // the pointer is always on that card when one is sent.
            // The guard was only needed when every card sent its own requests (a stuck `isHovering` would
            // grab the panel); the rationale stays in the comment on `WindowTitleTooltipRequest`.
            if windowTitleTooltipSuppressedChipID == request.chipID { return }
            windowTitleTooltipSuppressedChipID = nil
            cancelWindowTitleTooltipLinger()

            HoverTrace.hover(chipID: request.chipID, entered: true)
            windowTitleTooltipRequest = request
            installWindowTitleTooltipMouseMonitors()
            // Swap text and position immediately: no debounce, no fade-in (see the comment on the constant
            // above).
            presentWindowTitleTooltip(request)

        case let .exit(chipID):
            HoverTrace.hover(chipID: chipID, entered: false)
            if windowTitleTooltipSuppressedChipID == chipID {
                windowTitleTooltipSuppressedChipID = nil
            }
            guard windowTitleTooltipRequest?.chipID == chipID else { return }
            // `.exit` now has a plain meaning: **the pointer is not on any card**: the wide gap at a section
            // divider, the padding at the bar's ends, or already off the taskbar. The 2pt gap between cards
            // never gets here:
            // the ownership check bridges it (`StripHoverResolution`), so "A -> empty -> B" is gone at the
            // source.
            //
            // A 90ms grace period remains: no flash when crossing a divider, the neighbor takes over with its
            // `.update`.
            // If the pointer is already off the taskbar, dismiss immediately rather than leaving a stale
            // tooltip up.
            if isPointInsideTaskbarPanels(NSEvent.mouseLocation) {
                scheduleWindowTitleTooltipLinger()
            } else {
                dismissWindowTitleTooltip()
            }
        }
    }

    /// Deferred tooltip dismissal; if another chip's `.update` arrives within the grace period it takes over
    /// this panel directly (see `windowTitleTooltipLingerDelay`).
    private func scheduleWindowTitleTooltipLinger() {
        cancelWindowTitleTooltipLinger()
        let timer = Timer(timeInterval: Self.windowTitleTooltipLingerDelay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.windowTitleTooltipLingerTimer = nil
                self.dismissWindowTitleTooltip()
            }
        }
        windowTitleTooltipLingerTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelWindowTitleTooltipLinger() {
        windowTitleTooltipLingerTimer?.invalidate()
        windowTitleTooltipLingerTimer = nil
    }

    /// Watchdog while the tooltip is on screen: dismiss once the pointer has left the panels that show
    /// tooltips.
    ///
    /// After the rework its only role is **fallback**: who owns the tooltip on the bar is computed live by
    /// the whole-bar tracking area (`StripHoverResolution`), whose own `mouseExited` is the normal dismissal
    /// path.
    /// But when the panel is `orderOut` (edge hide, entering fullscreen) or a chip is pulled out from under
    /// the pointer, the tracking area is not guaranteed to deliver an exit; this 10Hz recheck then keeps the
    /// tooltip from staying up forever (seen as "sometimes the tooltip stays after the mouse moves away").
    ///
    /// **Decides on the whole panel, not the anchor rect**: ownership within the bar belongs to the tracking
    /// area, and checking the anchor again here would only fight it: with the pointer on a divider or narrow
    /// gap the two disagree and the tooltip gets dismissed in a tug-of-war.
    ///
    /// Deliberately a timer that **lives only while the tooltip is visible**, not a permanent `.mouseMoved`
    /// global monitor:
    /// the latter is an event tap that slows mouse events while our own menus are up (that is where the 100ms
    /// stickiness in the project rules came from), not worth opening another one for a tooltip.
    func startWindowTitleTooltipWatchdog() {
        guard windowTitleTooltipWatchdog == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.windowTitleTooltipPanel?.isVisible == true,
                      self.windowTitleTooltipRequest != nil else {
                    self.stopWindowTitleTooltipWatchdog()
                    return
                }
                guard !self.isPointInsideTaskbarPanels(NSEvent.mouseLocation) else { return }
                self.dismissWindowTitleTooltip()
            }
        }
        windowTitleTooltipWatchdog = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Whether the pointer is still over "the panels that show tooltips" (the taskbar itself + capsule + an
    /// open drawer).
    /// The whole window frame is enough: the only excess is the 20pt transparent shadow margin, and the grace
    /// period expiring dismisses it anyway.
    private func isPointInsideTaskbarPanels(_ point: CGPoint) -> Bool {
        if let dock = dockPanel, dock.frame.contains(point) { return true }
        if let capsule = shownCapsulePanel, capsule.frame.contains(point) { return true }
        if drawerWantsOpen, let drawer = drawerPanel, drawer.frame.contains(point) { return true }
        return false
    }

    private func stopWindowTitleTooltipWatchdog() {
        windowTitleTooltipWatchdog?.invalidate()
        windowTitleTooltipWatchdog = nil
    }

    private func presentWindowTitleTooltip(_ request: WindowTitleTooltipRequest) {
        guard request.anchorVisibleRect != .zero else { return }
        onAccessoryWillOpen?(self, .tooltip)
        let traceStart = CACurrentMediaTime()
        let traceCold = windowTitleTooltipPanel?.isVisible != true
        defer { HoverTrace.present(chipID: request.chipID, cold: traceCold,
                                   elapsed: CACurrentMediaTime() - traceStart) }
        let panel: NSPanel
        if let existing = windowTitleTooltipPanel {
            panel = existing
        } else {
            let created = makeFloatingPanel(contentRect: .zero, usesLiquidGlass: usesLiquidGlass)
            configurePanel(created, backgroundColor: .clear, appliesLevelOverride: false)
            created.ignoresMouseEvents = true
            windowTitleTooltipPanel = created
            panel = created
        }

        // The whole tooltip scales with the taskbar size (2026-08-17). `DockSize.scale` is already normalized
        // to the medium size, which is always 1.0 -> medium keeps the measured native pixels exactly. Size
        // switches go through the existing `beginDockSizeChange` transaction, which dismisses the tooltip
        // first, so no extra invalidation is needed here.
        let style = WindowTitleTooltipStyle(scale: settingsStore.dockSize.scale)
        let contentHost: ManualPanelHost
        if let hosting = windowTitleTooltipHosting, let existingHost = windowTitleTooltipHost {
            hosting.rootView = WindowTitleTooltipView(title: request.title, style: style,
                                                    usesLiquidGlass: usesLiquidGlass)
            contentHost = existingHost
        } else {
            let hosting = NSHostingView(rootView: WindowTitleTooltipView(title: request.title, style: style,
                                                          usesLiquidGlass: usesLiquidGlass))
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            contentHost = ManualPanelHost(contentView: hosting, in: panel)
            windowTitleTooltipHosting = hosting
            windowTitleTooltipHost = contentHost
        }
        panel.layoutIfNeeded()
        let size = contentHost.fittingSize
        guard size.width > 0, size.height > 0 else { return }

        let anchorPoint = CGPoint(x: request.anchorVisibleRect.midX, y: request.anchorVisibleRect.midY)
        // **The anchor must be on the screen the taskbar is on.** Chips that show tooltips all live in the
        // taskbar / drawer, which are always on the same screen; an anchor on another screen can only mean
        // that card's cached screen rect is stale (the panel changed screens).
        // Then rather skip this frame: `ScreenRectReader` now reports once more when the window moves, so the
        // next frame is correct. Showing it anyway is the "tooltip appears on the screen without a taskbar"
        // bug.
        let dockScreen = dockPanel.map { panelCurrentScreen(panel: $0) }
        if let dockScreen, !dockScreen.frame.contains(anchorPoint) { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchorPoint) })
            ?? dockScreen
            ?? NSScreen.lastResort
        let target = PanelGeometry.windowTitleTooltipTargetFrame(
            anchorVisibleRect: request.anchorVisibleRect,
            size: size,
            tipGap: style.tipGap,
            on: Self.screenGeometry(screen)
        )
        panel.setFrame(target, display: true)

        // **No fade-in.** Measured input -> tooltip on screen takes only 2.9–9.5ms, the pipeline is already
        // instant; the "not as crisp as native" impression came from the **softness** of the 0.1s fade-in,
        // not slowness (the native Dock's app name appears directly). Likewise leaving dismisses directly,
        // see the `.exit` branch.
        panel.alphaValue = 1
        if !panel.isVisible { panel.orderFrontRegardless() }
        pinOverlappingPanelIfNeeded(panel)
        startWindowTitleTooltipWatchdog()
    }

    /// **Idempotent**: every `.update` calls it (switching chips no longer dismisses then reinstalls), and
    /// installing twice would leak the old monitor.
    private func installWindowTitleTooltipMouseMonitors() {
        guard windowTitleTooltipLocalMonitor == nil, windowTitleTooltipGlobalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        windowTitleTooltipLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
            return event
        }
        windowTitleTooltipGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
        }
    }

    func dismissWindowTitleTooltip(suppressCurrentUntilExit: Bool = false) {
        if suppressCurrentUntilExit, let chipID = windowTitleTooltipRequest?.chipID {
            windowTitleTooltipSuppressedChipID = chipID
        }
        cancelWindowTitleTooltipLinger()
        stopWindowTitleTooltipWatchdog()
        windowTitleTooltipRequest = nil
        if let monitor = windowTitleTooltipLocalMonitor {
            NSEvent.removeMonitor(monitor)
            windowTitleTooltipLocalMonitor = nil
        }
        if let monitor = windowTitleTooltipGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            windowTitleTooltipGlobalMonitor = nil
        }
        windowTitleTooltipPanel?.alphaValue = 0
        windowTitleTooltipPanel?.orderOut(nil)
    }
}
