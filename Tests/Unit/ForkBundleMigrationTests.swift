import XCTest
@testable import NitiaDock

final class ForkBundleMigrationTests: XCTestCase {
    private let oldID = "no.thilip.nitiadock.tests.old"
    private let newID = "no.thilip.nitiadock.tests.new"
    private var support: URL!

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("nitiadock-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        UserDefaults.standard.removePersistentDomain(forName: oldID)
        UserDefaults.standard.removePersistentDomain(forName: newID)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: oldID)
        UserDefaults.standard.removePersistentDomain(forName: newID)
        try? FileManager.default.removeItem(at: support)
    }

    func testCopiesDefaultsAndApplicationSupportOnce() throws {
        UserDefaults.standard.setPersistentDomain(["keptAppBundleIDsV3": ["com.apple.Safari"]], forName: oldID)
        let oldFolder = support.appendingPathComponent(oldID, isDirectory: true)
        try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: oldFolder.appendingPathComponent("document-usage.json"))

        XCTAssertTrue(ForkBundleMigration.migrate(
            defaults: .standard, from: oldID, to: newID, applicationSupport: support))

        let copied = UserDefaults.standard.persistentDomain(forName: newID)
        XCTAssertEqual(copied?["keptAppBundleIDsV3"] as? [String], ["com.apple.Safari"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: support.appendingPathComponent(newID).appendingPathComponent("document-usage.json").path))
        // The old copies stay: a user who goes back to the old build loses nothing.
        XCTAssertNotNil(UserDefaults.standard.persistentDomain(forName: oldID))
        XCTAssertEqual(InstallLineage.classify(persistentDomain: copied), .priorUse)
    }

    func testLeavesAnExistingNewDomainAlone() {
        UserDefaults.standard.setPersistentDomain(["showDrawer": true], forName: oldID)
        UserDefaults.standard.setPersistentDomain(["showDrawer": false], forName: newID)

        XCTAssertFalse(ForkBundleMigration.migrate(
            defaults: .standard, from: oldID, to: newID, applicationSupport: support))
        XCTAssertEqual(UserDefaults.standard.persistentDomain(forName: newID)?["showDrawer"] as? Bool, false)
    }

    func testNothingToMigrateIsNotAnError() {
        XCTAssertFalse(ForkBundleMigration.migrate(
            defaults: .standard, from: oldID, to: newID, applicationSupport: support))
        // A domain that was removed earlier in the process reads back as `[:]`, not nil.
        XCTAssertTrue(UserDefaults.standard.persistentDomain(forName: newID)?.isEmpty ?? true)
    }
}
