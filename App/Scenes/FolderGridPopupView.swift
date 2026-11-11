import AppKit
import SwiftUI

/// Data layer of the pinned folder popup: background enumeration + live refresh from a directory watcher.
/// generation prevents crossed results (review P1): on rapid drill-down/refresh, stale results are always
/// dropped when they return.
@MainActor
final class FolderPopupModel: ObservableObject {
    @Published private(set) var entries: [FolderContentsLoader.Entry] = []
    @Published private(set) var loadFailed = false
    @Published private(set) var didFirstLoad = false

    private var watcher: DirectoryWatcher?
    private var generation = 0
    /// This folder's sort mode (fixed when the popup opens; changing it goes through the coordinator, which
    /// switches in place and reopens, no hot switch inside the popup).
    var sortOrder: FolderSortOrder = .default

    /// Preload path: the coordinator has read the contents in the background before opening, so the first
    /// frame is the full grid (root-cause fix for the piecemeal look).
    func seed(entries: [FolderContentsLoader.Entry]) {
        self.entries = entries
        didFirstLoad = true
    }

    func display(url: URL) {
        watcher?.stop()
        watcher = DirectoryWatcher(path: url.path) { [weak self] in
            Task { @MainActor [weak self] in self?.reload(url: url) }
        }
        reload(url: url)
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    /// Directory reads use their own serial queue rather than `Task.detached`: opening the popup is a user
    /// action, and the Swift cooperative thread pool would queue it behind `AppTracker`'s background AX batch
    /// reads (N×100ms serial) (a hard project rule).
    private static let reloadQueue = DispatchQueue(label: "no.thilip.nitiadock.folder-popup-reload",
                                                   qos: .userInitiated)

    private func reload(url: URL) {
        generation += 1
        let expected = generation
        Self.reloadQueue.async { [weak self] in
            let result = Result { try FolderContentsLoader.load(directory: url) }
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected else { return }
                switch result {
                case .success(let list):
                    // Do not publish when the content is unchanged: the first reload when the watcher
                    // attaches after a preload is usually identical, and triggers no refresh/animation (zero
                    // content change during the entrance is an acceptance criterion).
                    let sorted = FolderContentsLoader.sorted(list, by: self.sortOrder)
                    if sorted != self.entries { self.entries = sorted }
                    if self.loadFailed { self.loadFailed = false }
                case .failure:
                    if !self.entries.isEmpty { self.entries = [] }
                    if !self.loadFailed { self.loadFailed = true }
                }
                if !self.didFirstLoad { self.didFirstLoad = true }
            }
        }
    }
}

/// Resolution + caching of popup cell icons (shaped like `AppIconResolver`: a namespace enum holding an
/// NSCache, decoupled from views). The coordinator `warm`s the first visible cells before opening, and the
/// cell init looks up `cached` synchronously, so the first frame is "one whole block" (icons included);
/// anything not prewarmed (deep scroll / drill-down) falls back to `resolve` in the cell's `.task` and shows
/// the moment it resolves, **with no per-cell fade-in**.
enum FolderIconResolver {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 512   // bounded, so a long session does not pile up icons for every folder opened
        return c
    }()

    static func cached(_ path: String) -> NSImage? {
        cache.object(forKey: path as NSString)
    }

    /// Returns the cached value on a hit, otherwise resolves and writes back (synchronous on the main thread
    /// is fast enough: LazyVGrid only instantiates visible cells).
    static func resolve(_ path: String, size: CGFloat = 64) -> NSImage {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        let img = makeIcon(path, size: size)
        cache.setObject(img, forKey: path as NSString)
        return img
    }

    /// Prewarm before opening: fetches the first visible cells' icons into the cache in the background,
    /// blocking at most timeout (a cold-path trade-off for all icons lit on the first frame; NSWorkspace
    /// icons usually take <2ms each, and ≈ 0ms on the hot path when everything hits). After a timeout the
    /// background block runs to completion and writes to the cache, and the few icons missing from the first
    /// frame are filled in at once by the cell's `.task` fallback.
    static func warm(paths: [String], timeout: TimeInterval) {
        let pending = paths.filter { cache.object(forKey: $0 as NSString) == nil }
        guard !pending.isEmpty else { return }
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
            for path in pending {
                cache.setObject(makeIcon(path), forKey: path as NSString)
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    /// A shared cached object must be copied before changing its size (AppMenuFragments convention).
    private static func makeIcon(_ path: String, size: CGFloat = 64) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path)
        guard let copy = icon.copy() as? NSImage else { return icon }
        copy.size = NSSize(width: size, height: size)
        return copy
    }
}

