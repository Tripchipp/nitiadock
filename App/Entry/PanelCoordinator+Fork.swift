import AppKit

// fork: NitiaDock additions to PanelCoordinator. Upstream files call into these helpers; the logic
// itself lives here so merges with upstream stay small.
extension PanelCoordinator {
    // MARK: - Hideable drawer capsule

    /// Whether this unit has a drawer capsule at all (`AppSettingsStore.showDrawer`).
    var showsDrawerCapsule: Bool { settingsStore.showDrawer }

    /// The capsule panel, or nil while the drawer is hidden. The panel object itself always exists
    /// (setup, teardown and the fullscreen paths rely on that); hit-testing and ordering-front go
    /// through this so a hidden capsule neither appears nor swallows the pointer where it used to be.
    var shownCapsulePanel: NSPanel? { showsDrawerCapsule ? capsulePanel : nil }

    /// Applies a `showDrawer` change to a running unit. Layout is the caller's job.
    func applyDrawerCapsulePresence() {
        if showsDrawerCapsule {
            // Only join the bar if the bar itself is on screen (auto-hide, fullscreen).
            if panelsAreVisible { capsulePanel?.orderFrontRegardless() }
        } else {
            if drawerWantsOpen { closeDrawerImmediately() }
            capsulePanel?.orderOut(nil)
        }
        // The capsule joins or leaves the committed frame list; drop the "nothing changed" cache so
        // the next layout is not skipped.
        lastCommittedFrames = []
    }

    // MARK: - Bottom margin

    /// Whether `point` (screen coordinates) is in the strip between the screen edge and a raised bar.
    /// Uses the target frame, like every other geometry read here: the live frame is mid-animation
    /// while the margin slider is being dragged.
    func forkApproachCorridorContains(_ point: CGPoint) -> Bool {
        guard let dock = dockPanel else { return false }
        let frame = lastDockTargetFrame != .zero ? lastDockTargetFrame : dock.frame
        let screen = panelCurrentScreen(panel: dock)
        return ForkBottomMargin.approachCorridor(dockPanelFrame: frame, screenFrame: screen.frame)?
            .contains(point) ?? false
    }

    // MARK: - Appearance overrides

    /// The strip's content width may have changed. Same two-step as the shelf toggle: measure after
    /// SwiftUI's next pass. Title boxes animate to a new width on `LabelWidthAnimation`'s curve, so a
    /// second, unanimated measurement once that curve has finished settles the panel on the final
    /// width; when nothing moved it is a no-op (`setFrames` skips identical targets).
    func relayoutAfterForkAppearanceChange() {
        dismissWindowTitleTooltip(suppressCurrentUntilExit: true)
        DispatchQueue.main.async { [weak self] in self?.relayout(animated: true) }
        let settle = LabelWidthAnimation.curve.duration + 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            self?.relayout(animated: false)
        }
    }
}
