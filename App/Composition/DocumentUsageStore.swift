import AppKit
import Foundation

/// Count ledger for "most used files" (the sort data source for the recents section of the context menu).
///
/// macOS only records "recently opened", not counts, so NitiaDock counts on its own from the feature's
/// launch, from two sources:
/// ① **Changes to the top entry of the system recents list**: sfl directory watching (`DirectoryWatcher`)
///    + resampling on app activation / menu open. Directory watching gives no guarantee on "whether the sfl
///    is written by atomic replace" (TCC directory, cannot be probed on a dev machine), so it is only an
///    **accelerator**; resampling is the fallback for correctness. At the latest on the next right-click of
///    that app, the previous top-entry change is recorded.
/// ② **Opening from the NitiaDock menu** (`recordOpen`): +1 directly, and `lastTop` is set to that file
///    along the way so the following sfl update is not counted again by ①.
///
/// Storage: a JSON file (Application Support/<bundle id>/document-usage.json), **not UserDefaults**. The
/// worst case of 40 bundles × 200 entries is several hundred KB, and putting that in the preferences file
/// would slow down every defaults write. Pure logic (sorting / eviction / count decisions) is in
/// `DocumentUsageRanking` (unit tested); this only handles side effects.
@MainActor
final class DocumentUsageStore {
    /// Menu building is an AppKit side-effect path, so it uses a shared instance following the
    /// `AppDisplayNameResolver` precedent, instead of injecting an environment object into each of the three
    /// NSHostingViews.
    static let shared = DocumentUsageStore()

    private var usageByBundle: [String: BundleDocumentUsage]
    private var watcher: DirectoryWatcher?
    private var activationObserver: NSObjectProtocol?
    /// When directory watching fires, mtime identifies "which bundle's sfl changed", and only those are
    /// resampled.
    private var mtimeByFile: [String: Date] = [:]
    private var saveWork: DispatchWorkItem?
    private let ioQueue = DispatchQueue(label: "no.thilip.nitiadock.document-usage", qos: .utility)

    private init() {
        // Synchronous load: the file is capped at a few hundred KB and it happens once, so paying a few ms on
        // first access (context menu or start) is acceptable.
        usageByBundle = DocumentUsageDisk.load()
    }

    // MARK: Lifecycle (AppDelegate: started while the taskbar runs, stopped on suspend / quit)

    func start() {
        guard watcher == nil else { return }
        watcher = DirectoryWatcher(path: DocumentUsageDisk.sharedListDir) { [weak self] in
            self?.directoryChanged()
        }
        // Establish the mtime baseline (the round where known is empty only records, it does not sample).
        directoryChanged()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let bid = app?.bundleIdentifier else { return }
            MainActor.assumeIsolated { self?.resampleInBackground(bundleIDs: [bid]) }
        }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    // MARK: Menu-side entry points

    /// Synchronous sampling on menu open: the caller has just read this bundle's recents list and hands the
    /// top entry in.
    func noteRecentSample(bundleID: String, topPath: String?) {
        var usage = usageByBundle[bundleID] ?? BundleDocumentUsage()
        let previous = usage.lastTop
        usage.lastTop = topPath
        if DocumentUsageRanking.shouldCountTopChange(previousTop: previous, newTop: topPath), let topPath {
            usage.files = DocumentUsageRanking.bumped(usage.files, path: topPath, at: Date())
            usage.touchedAt = Date()
        } else if previous != topPath {
            usage.touchedAt = Date()
        }
        guard usageByBundle[bundleID] != usage else { return }
        usageByBundle[bundleID] = usage
        usageByBundle = DocumentUsageRanking.prunedBundles(usageByBundle)
        scheduleSave()
    }