/// Pinned folder popup grid, matching the native Stacks grid (2026-07-06): **no header**; "Open in Finder" is
/// the grid's **last cell** (with the Finder icon); after drill-down a small back arrow floats at the top
/// left. 64pt icons, 96pt cell width, columns = clamp(total cells, 3, 8). The width is **derived** from the
/// item count (a deterministic value), not measured, so there is no fittingSize feedback loop; the panel
/// narrows automatically for small folders (as in the native one). Sorting follows the user's choice
/// (remembered per folder), the same criterion as the chip cover (the first file under the current sort).
struct FolderGridPopupView: View {
    let rootURL: URL
    /// Upper limit of the grid's available height (above the anchor -> top of the screen, computed and passed
    /// in by PanelCoordinator); beyond it the grid scrolls internally.
    let maxContentHeight: CGFloat
    /// Whether the backing uses native Liquid Glass. **Passed explicitly, no default** (like `scale` /
    /// `hoverStyle`): every panel is an independent hosting root view, and omitting it gives the plainly
    /// visible inconsistency of "this panel is glass, the one beside it is still frosted".
    let usesLiquidGlass: Bool
    /// Called after a file is opened (the coordinator closes the popup). "Open"-type context menu actions go
    /// through it too (close semantics settled in review).
    var onFileOpened: () -> Void = {}
    /// Drill-down/refresh changed the content size (width or height) -> the coordinator repositions the panel
    /// with animation.
    var onContentResize: () -> Void = {}
    /// Context menu "Pin to pinned zone" on a directory item (the coordinator wires it to PinnedFolderStore).
    /// nil = the item is not shown.
    var onPinFolder: ((URL) -> Void)?
    /// Pinned check (an already pinned directory no longer shows "Pin to pinned zone").
    var isFolderPinned: ((URL) -> Bool)?

    private let theme = DockThemeTokens.standard

    @StateObject private var model: FolderPopupModel
    /// Drill-down stack: empty = root directory; push subfolder URLs.
    @State private var drillStack: [URL] = []
    /// Natural grid height (measured). Above the available height it scrolls internally (same capping policy
    /// as DrawerView).
    @State private var gridHeight: CGFloat = 0
    /// Grid add/remove animation is enabled only **after** the first content is in place: the first showing
    /// (preload or timeout backfill) always appears as one block, never inserted cell by cell.
    @State private var animatesGridChanges = false

    init(rootURL: URL,
         initialEntries: [FolderContentsLoader.Entry]?,
         sortOrder: FolderSortOrder = .default,
         maxContentHeight: CGFloat,
         usesLiquidGlass: Bool,
         onFileOpened: @escaping () -> Void = {},
         onContentResize: @escaping () -> Void = {},
         onPinFolder: ((URL) -> Void)? = nil,
         isFolderPinned: ((URL) -> Bool)? = nil) {
        self.rootURL = rootURL
        self.maxContentHeight = maxContentHeight
        self.usesLiquidGlass = usesLiquidGlass
        self.onFileOpened = onFileOpened
        self.onContentResize = onContentResize
        self.onPinFolder = onPinFolder
        self.isFolderPinned = isFolderPinned
        _model = StateObject(wrappedValue: {
            let model = FolderPopupModel()
            model.sortOrder = sortOrder
            if let initialEntries { model.seed(entries: initialEntries) }
            return model
        }())
    }

    private typealias Style = FolderPopupStyle

    private var currentURL: URL { drillStack.last ?? rootURL }

