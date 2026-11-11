import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drawer Capsule Button

struct DrawerCapsuleButton: View {
    @EnvironmentObject var drawerStore: DrawerStore
    @EnvironmentObject var keptAppStore: KeptAppStore
    @EnvironmentObject var messagingStore: MessagingAppStore
    @EnvironmentObject var runningApplicationStore: RunningApplicationStore
    @EnvironmentObject var drawerOrderStore: DrawerOrderStore
    @EnvironmentObject var settingsStore: AppSettingsStore
    /// Drop feedback for dragging a card into the drawer: while the finger is over the drop zone, the capsule
    /// scales up and gets a highlight stroke.
    @EnvironmentObject var dragController: DragController
    private let theme = DockThemeTokens.standard
    /// Right-click the capsule -> NitiaDock menu. The capsule is the **main fallback entry** to settings:
    /// always present, fixed position, as tall as the panel, and NitiaDock's own part (it belongs to no app),
    /// unlike the taskbar panel, where only a few gaps are clickable.
    var onRequestTaskbarMenu: (NSEvent, NSView) -> Void = { _, _ in }
    /// Whether the backing uses native Liquid Glass. **Passed explicitly, no default** (like `scale` /
    /// `hoverStyle`): the capsule is another long-lived hosting root view, and omitting it gives the plainly
    /// visible inconsistency of "the bar is glass, the capsule right next to it is still frosted".
    let usesLiquidGlass: Bool
    let action: () -> Void

    @State private var isHovering = false
    /// Click confirmation pulse: press and spring back, a pure view-layer signal that does not feed
    /// planner/frontmost (copied from ChipView).
    @State private var isTapPressed = false

    // 3-column grid: 3×icon + 2×spacing + 2×padding must fit within the capsule width (= panel height).
    // Medium is 3×9 + 2×4 + 2×6 = 47pt and the small capsule is only 44pt, so all three values must scale
    // down with it.
    private static let iconSize: CGFloat = 9
    private static let gridSpacing: CGFloat = 4
    private static let gridPadding: CGFloat = 6

    private var iconSize: CGFloat { Self.iconSize * dockScale }
    private var gridSpacing: CGFloat { Self.gridSpacing * dockScale }

    private var folderIDs: [String] {
        let placements = AppMembershipProjection.drawerMembers(drawerIDs: drawerStore.bundleIDs)
        let ordered = drawerOrderStore.reconciled(members: placements)
        return AppMembershipProjection.drawerPreview(
            drawerIDs: ordered,
            keptIDs: keptAppStore.bundleIDs,
            runningIDs: runningApplicationStore.runningBundleIDs
        )
    }

    /// The capsule is **another** long-lived NSHostingView root view and must observe the same store itself,
    /// otherwise on a size change the taskbar updates while the grid in the capsule stays at the old size.
    private var dockScale: CGFloat { settingsStore.dockSize.scale }

    var body: some View {
        // While dragging, hover yields to drag-in feedback: no popup when draggingPayload is non-nil (drag
        // wins).
        let showsHover = isHovering && dragController.draggingPayload == nil
        return ZStack {
            DockPanelBackdrop(theme: theme,
                              cornerRadius: DockShape.panelCornerRadius * dockScale,
                              usesLiquidGlass: usesLiquidGlass)

            // Hover + click feedback applies only to the inner preview content (grid / empty-state symbol);
            // the outer frame (frosted backing + stroke) stays still. It scales in place around the capsule
            // center and returns exactly when the animation ends, leaving no persistent offset.
            Group {
                if folderIDs.isEmpty {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 20 * dockScale, weight: .medium))
                        .foregroundStyle(theme.capsuleGlyph.color)
                } else {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(iconSize), spacing: gridSpacing), count: 3),
                        spacing: gridSpacing
                    ) {
                        ForEach(folderIDs, id: \.self) { id in
                            Image(nsImage: AppIconResolver.icon(for: id))
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: iconSize, height: iconSize)
                                .clipShape(RoundedRectangle(cornerRadius: iconSize / 4, style: .continuous))
                        }
                    }
                    .padding(Self.gridPadding * dockScale)
                }
            }
            .scaleEffect(showsHover ? 1.07 : 1.0)
            .animation(.easeOut(duration: 0.12), value: showsHover)
            // The press applies only to the grid inside and the outer frame stays still (2026-06-21), so the
            // scale lives here and the gesture on the outermost layer (see chipPressGesture below).
            .chipPressScale(isTapPressed)
        }
        .dockPanelRim(cornerRadius: DockShape.panelCornerRadius * dockScale,
                      style: theme.panelRimStyle,
                      lineWidth: theme.panelRimLineWidth,
                      usesLiquidGlass: usesLiquidGlass)
        // Feedback applies only to the inner preview content (see the Group above); this visible layer, as
        // tall as the panel, only handles hover hit testing: moving the mouse anywhere on the capsule
        // triggers it, the grid inside moves, the outer frame stays still.
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // Dragging a card over the capsule: **faint glow + very slight scale-up** (replaces the harsh white
        // ring stroke, 2026-06-21).
        .scaleEffect(dragController.isOverStashZone ? 1.04 : 1.0)
        .dockGlow(theme.capsuleStashGlow, radius: 5, active: dragController.isOverStashZone)
        .animation(.easeInOut(duration: DrawerAnimation.duration), value: dragController.isOverStashZone)
        .dockShadow(theme.stripShadow)
        .padding(PanelCoordinator.shadowPadding)
        .contentShape(Rectangle())
        .onTapGesture { action() }
        .chipPressGesture(isPressed: $isTapPressed)
        // MenuHostNSView only handles right-click / Control-click; a left click always returns nil and passes
        // through, so the "click the capsule to open the drawer" behavior above is unaffected.
        .overlay(NativeMenuHost(popUpHandler: onRequestTaskbarMenu))
    }
}
