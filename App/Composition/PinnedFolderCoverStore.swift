import AppKit
import QuickLookThumbnailing

/// Cover of a pinned folder chip: the Quick Look thumbnail of the folder's first file in the current
/// sort order. Enumeration runs on a background queue; each folder has a generation counter, and
/// when the async QL callback returns it publishes only if the generation is unchanged, so an old
/// result cannot overwrite a newer cover. @Published is written on the MainActor only.
/// Chip cover: isThumbnail decides rendering. A real thumbnail is square-cropped
/// with a thin white border; an icon (file/folder) is fitted uncropped.
struct FolderCover: Equatable {
    var image: NSImage
    var isThumbnail: Bool
}

@MainActor
final class PinnedFolderCoverStore: ObservableObject {
    /// path → cover. Fallback chain: thumbnail of the first file in the
    /// current sort order → its icon → the folder icon (empty folder).
    @Published private(set) var covers: [String: FolderCover] = [:]

    private struct CacheEntry {
        let order: FolderSortOrder
        let entries: [FolderContentsLoader.Entry]
    }
    /// Full folder contents pre-read and cached in the background, used by the popup for
    /// zero-delay retrieval. Hot cache first; not @Published, to avoid needless global redraws.
    private var cache: [String: CacheEntry] = [:]

    private var watchers: [String: DirectoryWatcher] = [:]
    private var generations: [String: Int] = [:]
    /// coverFilePath|modDate → thumbnail; not regenerated while the cover file is unchanged.
    private let thumbnailCache = NSCache<NSString, NSImage>()
    /// Per-folder sort order (injected by AppDelegate, reads PinnedFolderStore):
    /// cover = first file in the current sort order, same basis as the popup
    /// grid (like native Stacks: change the sort and the chip cover follows).
    private let sortOrderProvider: (String) -> FolderSortOrder

    init(sortOrderProvider: @escaping (String) -> FolderSortOrder = { _ in .default }) {
        self.sortOrderProvider = sortOrderProvider
    }

    /// Returns the hot cache if it hits and the sort order matches. If
    /// nil, the caller should run the synchronous preload fallback.
    func cachedEntries(for path: String, order: FolderSortOrder) -> [FolderContentsLoader.Entry]? {
        guard let entry = cache[path], entry.order == order else { return nil }
        return entry.entries
    }

    /// Reconciles with PinnedFolderStore.folderPaths: adds and
    /// removes watchers as needed and refreshes all covers once.
    func sync(paths: [String]) {
        let wanted = Set(paths)
        for gone in Array(watchers.keys) where !wanted.contains(gone) {
            watchers[gone]?.stop()
            watchers[gone] = nil
            covers[gone] = nil
            cache[gone] = nil
            generations[gone] = nil
        }
        for path in paths {
            if watchers[path] == nil {
                // The DirectoryWatcher callback is already on the main
                // thread; the Task wrapper satisfies MainActor isolation.
                watchers[path] = DirectoryWatcher(path: path) { [weak self] in
                    Task { @MainActor [weak self] in self?.refresh(path: path) }
                }
            }
            refresh(path: path)
        }
    }

    private func refresh(path: String) {
        let generation = (generations[path] ?? 0) + 1
        generations[path] = generation
        let folderURL = URL(fileURLWithPath: path)
        let order = sortOrderProvider(path)   // read on the MainActor, the background block uses the value

        Task.detached(priority: .utility) { [weak self] in
            let entries = (try? FolderContentsLoader.load(directory: folderURL)) ?? []
            let sortedEntries = FolderContentsLoader.sorted(entries, by: order)
            let newest = FolderContentsLoader.coverFile(in: sortedEntries, order: order)
            await MainActor.run { [weak self] in
                guard let self, self.generations[path] == generation else { return }
                self.cache[path] = CacheEntry(order: order, entries: sortedEntries)
                self.publishCover(path: path, newest: newest, generation: generation)
            }
        }
    }

    private func publishCover(path: String, newest: FolderContentsLoader.Entry?, generation: Int) {
        guard let newest else {
            covers[path] = FolderCover(image: Self.icon(forPath: path), isThumbnail: false)
            return
        }
        let cacheKey = "\(newest.url.path)|\(newest.dateModified?.timeIntervalSince1970 ?? 0)"
        if let cached = thumbnailCache.object(forKey: cacheKey as NSString) {
            covers[path] = FolderCover(image: cached, isThumbnail: true)
            return
        }
        // Use the file's icon as a placeholder first, then upgrade seamlessly once the QL thumbnail is ready.
        covers[path] = FolderCover(image: Self.icon(forPath: newest.url.path), isThumbnail: false)

        let request = QLThumbnailGenerator.Request(
            fileAt: newest.url,
            size: CGSize(width: 64, height: 64),
            scale: 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let cgImage = representation?.cgImage else { return }  // generation failed: keep the placeholder icon
            let image = NSImage(cgImage: cgImage, size: .zero)
            Task { @MainActor [weak self] in
                guard let self, self.generations[path] == generation else { return }
                self.thumbnailCache.setObject(image, forKey: cacheKey as NSString)
                self.covers[path] = FolderCover(image: image, isThumbnail: true)
            }
        }
    }

    /// NSWorkspace icons are shared cached objects; `.copy()`
    /// before changing size (same convention as AppMenuFragments).
    static func icon(forPath path: String) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path)
        guard let copy = icon.copy() as? NSImage else { return icon }
        copy.size = NSSize(width: 64, height: 64)
        return copy
    }
}
