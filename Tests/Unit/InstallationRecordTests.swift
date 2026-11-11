import XCTest
@testable import NitiaDock

/// First-launch timestamp.
///
/// This type has one property that really matters: **once written, never overwritten**. If the app ever
/// becomes paid, it is the only evidence that can automatically prove "users from before the announcement
/// stay free forever". If any launch resets it to today, this machine's early-user status is lost for good
/// and cannot be recovered from anywhere. So the overwrite test below is not a formality: it locks an
/// irreversible promise to users.
final class InstallationRecordTests: XCTestCase {

    func testFirstCallRecordsNowAndReturnsIt() {
        let defaults = makeDefaults()
        let now = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertNil(InstallationRecord.firstLaunchDate(defaults: defaults))

        let recorded = InstallationRecord.recordFirstLaunchIfNeeded(defaults: defaults, now: now)

        XCTAssertEqual(recorded, now)
        XCTAssertEqual(InstallationRecord.firstLaunchDate(defaults: defaults), now)
    }

    /// Regression lock: later launches must **never** overwrite the earliest value.
    func testLaterLaunchesNeverOverwriteTheOriginalDate() {
        let defaults = makeDefaults()
        let firstLaunch = Date(timeIntervalSince1970: 1_000_000)
        let muchLater = Date(timeIntervalSince1970: 9_000_000)

        InstallationRecord.recordFirstLaunchIfNeeded(defaults: defaults, now: firstLaunch)

        // Simulate every later launch
        let secondLaunch = InstallationRecord.recordFirstLaunchIfNeeded(defaults: defaults, now: muchLater)
        let thirdLaunch = InstallationRecord.recordFirstLaunchIfNeeded(defaults: defaults, now: Date())

        XCTAssertEqual(secondLaunch, firstLaunch)
        XCTAssertEqual(thirdLaunch, firstLaunch)
        XCTAssertEqual(InstallationRecord.firstLaunchDate(defaults: defaults), firstLaunch)
    }

    /// Existing users upgrading to this version record the upgrade date, not the real first-install date.
    /// That is a known, accepted limit, since it still predates any future paid announcement. This test pins
    /// the semantics so nobody "fixes" it as a bug.
    func testExistingUserUpgradingRecordsUpgradeDayAndThenFreezes() {
        let defaults = makeDefaults()
        let upgradeDay = Date(timeIntervalSince1970: 5_000_000)

        let recorded = InstallationRecord.recordFirstLaunchIfNeeded(defaults: defaults, now: upgradeDay)
        XCTAssertEqual(recorded, upgradeDay)

        InstallationRecord.recordFirstLaunchIfNeeded(defaults: defaults, now: Date(timeIntervalSince1970: 6_000_000))
        XCTAssertEqual(InstallationRecord.firstLaunchDate(defaults: defaults), upgradeDay)
    }

    /// The key name is on users' disks: renaming it wipes everyone's first-install record, and all would be
    /// misjudged as new users when going paid.
    func testKeyNameIsFrozen() {
        XCTAssertEqual(InstallationRecord.firstLaunchDateKey, "com.tungsten.edge.firstLaunchDate")
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "com.tungsten.edge.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
