import AppKit
import SwiftUI

/// Shelf: a holding cell fixed at the head of the folder zone. Drop a file on the cell to stash it (a
/// reference, the file is not moved); a click pops up the stash grid. **Not draggable** (fixed at the head).
/// Visually it uses the corner radius and shadow style of an ordinary app icon, no longer the folder's
/// stacked style. The count is **not a protruding badge**; it is text in the hover name bubble, to avoid
/// clashing with the "zero decoration" look of the other pinned zone chips.
struct ShelfChip: View {
    let itemCount: Int
    let isDropTargeted: Bool
    /// Scale factor of the taskbar size tier. Medium = 1.0, where every size is pixel-identical to the
    /// historical literals. **Deliberately no default**: omitting it must be a compile error, see the project
    /// rule "Taskbar Size Tiers".
    let scale: CGFloat
    /// Hover effect style. **Also deliberately no default**: omitting it must be a compile error, same reason
    /// as `scale`.
    let hoverStyle: HoverStyle
    /// Whether the pointer is on this cell. Computed by the taskbar's bar-wide tracking area and passed in
    /// (see `StripHoverResolution`).
    let isHovered: Bool
    let onTap: () -> Void
    let onClear: () -> Void
    let onAddFolder: () -> Void

    private let theme = DockThemeTokens.standard

    /// Master gate for hover visuals: always false in the "quiet" style, so the icon does not scale and the
    /// name bubble does not appear. Drop feedback (brighten/stroke/glow from `isDropTargeted`) is not
    /// governed by it.
    private var showsHover: Bool { hoverStyle.showsExpressiveHover(isHovering: isHovered) }
    /// Hover feedback for the quiet style (always false in the standard style). See
    /// `HoverStyle.showsQuietHoverFeedback`.
    private var quietHoverFeedback: Bool {
        hoverStyle.showsQuietHoverFeedback(isHovering: isHovered)
    }

    /// The item count used to appear only in the hover name, which the quiet style does not show, so it is
    /// merged into the system tooltip as a fallback. Active in both styles; changes no pixels on the bar.
    private var helpText: String {
        itemCount > 0
            ? String(format: String(localized: "Shelf · %d — drag files here to park them"), itemCount)
            : String(localized: "Shelf — drag files here to park them")
    }

    var body: some View {
        VStack(spacing: 2 * scale) {
            Spacer(minLength: 0)
            shelfIcon
            Spacer(minLength: 0)
        }
        .frame(width: ChipPillMetrics.cardWidth * scale,
               height: ChipPillMetrics.chipHeight * scale)
        .chipQuietHoverScale(quietHoverFeedback,
                             cardWidth: ChipPillMetrics.cardWidth * scale,
                             scale: scale)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .nativeContextMenu { buildMenu() }
        .help(helpText)
        .animation(.easeInOut(duration: 0.18), value: showsHover)
        .animation(.easeInOut(duration: 0.12), value: isDropTargeted)
    }

    /// Fixed entry icon.
    ///
    /// **Must be an opaque solid block.** Before 2026-08-16 it was a "translucent tinted backing + symbol",
    /// and in the light theme the backing's fill was a **low-opacity black**: once the area under the glass
    /// got dark, black on black vanished (report: "the shelf is hard to see on a dark background"). Every
    /// other chip on the bar is an opaque, full-color app icon; it was the only one that was not, so only it
    /// disappeared.
    ///
    /// The fix follows the native Dock's "Downloads": the same substance as its neighbors, opaque and
    /// full-color, not a translucent tinted backing.
    ///
    /// **Draw at `bareIconVisibleSlot` (32.5pt), not the slot's 40pt.** Apple's icon assets carry about 18%
    /// transparent margin, which is where the gaps between icons on the bar come from; our self-drawn shape
    /// has no such margin, so drawn at 40 it would be visibly larger than its neighbors (half of the reported
    /// "too jarring" was size, not just color).
    ///
    /// The default is the vector-drawn `ShelfTrayArt` (based on a supplied reference image); the other three
    /// are "solid tile + SF symbol" fallbacks, switchable on the spot with
    /// `DOCK_SHELF_TILE=graphite|blue|light`, no rebuild needed.
    private var shelfIcon: some View {
        let art = ChipPillMetrics.bareIconVisibleSlot * scale
        let style = theme.effectiveShelfTile
        return Group {
            if style.isIllustration {
                ShelfTrayArt(size: art, lifted: isDropTargeted)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: art * 0.215, style: .continuous)
                        .fill(style.gradient(lifted: isDropTargeted))
                    Image(systemName: "tray.fill")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: art * 0.5, height: art * 0.5)
                        .foregroundStyle(style.glyphColor)
                }
                .frame(width: art, height: art)
            }
        }
        // The slot is still 40pt, the same as every icon card; only the drawn square shrinks to 32.5.
        .frame(width: ChipPillMetrics.bareIconSlot * scale,
               height: ChipPillMetrics.bareIconSlot * scale)
        // No outer shadow, like the icons (2026-08-19). This one invites "add a little shadow to lift it"
        // more than icons do, but it stands on being opaque with a self-drawn backing (see
        // `DockThemeTokens.shelfTile`), not on a shadow.
        .dockGlow(theme.shelfDropGlow, radius: 3, active: isDropTargeted)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(String(localized: "Open Shelf")) { onTap() })
        if itemCount > 0 {
            menu.addItem(ClosureMenuItem(String(localized: "Clear Shelf")) { onClear() })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(String(localized: "Add Folder…")) { onAddFolder() })
        return menu
    }
}
