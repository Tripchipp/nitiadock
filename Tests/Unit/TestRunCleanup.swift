import Foundation
import XCTest

/// Removes the preference domains the tests create. Many tests give `UserDefaults(suiteName:)` a
/// fresh UUID-named suite and never delete it, and each one is a .plist in ~/Library/Preferences;
/// over a few months of test runs that came to more than 8 000 files.
///
/// Registered as the test bundle's principal class (`INFOPLIST_KEY_NSPrincipalClass`), so XCTest
/// creates it before the first test. When the bundle finishes it deletes the domains that match a
/// test prefix *and* were written during this run, so nothing that existed before is touched.
final class TestRunCleanup: NSObject, XCTestObservation {
    /// Name prefixes of the suites the tests create. A new test that makes its own suite should use
    /// one of these (the UUID or counter after the prefix keeps runs apart).
    static let prefixes = [
        "com.tungsten.edge.tests.", "no.thilip.nitiadock.tests.", "test-",
        "SettingsCoordinatorTests.", "WindowInventoryAnomalyLogTests.",
        "ForkMultiDisplayChoiceTests-", "ForkMiddleClickActionsTests-", "ForkHapticsPolicyTests-",
    ]

    private let started = Date()

    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        let removed = Self.removeTestDomains(createdAfter: started.addingTimeInterval(-1))
        if removed > 0 { print("TestRunCleanup: removed \(removed) test preference domains") }
    }

    @discardableResult
    static func removeTestDomains(createdAfter cutoff: Date?) -> Int {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return 0 }
        var removed = 0
        for file in files where file.pathExtension == "plist" {
            let domain = file.deletingPathExtension().lastPathComponent
            guard prefixes.contains(where: { domain.hasPrefix($0) }) else { continue }
            if let cutoff {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard let modified, modified >= cutoff else { continue }
            }
            UserDefaults.standard.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: file)
            removed += 1
        }
        return removed
    }
}