    /// A file was opened from the NitiaDock menu: +1 directly, and lastTop is set to it (prevents double
    /// counting via source ①).
    func recordOpen(bundleID: String, path: String) {
        var usage = usageByBundle[bundleID] ?? BundleDocumentUsage()
        usage.files = DocumentUsageRanking.bumped(usage.files, path: path, at: Date())
        usage.lastTop = path
        usage.touchedAt = Date()
        usageByBundle[bundleID] = usage
        usageByBundle = DocumentUsageRanking.prunedBundles(usageByBundle)
        scheduleSave()
    }

    /// Ranking (count descending -> most recently opened descending -> system recents order). Existence is
    /// checked only for "count-only" paths (the system recents side was already checked by
    /// `RecentDocumentsReader`), and deleted files are dropped from the ledger along the way.
    func ranked(bundleID: String, recentPaths: [String], limit: Int = 10) -> [String] {
        let counts = usageByBundle[bundleID]?.files ?? [:]
        let candidates = DocumentUsageRanking.ranked(
            counts: counts,
            recentPaths: recentPaths,
            limit: limit + 8
        )
        let recentSet = Set(recentPaths)
        var removedDead = false
        let alive = candidates.filter { path in
            if recentSet.contains(path) { return true }
            if FileManager.default.fileExists(atPath: path) { return true }
            usageByBundle[bundleID]?.files.removeValue(forKey: path)
            removedDead = true
            return false
        }
        if removedDead { scheduleSave() }
        return Array(alive.prefix(limit))
    }

    // MARK: Sampling

    private func directoryChanged() {
        let known = mtimeByFile
        ioQueue.async { [weak self] in
            let fm = FileManager.default
            let dir = DocumentUsageDisk.sharedListDir
            var next: [String: Date] = [:]
            var changed: [String] = []
            let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            for name in names where name.contains(".sfl") {
                let path = dir + "/" + name
                guard let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { continue }
                next[name] = mtime
                if known[name] != mtime {
                    changed.append((name as NSString).deletingPathExtension)
                }
            }
            DispatchQueue.main.async { [weak self, next, changed] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.mtimeByFile = next
                    guard !known.isEmpty else { return } // First round only sets the baseline
                    self.resampleInBackground(bundleIDs: changed)
                }
            }
        }
    }

    private func resampleInBackground(bundleIDs: [String]) {
        guard !bundleIDs.isEmpty else { return }
        ioQueue.async { [weak self] in
            var tops: [String: String?] = [:]
            for bid in Set(bundleIDs) {
                tops[bid] = RecentDocumentsReader.recentDocuments(for: bid, maxCount: 1).first?.path
            }
            DispatchQueue.main.async { [weak self, tops] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for (bid, top) in tops { self.noteRecentSample(bundleID: bid, topPath: top) }
                }
            }
        }
    }

    // MARK: Persistence (coalesced 1s, utility queue, atomic write)

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = usageByBundle
        let work = DispatchWorkItem { DocumentUsageDisk.write(snapshot) }
        saveWork = work
        ioQueue.asyncAfter(deadline: .now() + 1, execute: work)
    }
}

/// Disk and paths (file-private): kept outside the @MainActor class so the io queue calls them directly, free
/// of isolation.
private enum DocumentUsageDisk {
    static let sharedListDir =
        ("~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"
            as NSString).expandingTildeInPath

    struct Archive: Codable {
        var version: Int
        var bundles: [String: BundleDocumentUsage]
    }

    static var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let bundleID = Bundle.main.bundleIdentifier ?? "no.thilip.nitiadock"
        return base.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("document-usage.json")
    }

    static func load() -> [String: BundleDocumentUsage] {
        guard let data = try? Data(contentsOf: storeURL),
              let archive = try? JSONDecoder().decode(Archive.self, from: data),
              archive.version == 1 else { return [:] }
        return archive.bundles
    }

    static func write(_ bundles: [String: BundleDocumentUsage]) {
        let archive = Archive(version: 1, bundles: bundles)
        guard let data = try? JSONEncoder().encode(archive) else { return }
        let url = storeURL
        // Document paths are private: the folder and the file are readable by the owner only.
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try? manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? data.write(to: url, options: .atomic)
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
