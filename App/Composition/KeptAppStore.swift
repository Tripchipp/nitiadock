import Foundation
import os

/// List of "Keep in Dock" apps. While running they show window cards
/// as usual; after quitting they collapse into one app icon in place.
///
/// Since 2026-08-20 Finder is also managed by this store (`FinderTaskbarPolicy`),
/// checked by default and uncheckable. Order is managed centrally by
/// `StripOrderStore`; this store only handles membership and persistence.
@MainActor
final class KeptAppStore: ObservableObject {
    /// V3 lets a messaging app also be kept (kept alone now decides post-exit
    /// visibility). Key existence is the migration marker, including an explicitly
    /// persisted empty array on a fresh install. Older kept keys stay frozen
    /// read-only so a code rollback still reads the exact pre-upgrade list.
    static let defaultsKey = "keptAppBundleIDsV3"
    static let previousDefaultsKey = "keptAppBundleIDsV2"
    /// One-time Finder seeding flag. **The V3 key cannot be reused**: its existence is
    /// already a migration marker, and existing users have had V3 written long ago.
    /// Only a separate key can express "has the one-time Finder check been applied".
    static let finderSeedKey = "keptAppFinderSeededV1"
    private static let v1Key = "keptAppBundleIDs"
    private static let legacyKey = "pinnedAppBundleIDs"
    private static let drawerKey = "drawerBundleIDs"
    private static let messagingV2Key = "messagingBundleIDsV2"
    private static let messagingV1Key = "messagingBundleIDs"

    @Published private(set) var bundleIDs: [String]

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "no.thilip.nitiadock", category: "kept-app-store")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Already on V3.
        if defaults.object(forKey: Self.defaultsKey) != nil {
            let stored = defaults.stringArray(forKey: Self.defaultsKey) ?? []
            bundleIDs = Self.cleaned(stored)
            if bundleIDs != stored { persist() }
            seedFinderOnce()
            return
        }

        // First migration to V3. Messaging apps now join kept so they stay visible
        // after exit under the unified model. Frozen legacy keys (V2 / V1 / pinned)
        // are left untouched for a clean code rollback.
        let messaging = Self.authoritativeMessagingNames(defaults)
        let seed: [String]
        if defaults.object(forKey: Self.previousDefaultsKey) != nil {
            // Kept V2 exists: keep its order first, messaging appended.
            let v2 = defaults.stringArray(forKey: Self.previousDefaultsKey) ?? []
            seed = v2 + messaging
        } else {
            // No kept V2 (upgrading straight past it): fold V1 + pinned + drawer + messaging.
            let v1 = defaults.stringArray(forKey: Self.v1Key) ?? []
            let legacy = defaults.stringArray(forKey: Self.legacyKey) ?? []
            let drawer = defaults.stringArray(forKey: Self.drawerKey) ?? []
            seed = v1 + legacy + drawer + messaging
        }
        bundleIDs = Self.cleaned(seed)
        persist() // Empty is intentional: V3 key existence is the migration marker.
        seedFinderOnce()
        logger.info("initialized keptAppBundleIDsV3 with \(self.bundleIDs.count) entries")
    }

    /// Finder is checked by default, applied once only. Nothing changes visibly for
    /// existing users after upgrading; if the user later unchecks it, the flag is already
    /// true and the next launch will not turn it back on. Appended at the **tail**: neither
    /// the existing kept order nor `StripOrderStore`'s cross-reboot ranks are disturbed.
    private func seedFinderOnce() {
        guard !defaults.bool(forKey: Self.finderSeedKey) else { return }
        defaults.set(true, forKey: Self.finderSeedKey)
        guard ForkDefaults.keepsFinderByDefault else { return }   // fork: the one-shot still counts as done
        guard !contains(FinderTaskbarPolicy.bundleID) else { return }
        add(FinderTaskbarPolicy.bundleID)
        logger.info("seeded Finder into keptAppBundleIDsV3 (one-shot)")
    }

    /// Authoritative messaging names for the kept-V3 seed, independent of store
    /// init order: if the messaging V2 key exists (even an explicit empty array)
    /// read only it; otherwise fall back to the legacy messaging key. Never union.
    private static func authoritativeMessagingNames(_ defaults: UserDefaults) -> [String] {
        if defaults.object(forKey: messagingV2Key) != nil {
            return defaults.stringArray(forKey: messagingV2Key) ?? []
        }
        return defaults.stringArray(forKey: messagingV1Key) ?? []
    }

    /// Only the non-empty check remains: since 2026-08-20 Finder
    /// may also be kept, so there is no exception list here.
    static func canKeep(_ bundleID: String) -> Bool {
        normalized(bundleID) != nil
    }

    func canKeep(_ bundleID: String) -> Bool {
        Self.canKeep(bundleID)
    }

    func contains(_ bundleID: String) -> Bool {
        guard let normalized = Self.normalized(bundleID) else { return false }
        return bundleIDs.contains(normalized)
    }

    func add(_ bundleID: String) {
        guard Self.canKeep(bundleID),
              let normalized = Self.normalized(bundleID),
              !bundleIDs.contains(normalized) else { return }
        bundleIDs.append(normalized)
        persist()
    }

    func remove(_ bundleID: String) {
        guard let normalized = Self.normalized(bundleID) else { return }
        let previousCount = bundleIDs.count
        bundleIDs.removeAll { $0 == normalized }
        if bundleIDs.count != previousCount {
            persist()
        }
    }

    private static func cleaned(_ bundleIDs: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for bundleID in bundleIDs {
            guard canKeep(bundleID),
                  let normalized = normalized(bundleID),
                  seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }
        return result
    }

    private static func normalized(_ bundleID: String) -> String? {
        let normalized = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func persist() {
        defaults.set(bundleIDs, forKey: Self.defaultsKey)
    }
}
