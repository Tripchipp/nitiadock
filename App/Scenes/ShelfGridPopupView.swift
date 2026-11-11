import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shelf popup: a grid of stashed files. Shares `FolderGridCell` / `FolderPopupStyle` with the folder popup,
/// but has **no drill-down, no "Open in Finder" last cell and no directory watcher**: the data source is
/// `ShelfStore`'s path list (order = stash order, newest first; pruned by the coordinator before opening).
/// The empty state is a one-line hint. Cells can be dragged out with a system drag (.onDrag); the context
/// menu has "Remove from Shelf", and a successful move to Trash also removes the item.
struct ShelfGridPopupView: View {
    @ObservedObject var shelfStore: ShelfStore
    let maxContentHeight: CGFloat
    /// Whether the backing uses native Liquid Glass. **Passed explicitly, no default** (like `scale` /
    /// `hoverStyle`): every panel is an independent hosting root view, and omitting it gives the plainly
    /// visible inconsistency of "this panel is glass, the one beside it is still frosted".
    let usesLiquidGlass: Bool
    var onClosePopup: () -> Void = {}
    var onContentResize: () -> Void = {}
    var onPinFolder: ((URL) -> Void)?
    var isFolderPinned: ((URL) -> Bool)?

    private let theme = DockThemeTokens.standard

    @State private var gridHeight: CGFloat = 0

    private typealias Style = FolderPopupStyle

    var body: some View {
        // Each render reads file attributes once in the current stash order (the shelf is small, so a
        // synchronous read is acceptable; the coordinator prunes before the popup opens).
        let entries = FolderContentsLoader.entries(forPaths: shelfStore.itemPaths)
        let columnCount = min(Style.maxColumns, max(Style.minColumns, max(entries.count, 1)))
        let contentWidth = CGFloat(columnCount) * Style.cellWidth
            + CGFloat(columnCount - 1) * Style.cellSpacing
            + Style.contentPadding * 2
        let availableGridHeight = min(max(140, maxContentHeight), Style.maxGridHeight)

        ZStack(alignment: .bottomLeading) {
            DockPanelBackdrop(theme: theme,
                              cornerRadius: DockShape.panelCornerRadius,
                              usesLiquidGlass: usesLiquidGlass)

            Group {
                if gridHeight > availableGridHeight + 0.5 {
                    ScrollView(.vertical, showsIndicators: true) { gridBody(entries: entries, contentWidth: contentWidth, columnCount: columnCount) }
                        .frame(height: availableGridHeight)
                } else {
                    gridBody(entries: entries, contentWidth: contentWidth, columnCount: columnCount)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DockShape.panelCornerRadius, style: .continuous))
        }
        .dockPanelRim(cornerRadius: DockShape.panelCornerRadius,
                      style: theme.panelRimStyle,
                      lineWidth: theme.panelRimLineWidth,
                      usesLiquidGlass: usesLiquidGlass)
        // The fade is done by the coordinator at the AppKit layer (panel.alphaValue); the content layer adds
        // none (same as FolderGridPopupView). The shadow extent (radius+|y|) must be <= shadowPadding(20)
        // (project rule, same as the folder popup).
        .dockShadow(theme.popupShadow)
        .padding(PanelCoordinator.shadowPadding)
        .onChange(of: gridHeight) { _ in onContentResize() }
        .onChange(of: columnCount) { _ in onContentResize() }
    }

    private func gridBody(entries: [FolderContentsLoader.Entry], contentWidth: CGFloat, columnCount: Int) -> some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                Text("Drag files here to park them")
                    .font(.system(size: Style.labelSize))
                    .foregroundStyle(theme.popupSecondaryText.color)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            } else if entries.contains(where: { !$0.isAccessible }) {
                // Kept, not pruned: the file exists but its folder's privacy permission is missing.
                Text("Some items can’t be accessed. Allow NitiaDock to access their folder in your Mac’s privacy settings.")
                    .font(.system(size: Style.labelSize))
                    .foregroundStyle(theme.popupSecondaryText.color)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Style.cellWidth), spacing: Style.cellSpacing), count: columnCount),
                      spacing: Style.cellSpacing) {
                ForEach(entries, id: \.url) { entry in
                    FolderGridCell(iconPath: entry.isAccessible ? entry.url.path : nil,
                                   staticIcon: entry.isAccessible ? nil : Self.inaccessibleIcon,
                                   label: entry.name,
                                   dragURL: entry.isAccessible ? entry.url : nil,
                                   contextMenu: { cellMenu(for: entry) }) {
                        // The shelf does not drill down: a click always opens (a folder opens in Finder); the
                        // main use is dragging out.
                        NSWorkspace.shared.open(entry.url)
                        onClosePopup()
                    }
                }
            }
            .animation(.easeInOut(duration: DrawerAnimation.duration), value: shelfStore.itemPaths)
        }
        .padding(Style.contentPadding)
        .frame(width: contentWidth)
        .background(GeometryReader { g in
            Color.clear.preference(key: ShelfGridHeightKey.self, value: g.size.height)
        })
        .onPreferenceChange(ShelfGridHeightKey.self) { gridHeight = $0 }
    }

    private static let inaccessibleIcon = NSWorkspace.shared.icon(for: .data)

    private func cellMenu(for entry: FolderContentsLoader.Entry) -> NSMenu {
        let canPin = entry.isDirectory && !(isFolderPinned?(entry.url) ?? true)
        let path = entry.url.path
        return FileItemMenuBuilder.menu(for: .init(
            url: entry.url,
            isDirectory: entry.isDirectory,
            closePopup: onClosePopup,
            pinFolder: canPin ? { onPinFolder?(entry.url) } : nil,
            removeFromShelf: { shelfStore.remove(path) },
            onTrashed: { shelfStore.remove(path) }
        ))
    }
}

private struct ShelfGridHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
