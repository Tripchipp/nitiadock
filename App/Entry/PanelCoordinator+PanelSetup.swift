import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

// PanelCoordinator · Panel setup: creation, configuration and first-frame presentation of the three permanent
// panels (taskbar / glass backplate / capsule).
// Split out of PanelCoordinator.swift as an extension on 2026-09-05, moved without changes.
extension PanelCoordinator {
    func setupDockPanel() {
        let screen = resolvedPinnedScreen() ?? NSScreen.lastResort
        let s = screen.frame
        let legacyInitialFrame = NSRect(
            x: s.minX,
            y: s.minY + layoutMetrics.bottomGap - Self.shadowPadding,
            width: s.width,
            height: windowHeight
        )

        let glassBackground = makeTaskbarGlassBackground(contentPanelFrame: legacyInitialFrame)
        let usesLiquidGlass = glassBackground != nil

        // The content window **always** uses the frame including the 20pt transparent shadow margin, in glass
        // mode too: the drop shadow lives there, and the drop zone / spring zone / "mouse still on the bar"
        // checks are all converted as "window frame minus shadowPadding" (`dragDropZones` / `springZone` /
        // `isMouseOutsideInteractivePanels`).
        // Shrinking the window would shift that whole batch of coordinates.
        let panel = makeFloatingPanel(contentRect: legacyInitialFrame, usesLiquidGlass: usesLiquidGlass)
        configurePanel(panel, backgroundColor: NSColor(white: 1.0, alpha: 0.0), appliesLevelOverride: true)

        let hosting = NSHostingView(rootView: DockStripView(
            usesLiquidGlass: usesLiquidGlass,
            stripSurfaceID: stripSurfaceID,
            displayUUID: fixedUnitDisplayUUID,
            onFolderPopupToggle: { [weak self] path, anchorRect in
                self?.toggleFolderPopup(path: path, anchorVisibleRect: anchorRect)
            },
            onShelfPopupToggle: { [weak self] anchorRect in
                self?.toggleShelfPopup(anchorVisibleRect: anchorRect)
            },
            onTrashPopupToggle: { [weak self] anchorRect in
                self?.toggleTrashPopup(anchorVisibleRect: anchorRect)
            },
            onAddFolder: { [weak self] in self?.onAddFolder() },
            onMoveExternalFiles: { [weak self] urls, path in
                self?.moveExternalFiles(urls, into: path)
            },
            onWindowTitleTooltipEvent: { [weak self] event in
                self?.handleWindowTitleTooltipEvent(event)
            },
            onRequestTaskbarMenu: { [weak self] event, view in
                self?.onRequestTaskbarMenu?(event, view)
            },
            // Label grew or shrank: open a window in which the panel follows the content width per frame (see
            // `beginLabelWidthFollow`).
            onLabelWidthChange: { [weak self] starting in self?.beginLabelWidthFollow(starting: starting) },
            onLabelBoxWidthTick: { [weak self] id, width in self?.labelBoxWidthDidTick(chipID: id, width: width) }
        ).environmentObject(runtime).environmentObject(drawerStore).environmentObject(messagingStore).environmentObject(badgeStore).environmentObject(stripOrderStore).environmentObject(pinnedFolderStore).environmentObject(folderCoverStore).environmentObject(shelfStore).environmentObject(dragController).environmentObject(keptAppStore).environmentObject(runningApplicationStore).environmentObject(appMembershipController).environmentObject(settingsStore).environmentObject(displayTopologyStore))
        hosting.autoresizingMask = [.width, .height]
        // Prevent NSHostingView from adding its own opaque background over the blur
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.0).cgColor
        dockContentHost = ManualPanelHost(contentView: hosting, in: panel)
        dockPanel = panel

