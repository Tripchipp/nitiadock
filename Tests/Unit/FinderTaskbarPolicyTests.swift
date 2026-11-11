import XCTest

final class FinderTaskbarPolicyTests: XCTestCase {

    func testIsFinderMatchesOnlyFinder() {
        XCTAssertTrue(FinderTaskbarPolicy.isFinder("com.apple.finder"))
        XCTAssertFalse(FinderTaskbarPolicy.isFinder("com.apple.finder.helper"))
        XCTAssertFalse(FinderTaskbarPolicy.isFinder(nil))
        XCTAssertFalse(FinderTaskbarPolicy.isFinder(""))
    }

    /// With "Keep in Dock" unchecked, Finder's app-level entry is
    /// no longer shown. That is the gate for the whole feature.
    func testAppLevelEntryFollowsKept() {
        XCTAssertTrue(FinderTaskbarPolicy.showsAppLevelEntry(isKept: true))
        XCTAssertFalse(FinderTaskbarPolicy.showsAppLevelEntry(isKept: false))
    }

    /// Drawer and keep are opened up; the messaging zone still is not.
    func testMessagingStaysClosedToFinder() {
        XCTAssertFalse(FinderTaskbarPolicy.canMarkMessaging(FinderTaskbarPolicy.bundleID))
        XCTAssertFalse(FinderTaskbarPolicy.canMarkMessaging(""))
        XCTAssertTrue(FinderTaskbarPolicy.canMarkMessaging("com.example.chat"))
    }
}
