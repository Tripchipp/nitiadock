import Foundation
import os

@MainActor
final class DrawerStore: ObservableObject {
    @Published private(set) var bundleIDs: [String] = []
    /// fork: the list as persisted. Equal to `bundleIDs` while the drawer is enabled; while it is
    /// disabled (`AppSettingsStore.showDrawer` off) `bundleIDs` is empty so every reader sees "no
    /// drawer", and this keeps the user's list so it comes back unchanged on re-enable.
    private var storedBundleIDs: [String] = []
    private(set) var isEnabled = true
    private let key = "drawerBundleIDs"
    private static let legacyFavoriteKey = "launchFavoriteBundleIDs"
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "no.thilip.nitiadock", category: "drawer-store")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var ids = defaults.stringArray(forKey: key) ?? []

        // Migration: merge the old launchFavoriteBundleIDs, then delete
        // the old key (also when the array is empty, leave no stale key)
        if let favorites = defaults.stringArray(forKey: Self.legacyFavoriteKey) {
            defaults.removeObject(forKey: Self.legacyFavoriteKey)
            for fav in favorites where !fav.isEmpty && !ids.contains(fav) {
                ids.append(fav)
            }
            if !favorites.isEmpty {
                logger.info("merged \(favorites.count) entries from launchFavoriteBundleIDs into drawerBundleIDs")
            }
        }

        bundleIDs = ids
        storedBundleIDs = ids
        if let stored = defaults.stringArray(forKey: key), stored != ids {
            persist()
        } else if defaults.stringArray(forKey: key) == nil && !ids.isEmpty {
            persist()
        }
    }

    func contains(_ id: String) -> Bool { bundleIDs.contains(id) }

    func add(_ id: String) {
        guard isEnabled else { return }
        guard !id.isEmpty, !bundleIDs.contains(id) else { return }
        bundleIDs.append(id)
        persist()
    }

    func remove(_ id: String) {
        guard isEnabled else { return }
        bundleIDs.removeAll { $0 == id }
        persist()
    }

    /// fork: see `storedBundleIDs`. Disabling never touches what is on disk.
    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        bundleIDs = enabled ? storedBundleIDs : []
    }

    private func persist() {
        storedBundleIDs = bundleIDs
        defaults.set(bundleIDs, forKey: key)
    }
}