        if let (backgroundPanel, backgroundView) = glassBackground {
            dockGlassBackgroundPanel = backgroundPanel
            dockGlassBackgroundView = backgroundView
        }
    }

    private func makeTaskbarGlassBackground(
        contentPanelFrame: NSRect
    ) -> (NonConstrainingPanel, DockTaskbarLiquidGlassBackgroundView)? {
        guard DockGlassPresentation.shouldAttemptTaskbarComposite else { return nil }

        let configuration = DockGlassPresentation.configuration
        let backgroundFrame = DockLiquidGlassPanelGeometry.backgroundFrame(
            for: contentPanelFrame,
            shadowPadding: Self.shadowPadding
        )
        guard backgroundFrame.width > 0, backgroundFrame.height > 0 else { return nil }

        let panel = NonConstrainingPanel(
            contentRect: backgroundFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configurePanel(panel, backgroundColor: .clear, appliesLevelOverride: true)
        panel.ignoresMouseEvents = true
        // The failure branch below close()s a window that was never ordered in; NSWindow releases on close by
        // default, while a strong reference is still held here.
        panel.isReleasedWhenClosed = false

        let backgroundView = DockTaskbarLiquidGlassBackgroundView(
            frame: NSRect(origin: .zero, size: backgroundFrame.size),
            cornerRadius: taskbarPlateCornerRadius,
            configuration: configuration
        )
        backgroundView.autoresizingMask = [.width, .height]
        panel.contentView = backgroundView

        let blurRadius = UInt32(configuration.windowBlurRadius.rounded())
        guard TEDockGlassSetWindowBackgroundBlurRadius(panel.windowNumber, blurRadius) else {
            panel.contentView = nil
            panel.close()
            return nil
        }
        return (panel, backgroundView)
    }

    func tearDownTaskbarGlassBackground() {
        guard let background = dockGlassBackgroundPanel else { return }
        _ = TEDockGlassSetWindowBackgroundBlurRadius(background.windowNumber, 0)
        background.contentView = nil
        background.orderOut(nil)
        background.close()
        dockGlassBackgroundView = nil
        dockGlassBackgroundPanel = nil
    }

    func orderDockSurfaceFront() {
        let ordering = DockLiquidGlassPanelLifecyclePlan.ordering(
            isCompositeActive: dockGlassBackgroundPanel != nil,
            shouldShow: true
        )
        for role in ordering {
            switch role {
            case .background:
                dockGlassBackgroundPanel?.orderFrontRegardless()
            case .content:
                dockPanel?.orderFrontRegardless()
            }
        }
        if let background = dockGlassBackgroundPanel, let dock = dockPanel {
            background.order(.below, relativeTo: dock.windowNumber)
        }
    }

    func orderDockSurfaceOut() {
        let ordering = DockLiquidGlassPanelLifecyclePlan.ordering(
            isCompositeActive: dockGlassBackgroundPanel != nil,
            shouldShow: false
        )
        for role in ordering {
            switch role {
            case .background:
                dockGlassBackgroundPanel?.orderOut(nil)
            case .content:
                dockPanel?.orderOut(nil)
            }
        }
    }

    private func moveExternalFiles(_ urls: [URL], into path: String) {
        let destination = URL(fileURLWithPath: path, isDirectory: true)
        fileDropQueue.async {
            let eligible = FolderDropPlan.eligibleSources(urls, destination: destination)
            guard !eligible.isEmpty else { return }
            let result = FileMover().move(eligible, into: destination)
            guard result.hasIssues else { return }
            DispatchQueue.main.async { NSSound.beep() }
        }
    }

    func setupCapsulePanel() {
        let panel = makeFloatingPanel(
            contentRect: NSRect(origin: .zero,
                                size: CGSize(width: capsuleWidth + Self.shadowPadding * 2,
                                             height: capsuleWidth + Self.shadowPadding * 2)),
            usesLiquidGlass: usesLiquidGlass
        )
        configurePanel(panel, backgroundColor: NSColor(white: 1.0, alpha: 0.0), appliesLevelOverride: true)
        let hosting = NSHostingView(rootView:
            DrawerCapsuleButton(
                onRequestTaskbarMenu: { [weak self] event, view in
                    self?.onRequestTaskbarMenu?(event, view)
                },
                usesLiquidGlass: usesLiquidGlass,
                action: { [weak self] in self?.toggleDrawer() }
            )
                .environmentObject(runtime)
                .environmentObject(drawerStore)
                .environmentObject(messagingStore)
                .environmentObject(keptAppStore)
                .environmentObject(runningApplicationStore)
                .environmentObject(drawerOrderStore)
                .environmentObject(dragController)
                .environmentObject(settingsStore)
        )
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.0).cgColor
        capsuleContentHost = ManualPanelHost(contentView: hosting, in: panel)
        capsulePanel = panel
    }

    /// The two permanent panels finish SwiftUI layout and target frame commit while hidden, then show
    /// together.
    /// So the first visible frame is already the intended geometry, leaving no window-level intermediate
    /// state from HostingView's natural size.
    func presentInitialPanels() {
        guard let dock = dockPanel, let capsule = capsulePanel else { return }
        dock.layoutIfNeeded()
        capsule.layoutIfNeeded()
        relayout(animated: false)
        orderDockSurfaceFront()
        shownCapsulePanel?.orderFrontRegardless()
    }

    /// `usesLiquidGlass` is passed explicitly by the caller: in `setupDockPanel` the glass backplate has just
    /// been built and not yet assigned to `dockGlassBackgroundPanel`, so reading the computed property would
    /// misjudge "no glass" and build a plain panel.
    func makeFloatingPanel(contentRect: NSRect, usesLiquidGlass: Bool) -> NonConstrainingPanel {
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        return usesLiquidGlass
            ? DockLiquidGlassPanel(contentRect: contentRect, styleMask: styleMask,
                                   backing: .buffered, defer: false)
            : NonConstrainingPanel(contentRect: contentRect, styleMask: styleMask,
                                   backing: .buffered, defer: false)
    }

    /// Window configuration shared by the six panels (consolidated 2026-09-05 from six verbatim copies).
    /// **Order is load-bearing**:
    /// `isFloatingPanel = true` resets `level` to `.floating`, so the experimental level override must come
    /// after it; only the three permanent panels (taskbar / glass backplate / capsule) take the
    /// `DOCK_PANEL_LEVEL` override; drawer / popup / tooltip do not.
    /// This leaves `PanelCollectionBehavior.standard` assigned only here and in the issue #19 repair loop.
    func configurePanel(_ panel: NSPanel, backgroundColor: NSColor, appliesLevelOverride: Bool) {
        panel.level = .floating
        panel.collectionBehavior = PanelCollectionBehavior.standard
        panel.isFloatingPanel = true
        if appliesLevelOverride, let level = Self.panelLevelOverride { panel.level = level }
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = backgroundColor
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
    }
}
