import Foundation

/// fork: carries settings across the rename from NitiaBar (`no.thilip.nitiabar`) to NitiaDock.
///
/// Everything the app persists hangs off the bundle id: the preference domain, and one folder in
/// Application Support (`DocumentUsageStore.storeURL`). A new id therefore starts empty, and
/// `InstallLineage` would call that a first install and replay the welcome guide. This copies both
/// over once, before anything reads them. It never deletes the old copies, and it does nothing
/// when the new domain already has content, so running it on every launch is safe.
///
/// What cannot be carried: the Accessibility and Automation grants (macOS keys them on the bundle
/// id; the user grants them again) and the login item (`SMAppService` registers the bundle id, so
/// "launch at login" reads as off until it is ticked again).
enum ForkBundleMigration {
    static let previousBundleID = "no.thilip.nitiabar"

    /// `AppDelegate` calls this in place of `InstallLineage.capture()`, which has to be the first
    /// thing that touches defaults; migrating first keeps a renamed install classified `.priorUse`.
    static func migrateThenCaptureLineage() -> InstallLineage {
        if let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            migrate(defaults: .standard, from: previousBundleID, to: bundleID, applicationSupport: support)
        }
        return InstallLineage.capture()
    }

    @discardableResult
    static func migrate(
        defaults: UserDefaults,
        from oldID: String,
        to newID: String,
        applicationSupport: URL?,
        fileManager: FileManager = .default
    ) -> Bool {
        guard oldID != newID else { return false }
        var migrated = false
        if defaults.persistentDomain(forName: newID)?.isEmpty ?? true,
           let old = defaults.persistentDomain(forName: oldID), !old.isEmpty {
            defaults.setPersistentDomain(old, forName: newID)
            migrated = true
        }
        if let applicationSupport {
            let source = applicationSupport.appendingPathComponent(oldID, isDirectory: true)
            let destination = applicationSupport.appendingPathComponent(newID, isDirectory: true)
            if fileManager.fileExists(atPath: source.path), !fileManager.fileExists(atPath: destination.path),
               (try? fileManager.copyItem(at: source, to: destination)) != nil {
                migrated = true
            }
        }
        return migrated
    }
}
