import XCTest

/// fork: middle-click on Finder and browser cards (`ForkMiddleClickPolicy`,
/// `AppSettingsStore.middleClickActions`).
@MainActor
final class ForkMiddleClickActionsTests: XCTestCase {
    private let own = "no.thilip.nitiadock"

    private func action(
        _ bundleID: String?,
        enabled: Bool = true,
        appLevel: Bool = false,
        windows: Int = 1
    ) -> ForkMiddleClickAction {
        ForkMiddleClickPolicy.action(
            enabled: enabled, bundleID: bundleID, isAppLevelFallback: appLevel,
            appWindowCount: windows, ownBundleID: own
        )
    }

    func testFinderOpensANewWindowFromAWindowCardOrTheWindowlessCard() {
        XCTAssertEqual(action("com.apple.finder", windows: 3), .newWindow)
        XCTAssertEqual(action("com.apple.finder", appLevel: true, windows: 0), .newWindow)
    }

    func testBrowserWithOneWindowOpensAnotherOne() {
        for bundleID in ["com.brave.Browser", "com.google.Chrome", "com.apple.Safari"] {
            XCTAssertEqual(action(bundleID, windows: 1), .newWindow, bundleID)
            XCTAssertEqual(action(bundleID, appLevel: true, windows: 0), .newWindow, bundleID)
        }
    }

    func testBrowserWithSeveralWindowsClosesTheClickedOne() {
        for bundleID in ["com.brave.Browser", "com.google.Chrome", "com.apple.Safari"] {
            XCTAssertEqual(action(bundleID, windows: 2), .closeWindow, bundleID)
            XCTAssertEqual(action(bundleID, windows: 5), .closeWindow, bundleID)
        }
    }

    func testOtherAppsAreNeverQuitOrTouched() {
        XCTAssertEqual(action("com.apple.TextEdit", windows: 1), .fallThrough)
        XCTAssertEqual(action("com.apple.TextEdit", windows: 4), .fallThrough)
        XCTAssertEqual(action("com.apple.TextEdit", appLevel: true, windows: 0), .fallThrough)
    }

    func testDoesNothingWhenDisabledOrForTheBarItself() {
        XCTAssertEqual(action("com.apple.finder", enabled: false), .fallThrough)
        XCTAssertEqual(action("com.brave.Browser", enabled: false, windows: 3), .fallThrough)
        XCTAssertEqual(action(own, windows: 3), .fallThrough)
    }

    func testCardsWithoutABundleIdentifierAreIgnored() {
        XCTAssertEqual(action(nil), .fallThrough)
        XCTAssertEqual(action(""), .fallThrough)
    }

    func testSettingDefaultsToOnAndPersists() {
        let suite = "ForkMiddleClickActionsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(store.middleClickActions, ForkDefaults.middleClickActions)

        store.setMiddleClickActions(false)
        XCTAssertFalse(AppSettingsStore(defaults: defaults).middleClickActions)
        store.setMiddleClickActions(true)
        XCTAssertTrue(AppSettingsStore(defaults: defaults).middleClickActions)
    }
}
