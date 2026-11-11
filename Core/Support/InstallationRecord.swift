import Foundation

/// Records when this machine **first ran NitiaDock**. Written once, never overwritten afterwards.
///
/// ## Why it is needed
///
/// NitiaDock will move from free to a one-time purchase, with the promise that
/// "anyone already using it before the announcement date stays free forever".
/// Honoring that promise needs a credential that identifies existing users **automatically**.
///
/// An email list alone is not enough: only a minority of real existing users are willing to leave an
/// email, and the majority would find themselves excluded, which is exactly the resentment the
/// promise is meant to avoid. So the primary credential is this local timestamp (automatic, invisible
/// to the user), and the email list is only the reissue channel after a machine change / reinstall.
///
/// ## Two known and accepted limits
///
/// - **Existing users already on the app** get the "upgrade date" written, not
///   the real first-install date, when they upgrade to a version with this key.
///   Acceptable: it is still earlier than the future pricing announcement date, so the verdict is unaffected.
/// - **It can be forged**: editing the plist changes it. **Do not add server-side
///   verification for this**: people who edit plists are not the target customers, and
///   what gets forged away is only the group that was free anyway, so it is not worth it.
///
/// Deleting the app does not clear UserDefaults, so it survives a reinstall;
/// only a machine change loses it, and the email list covers that.
enum InstallationRecord {
    /// ⚠️ This key name is on users' disks. **Renaming it = zeroing every existing user's first-install
    /// record**, and they would be misjudged as new users when pricing starts. A rename requires a migration.
    static let firstLaunchDateKey = "com.tungsten.edge.firstLaunchDate"

    static func firstLaunchDate(defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: firstLaunchDateKey) as? Date
    }

    /// The first call writes `now` and returns it; every later call returns that earliest value unchanged.
    ///
    /// **"Never overwrite once present" is the whole point of this type**: if any launch resets it
    /// to today, this machine's existing-user status is lost permanently and cannot be recovered.
    @discardableResult
    static func recordFirstLaunchIfNeeded(
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) -> Date {
        if let existing = firstLaunchDate(defaults: defaults) {
            return existing
        }
        defaults.set(now, forKey: firstLaunchDateKey)
        return now
    }
}
