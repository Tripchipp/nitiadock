import AppKit

/// Hosts manually sized panel content without letting the hosted view become the
/// window's content view and participate in automatic window sizing.
@MainActor
final class ManualPanelHost {
    let contentView: NSView

    init(contentView: NSView, in panel: NSPanel) {
        self.contentView = contentView

        let initialSize = panel.contentView?.bounds.size
            ?? panel.contentRect(forFrameRect: panel.frame).size
        let container = NSView(frame: NSRect(origin: .zero, size: initialSize))
        panel.contentView = container

        contentView.frame = container.bounds
        contentView.autoresizingMask = [.width, .height]
        container.addSubview(contentView)
    }

    var fittingSize: NSSize { contentView.fittingSize }
}

/// Window behavior set shared by the seven floating panels. **This must be the only literal**:
/// the issue #19 fix reassigns these exact values to restore "present on all desktops" membership, and if the
/// restored values ever diverge from the creation values, the fix silently changes the panel's behavior.
enum PanelCollectionBehavior {
    static let standard: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
}

/// Turns off AppKit's automatic window constraining. By default the system moves windows near or across a
/// screen edge back into the "current screen's" usable area (clear of the menu bar).
/// With screens that **share an edge** this is fatal: with the taskbar at the bottom of the upper screen, the
/// window origin y falls on the lower screen's side, so the system constrains against the lower screen and
/// pushes the whole window right under the lower screen's menu bar -> the taskbar/capsule lands on the wrong
/// screen (root cause of the 2026-06-23 three-screen bug; measured y=970 pushed to y=857 = lower screen's
/// usable top 949 - window height 92). Our panels are always positioned manually and exactly and never cover
/// the menu bar, so return the original frame and keep the system from constraining a second time.
class NonConstrainingPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Liquid Glass is hosted in a non-key floating panel. These private AppKit appearance hooks are
/// the same narrow override used by native-looking third-party docks to keep the material active.
final class DockLiquidGlassPanel: NonConstrainingPanel {
    @objc(_hasActiveAppearance)
    func bestDockHasActiveAppearance() -> Bool { true }

    @objc(_hasActiveAppearanceIgnoringKeyFocus)
    func bestDockHasActiveAppearanceIgnoringKeyFocus() -> Bool { true }

    @objc(_hasKeyAppearance)
    func bestDockHasKeyAppearance() -> Bool { true }

    @objc(_hasMainAppearance)
    func bestDockHasMainAppearance() -> Bool { true }

    @objc(_hasActiveControls)
    func bestDockHasActiveControls() -> Bool { true }
}
