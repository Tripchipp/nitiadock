import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Trash chip's popup: what is in the Trash, by name and type icon. No thumbnails: the Trash
/// is readable only with Full Disk Access, which the product never asks for; the listing comes from
/// Finder automation. Same panel, grid and cells as the folder and shelf popups.
struct TrashGridPopupView: View {
    @ObservedObject var trashStore: TrashStateStore
    let maxContentHeight: CGFloat
    let usesLiquidGlass: Bool
    var onClosePopup: () -> Void = {}
    var onContentResize: () -> Void = {}
    var onOpenInFinder: () -> Void = {}

    private let theme = DockThemeTokens.standard
    @State private var gridHeight: CGFloat = 0
    private typealias Style = FolderPopupStyle

    private var items: [TrashItem] {
        if case let .loaded(items, _) = trashStore.listing { return items }
        return []
    }
    /// Denied automation leaves only Open in Finder, as the chip menu does.
    private var canEmpty: Bool { trashStore.status != .denied }
    private var tailCellCount: Int { canEmpty ? 2 : 1 }

    var body: some View {
        let columnCount = min(Style.maxColumns, max(Style.minColumns, items.count + tailCellCount))
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
                    ScrollView(.vertical, showsIndicators: true) { gridBody(contentWidth: contentWidth, columnCount: columnCount) }
                        .frame(height: availableGridHeight)
                } else {
                    gridBody(contentWidth: contentWidth, columnCount: columnCount)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DockShape.panelCornerRadius, style: .continuous))
        }
        .dockPanelRim(cornerRadius: DockShape.panelCornerRadius,
                      style: theme.panelRimStyle,
                      lineWidth: theme.panelRimLineWidth,
                      usesLiquidGlass: usesLiquidGlass)
        .dockShadow(theme.popupShadow)
        .padding(PanelCoordinator.shadowPadding)
        .onChange(of: gridHeight) { _ in onContentResize() }
        .onChange(of: columnCount) { _ in onContentResize() }
    }

    private func gridBody(contentWidth: CGFloat, columnCount: Int) -> some View {
        VStack(spacing: 0) {
            statusLine
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Style.cellWidth), spacing: Style.cellSpacing), count: columnCount),
                      spacing: Style.cellSpacing) {
                ForEach(items, id: \.url) { item in
                    FolderGridCell(iconPath: nil,
                                   staticIcon: TrashItemIcon.icon(for: item),
                                   label: item.name,
                                   contextMenu: { itemMenu(for: item) }) { reveal(item) }
                }
                FolderGridCell(iconPath: nil, staticIcon: Self.finderIcon, label: String(localized: "Open in Finder")) {
                    onOpenInFinder()
                }
                if canEmpty {
                    FolderGridCell(iconPath: nil, staticIcon: Self.emptyIcon, label: String(localized: "Empty Trash…")) {
                        // The confirmation is modal; the popup's click-away monitor would close it anyway.
                        onClosePopup()
                        trashStore.emptyTrash()
                    }
                }
            }
            .animation(.easeInOut(duration: DrawerAnimation.duration), value: items)
        }
        .padding(Style.contentPadding)
        .frame(width: contentWidth)
        .background(GeometryReader { g in
            Color.clear.preference(key: TrashGridHeightKey.self, value: g.size.height)
        })
        .onPreferenceChange(TrashGridHeightKey.self) { gridHeight = $0 }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch trashStore.listing {
        case .idle, .loading:
            note(String(localized: "Reading Trash…"))
        case .unavailable:
            note(String(localized: "Allow Finder automation to see what’s in the Trash"))
        case let .loaded(items, hidden):
            if items.isEmpty {
                note(String(localized: "Trash is empty"))
            } else if hidden > 0 {
                note(String(localized: "Open in Finder to see the rest"))
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Style.labelSize))
            .foregroundStyle(theme.popupSecondaryText.color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
    }

    /// A click selects the item in the Trash window: Finder exposes no put-back command, so that
    /// window (⌘⌫ there) is the road to it.
    private func reveal(_ item: TrashItem) {
        onClosePopup()
        trashStore.revealItem(item.url)
    }

    /// Only actions that never touch the item: Finder performs moves and deletes of a Trash item on
    /// the sender's Full Disk Access (denied, with Finder's own error dialog blocking the reply), and
    /// opening a document there does nothing. Deleting or putting back happens in the Trash window.
    private func itemMenu(for item: TrashItem) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(String(localized: "Show in Finder")) { reveal(item) })
        menu.addItem(ClosureMenuItem(String(localized: "Copy Name")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.name, forType: .string)
        })
        return menu
    }

    private static let finderIcon: NSImage = FolderIconResolver.resolve("/System/Library/CoreServices/Finder.app")
    private static let emptyIcon: NSImage = NSImage(named: NSImage.trashFullName) ?? NSImage()
}

/// Type icons by extension: the files themselves cannot be read without Full Disk Access.
enum TrashItemIcon {
    private static var cache: [String: NSImage] = [:]

    @MainActor
    static func icon(for item: TrashItem) -> NSImage {
        let ext = item.url.pathExtension.lowercased()
        let key = (item.isDirectory ? "d:" : "f:") + ext
        if let cached = cache[key] { return cached }
        let type: UTType
        if item.isDirectory {
            type = ext == "app" ? .applicationBundle : .folder
        } else {
            type = UTType(filenameExtension: ext) ?? .data
        }
        let icon = NSWorkspace.shared.icon(for: type)
        cache[key] = icon
        return icon
    }
}

private struct TrashGridHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
