import AppKit
import SwiftUI

/// Pinned folder chip: a flat single cover (no stacked sheets), sized like the other chips. The cover is the
/// thumbnail of the first file under the folder's current sort (supplied by PinnedFolderCoverStore; an icon
/// for an empty folder / no thumbnail). The name is always shown below the cover; long names are truncated
/// and .help gives the full name. Clicks always use onTapGesture (do not use Button on a nonactivatingPanel);
/// right-click = hand-built NSMenu.
struct PinnedFolderChip: View {
    /// Folder card width. **Not equal to the bar height**: it is the room for the folder name (name
    /// truncation cap 48pt).
    static let chipWidth: CGFloat = 52

    let path: String
    let cover: FolderCover?
    /// Current sort mode (for the menu checkmark; the menu builder is rebuilt on every right-click and always
    /// reads the latest value).
    let sortOrder: FolderSortOrder
    let onTap: () -> Void
    /// Content preview (context menu "Preview Contents"; the left click also goes here in preview mode).
    let onPreview: () -> Void
    /// Opens a Finder window at this path (context menu "Open in Finder"; the left click also goes here in
    /// openFinderWindow mode).
    let onOpenInFinder: () -> Void
    let onAddFolder: () -> Void
    let onRemove: () -> Void
    let onSetSortOrder: (FolderSortOrder) -> Void
    var isDropTarget = false
    /// Scale factor of the taskbar size tier. Medium = 1.0, where every size is pixel-identical to the
    /// historical literals. **Deliberately no default**: omitting it must be a compile error, see the project
    /// rule "Taskbar Size Tiers".
    let scale: CGFloat
    /// Hover effect style. **Also deliberately no default**: omitting it must be a compile error, same reason
    /// as `scale`.
    let hoverStyle: HoverStyle
    /// Whether the pointer is on this card. Computed by the taskbar's bar-wide tracking area and passed in
    /// (see `StripHoverResolution`); the drag carrier passes `false`. **Deliberately no default**, same
    /// reason as `scale` / `hoverStyle`.
    let isHovered: Bool

    private let theme = DockThemeTokens.standard

    /// Master gate for hover visuals: always false in the "quiet" style, so the whole-card scale-up no longer
    /// happens. Drop highlight (`isDropTarget`) is not governed by it: that is drag-and-drop feedback, not
    /// hover.
    private var showsHover: Bool { hoverStyle.showsExpressiveHover(isHovering: isHovered) }
    /// This cell **scales up in both styles**: the form chosen when the quiet style got hover feedback on
    /// 2026-08-17 happens to be a whole-card scale-up, which coincides with what was already done here, so
    /// the same one is used and no separate scale is stacked for the quiet style. The amount does not vary by
    /// style either: varying it would require explaining "why it scales less once the name is turned off".
    private var showsHoverScale: Bool { showsHover || hoverStyle.showsQuietHoverFeedback(isHovering: isHovered) }
    /// Factor of the whole-card hover scale-up (bottom-anchored). **The drag-start pose reads it too**
    /// (`DockStripView.pickUpPose`): the carrier's first frame must be placed at the slot's current scale,
    /// and two copies of the number would drift.
    static let hoverScale: CGFloat = 1.12

    private var folderName: String {
        FileManager.default.displayName(atPath: path)
    }

    var body: some View {
        let coverSize: CGFloat = 26 * scale
        VStack(spacing: 2 * scale) {
            Spacer(minLength: 0)
            coverImage(size: coverSize)
                .overlay {
                    RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                        .strokeBorder(theme.folderDropRing.color(active: isDropTarget), lineWidth: 1.5)
                }
                .scaleEffect(isDropTarget ? 1.08 : 1)
            Text(folderName)
                .font(.system(size: 10 * scale, weight: .medium, design: .rounded))
                .foregroundStyle(theme.labelHover.color)
                // **Always visible** bare text, exposed to the background for longer than the hover labels.
                // See DockThemeTokens.labelHalo
                .dockShadow(theme.labelHalo)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 48 * scale)
            Spacer(minLength: 0)
        }
        // The height follows the bar height (the card must fill it); the width is the room for the folder
        // name and is unrelated to the bar height, so when the bar height went 52->54 on 2026-08-16 **only
        // the height changed**, not the width: widening would shift the whole folder zone and the hit band
        // for external drops.
        .frame(width: Self.chipWidth * scale, height: ChipPillMetrics.chipHeight * scale)
        .contentShape(Rectangle())
        // Hover: the whole chip scales up and pushes upward (native Dock feel). anchor .bottom keeps the name
        // at the bottom nearly still while the cover rises. scaleEffect is only a render transform and does
        // not change the layout frame: drop hit testing reads the unscaled frame reported by the .background
        // GeometryReader and is unaffected.
        .scaleEffect(showsHoverScale ? Self.hoverScale : 1, anchor: .bottom)
        .onTapGesture { onTap() }
        .nativeContextMenu { buildMenu() }
        .help(folderName)
        .animation(.easeOut(duration: 0.12), value: isDropTarget)
        .animation(.easeOut(duration: 0.12), value: showsHoverScale)
    }

    /// Cover: a real thumbnail is cropped square with a thin stroke (white in dark, black in light); a file
    /// icon / empty-folder icon is rendered fit, with no crop or stroke. A thumbnail is **full-bleed with no
    /// margin** and looks larger than an app icon (.fit has about 20% built-in margin), so it is scaled by
    /// 5/6 to the icon's visible square; an icon has its own margin and already matches app icons, so it
    /// keeps size unscaled.
    @ViewBuilder
    private func coverImage(size: CGFloat) -> some View {
        if let cover, cover.isThumbnail {
            // Real thumbnail: square crop + thin stroke (scaled to the app icon's visible square; corner
            // radius thumb/4).
            let thumb = size * 5 / 6
            Image(nsImage: cover.image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: thumb, height: thumb)
                .clipShape(RoundedRectangle(cornerRadius: thumb / 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: thumb / 4, style: .continuous)
                        .strokeBorder(theme.folderThumbHairline.color, lineWidth: 0.5)
                )
                .frame(width: size, height: size)
        } else {
            // Icon (file icon as the base / folder icon for an empty folder): rendered fit, no crop or
            // stroke.
            Image(nsImage: cover?.image ?? PinnedFolderCoverStore.icon(forPath: path))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(String(localized: "Preview Contents")) { onPreview() })
        menu.addItem(ClosureMenuItem(String(localized: "Open in Finder")) { onOpenInFinder() })
        menu.addItem(.separator())
        // Sort By ▸ (as in native Stacks): both the popup grid and the chip cover follow it, remembered per
        // folder.
        let sortItem = NSMenuItem(title: String(localized: "Sort by"), action: nil, keyEquivalent: "")
        let sortMenu = NSMenu()
        for order in FolderSortOrder.allCases {
            let item = ClosureMenuItem(order.menuTitle) { onSetSortOrder(order) }
            item.state = order == sortOrder ? .on : .off
            sortMenu.addItem(item)
        }
        sortItem.submenu = sortMenu
        menu.addItem(sortItem)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(String(localized: "Add Folder…")) { onAddFolder() })
        menu.addItem(ClosureMenuItem(String(localized: "Remove from Taskbar")) { onRemove() })
        return menu
    }
}
