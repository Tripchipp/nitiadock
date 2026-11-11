import XCTest

/// fork: apps that stop being regular Dock apps (LuLu, ItsyPad) lose their windowless icon.
final class ForkFallbackVisibilityTests: XCTestCase {
    private let running: Set<String> = ["com.brave.Browser", "com.apple.Terminal"]

    func testWindowlessIconOfARegularRunningAppStays() {
        XCTAssertTrue(ForkFallbackVisibility.shows(isAppLevelFallback: true, bundleID: "com.brave.Browser",
                                                   runningRegularBundleIDs: running))
    }

    func testWindowlessIconOfAnAppThatWentBackToTheBackgroundGoes() {
        XCTAssertFalse(ForkFallbackVisibility.shows(isAppLevelFallback: true, bundleID: "com.objective-see.lulu.app",
                                                    runningRegularBundleIDs: running))
    }

    func testWindowCardsAreNeverHidden() {
        // While LuLu's window is open it is a window card, and must show even if the store lags.
        XCTAssertTrue(ForkFallbackVisibility.shows(isAppLevelFallback: false, bundleID: "com.objective-see.lulu.app",
                                                   runningRegularBundleIDs: running))
    }

    func testItemsWithoutABundleIDAreLeftAlone() {
        XCTAssertTrue(ForkFallbackVisibility.shows(isAppLevelFallback: true, bundleID: nil, runningRegularBundleIDs: running))
        XCTAssertTrue(ForkFallbackVisibility.shows(isAppLevelFallback: true, bundleID: "", runningRegularBundleIDs: running))
    }
}