    /// Total cells = items + the last cell "Open in Finder". The column count is derived from it
    /// (deterministic, not measured).
    private var totalCellCount: Int { model.entries.count + 1 }
    private var columnCount: Int { min(Style.maxColumns, max(Style.minColumns, totalCellCount)) }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(Style.cellWidth), spacing: Style.cellSpacing), count: columnCount)
    }
    private var contentWidth: CGFloat {
        CGFloat(columnCount) * Style.cellWidth
            + CGFloat(columnCount - 1) * Style.cellSpacing
            + Style.contentPadding * 2
    }
    private var availableGridHeight: CGFloat { min(max(140, maxContentHeight), Style.maxGridHeight) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            DockPanelBackdrop(theme: theme,
                              cornerRadius: DockShape.panelCornerRadius,
                              usesLiquidGlass: usesLiquidGlass)

            Group {
                if gridHeight > availableGridHeight + 0.5 {
                    ScrollView(.vertical, showsIndicators: true) { gridBody }
                        .frame(height: availableGridHeight)
                } else {
                    gridBody
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DockShape.panelCornerRadius, style: .continuous))
        }
        .dockPanelRim(cornerRadius: DockShape.panelCornerRadius,
                      style: theme.panelRimStyle,
                      lineWidth: theme.panelRimLineWidth,
                      usesLiquidGlass: usesLiquidGlass)
        // As in the native one: after drill-down a back arrow floats at the top left (no header, takes no
        // layout space).
        .overlay(alignment: .topLeading) { backChip }
        // The fade of the whole panel is done by the coordinator at the AppKit layer (panel.alphaValue,
        // background/shadow fade together), so the content layer adds no extra scale/opacity: two stacked
        // fades multiply the curves, and scaling large content looks like "unfolding from a corner". The
        // shadow extent (radius+|y|) must be <= shadowPadding(20), or it is hard-clipped at the panel's
        // transparent edge (the reported clipped look).
        .dockShadow(theme.popupShadow)
        .padding(PanelCoordinator.shadowPadding)
        .onAppear {
            model.display(url: rootURL)
            if model.didFirstLoad { animatesGridChanges = true }   // preload path: the first frame is already complete, later changes may animate
        }
        .onDisappear { model.stop() }
        .onChange(of: model.didFirstLoad) { loaded in
            guard loaded else { return }
            // Timeout fallback path: the first backfill frame is not animated, animation is enabled on the
            // next runloop, so it appears as one block.
            DispatchQueue.main.async { animatesGridChanges = true }
        }
        .onChange(of: drillStack) { _ in model.display(url: currentURL) }
        .onChange(of: gridHeight) { _ in onContentResize() }
        // A column-count change can change width only, not height (e.g. 5->6 cells in the same row); the
        // height probe does not fire, so reposition is driven separately.
        .onChange(of: columnCount) { _ in onContentResize() }
    }

    // MARK: - Floating back button (drill-down only)

    @ViewBuilder
    private var backChip: some View {
        if !drillStack.isEmpty {
            Image(systemName: "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.backChipGlyph.color)
                .frame(width: Style.backChipSize, height: Style.backChipSize)
                .background(Circle().fill(theme.backChipFill.color))
                .overlay(Circle().strokeBorder(theme.backChipRim.color, lineWidth: 0.5))
                .contentShape(Circle())
                .onTapGesture { _ = drillStack.removeLast() }
                .help(Text("Back"))
                .padding(10)
                .transition(.opacity)
        }
    }

    // MARK: - Grid

    private var gridBody: some View {
        VStack(spacing: 0) {
            if model.loadFailed {
                Text("Can’t read this folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.popupPrimaryText.color)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            } else if model.entries.isEmpty && model.didFirstLoad {
                Text("This folder is empty")
                    .font(.system(size: Style.labelSize))
                    .foregroundStyle(theme.popupSecondaryText.color)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            LazyVGrid(columns: columns, spacing: Style.cellSpacing) {
                ForEach(model.entries, id: \.url) { entry in
                    FolderGridCell(iconPath: entry.url.path,
                                   staticIcon: nil,
                                   label: entry.name,
                                   dragURL: entry.url,
                                   contextMenu: { cellMenu(for: entry) }) { open(entry) }
                }
                // Native-style last cell: open the current directory in Finder.
                FolderGridCell(iconPath: nil, staticIcon: Self.finderIcon, label: String(localized: "Open in Finder")) {
                    NSWorkspace.shared.open(currentURL)
                    onFileOpened()
                }
            }
            .animation(animatesGridChanges ? .easeInOut(duration: DrawerAnimation.duration) : nil,
                       value: model.entries.map(\.url))
        }
        // On drill-down, leave extra room at the top for the floating back button so it does not cover the
        // first row.
        .padding(.top, drillStack.isEmpty ? Style.contentPadding : Style.contentPadding + Style.backChipSize + 4)
        .padding([.horizontal, .bottom], Style.contentPadding)
        .frame(width: contentWidth)
        .background(GeometryReader { g in
            Color.clear.preference(key: FolderGridHeightKey.self, value: g.size.height)
        })
        .onPreferenceChange(FolderGridHeightKey.self) { gridHeight = $0 }
    }

    private func open(_ entry: FolderContentsLoader.Entry) {
        if entry.isDirectory {
            drillStack.append(entry.url)
        } else {
            NSWorkspace.shared.open(entry.url)
            onFileOpened()
        }
    }

    /// Context menu for an item (hand-built NSMenu, project rule). "Pin to pinned zone" is offered only for
    /// an unpinned directory.
    private func cellMenu(for entry: FolderContentsLoader.Entry) -> NSMenu {
        let canPin = entry.isDirectory && !(isFolderPinned?(entry.url) ?? true)
        return FileItemMenuBuilder.menu(for: .init(
            url: entry.url,
            isDirectory: entry.isDirectory,
            closePopup: onFileOpened,
            pinFolder: canPin ? { onPinFolder?(entry.url) } : nil
        ))
    }

    private static let finderIcon: NSImage = FolderIconResolver.resolve("/System/Library/CoreServices/Finder.app")
}

/// Shared size constants for popup grids (used by the folder popup and the shelf popup; do not keep a
/// drifting copy on each side). Column derivation: columnCount = clamp(total cells, minColumns, maxColumns),
/// and the width is **derived** from the column count, never falling back to a measured value (fittingSize
/// feedback loop). maxColumns=8 is the settled "a bit wider" decision, do not change it back to 6.
enum FolderPopupStyle {
    static let iconSize: CGFloat = 64          // large icons, as in native Stacks
    static let cellWidth: CGFloat = 96
    static let cellHeight: CGFloat = 104
    static let cellSpacing: CGFloat = 10
    static let contentPadding: CGFloat = 16
    static let minColumns = 3
    static let maxColumns = 8                  // full-row content width ≈ 870pt (decision: a bit wider)
    /// Upper limit of the grid's displayed height (a little over 4 rows, scrolls internally beyond it;
    /// decision: a bit shorter).
    static let maxGridHeight: CGFloat = 470
    static let labelSize: CGFloat = 11
    static let backChipSize: CGFloat = 26
}

/// A single cell: 64pt icon + a two-line small name, with a white backing on hover. Only a separate struct
/// lets each cell hold its own hover state. Shared by item cells and the "Open in Finder" last cell (which
/// has no drag / no menu). Reused by the shelf popup (phase B), hence internal. `dragURL` non-nil -> attaches
/// a system file drag `.onDrag` (dragging the real file out to another app; the system drag image is the
/// native effect, and the project rule "No System Drag Image" covers taskbar/drawer chip drags only, so
/// dragging files out is exempt).
struct FolderGridCell: View {
    let iconPath: String?
    let staticIcon: NSImage?
    let label: String
    var dragURL: URL? = nil
    var contextMenu: (() -> NSMenu)? = nil
    let onTap: () -> Void

    private let theme = DockThemeTokens.standard

    @State private var isHovering = false
    @State private var resolvedIcon: NSImage?

    init(iconPath: String?,
         staticIcon: NSImage?,
         label: String,
         dragURL: URL? = nil,
         contextMenu: (() -> NSMenu)? = nil,
         onTap: @escaping () -> Void) {
        self.iconPath = iconPath
        self.staticIcon = staticIcon
        self.label = label
        self.dragURL = dragURL
        self.contextMenu = contextMenu
        self.onTap = onTap
        // Synchronous cache lookup on the first frame: the coordinator prewarmed before opening
        // (FolderIconResolver.warm), so on a hit the icon is lit on the first frame. Without this step every
        // icon is filled in asynchronously, appearing one by one from the top left toward the bottom right,
        // which is the real cause of the reported "popup starts appearing from the top-left corner"
        // (2026-07-07, introduced by 48a2415).
        _resolvedIcon = State(initialValue: iconPath.flatMap { FolderIconResolver.cached($0) })
    }

    var body: some View {
        if let dragURL {
            core.onDrag { NSItemProvider(contentsOf: dragURL) ?? NSItemProvider() }
        } else {
            core
        }
    }

    private var core: some View {
        VStack(spacing: 5) {
            Image(nsImage: currentIcon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .opacity(resolvedIcon == nil && staticIcon == nil ? 0 : 1)
                .task(id: iconPath) {
                    guard let path = iconPath, resolvedIcon == nil else { return }
                    // Fallback path (cells the prewarm missed / deep scroll / drill-down): resolve + write
                    // the cache off-main, then read back from the thread-safe cache (no NSImage crosses
                    // actors, avoiding the macOS 14 Sendable warning). Once resolved it shows directly,
                    // **with no per-cell fade-in**: an animated per-cell fade would sweep from top left to
                    // bottom right in completion order and reproduce the reported directional look.
                    await Task.detached(priority: .userInitiated) { _ = FolderIconResolver.resolve(path) }.value
                    resolvedIcon = FolderIconResolver.cached(path)
                }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(theme.popupCellLabel.color)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .frame(width: 96, height: 104)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.popupCellHover.color(active: isHovering))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { onTap() }
        .nativeContextMenu { contextMenu?() ?? NSMenu() }
        .help(label)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
    }

    private var currentIcon: NSImage {
        if let s = staticIcon { return s }
        if let r = resolvedIcon { return r }
        return Self.placeholderIcon
    }

    private static let placeholderIcon = NSImage(size: NSSize(width: 64, height: 64))
}

private struct FolderGridHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
