import XCTest
@testable import NitiaDock

final class MessagingZoneAdmissionTests: XCTestCase {

    /// Maps an "app name" table to the exact-equality semantics of `titleMatchesAppName`.
    private func matcher(_ names: [String: String]) -> (String, String) -> Bool {
        { title, bundleID in
            guard let name = names[bundleID] else { return false }
            return title.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func win(_ bundleID: String, _ title: String, fallback: Bool = false) -> MessagingZoneAdmission.WindowFact {
        .init(bundleID: bundleID, title: title, isAppLevelFallback: fallback)
    }

    // MARK: - Apps with a recognizable main window enter the admission set

    func testTitleMatchingWindowQualifiesItsApp() {
        let ids = MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
            windows: [win("com.tencent.xinWeChat", "微信")],
            titleMatchesAppName: matcher(["com.tencent.xinWeChat": "微信"])
        )
        XCTAssertEqual(ids, ["com.tencent.xinWeChat"])
    }

    func testAppWithBothMainAndOtherWindowsStillQualifies() {
        // WeChat main window + a "Notes" window together: the main window is the hit.
        let ids = MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
            windows: [win("com.tencent.xinWeChat", "笔记"),
                      win("com.tencent.xinWeChat", "微信")],
            titleMatchesAppName: matcher(["com.tencent.xinWeChat": "微信"])
        )
        XCTAssertEqual(ids, ["com.tencent.xinWeChat"])
    }

    // MARK: - Unrecognizable ones are kept out (the core of this fix)

    func testCatalystStyleNumericTitleNeverQualifies() {
        // Apple Messages: the title is a UIScene session number, never equal to the app name.
        let ids = MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
            windows: [win("com.apple.MobileSMS", "10691420171100425")],
            titleMatchesAppName: matcher(["com.apple.MobileSMS": "信息"])
        )
        XCTAssertTrue(ids.isEmpty, "an app whose main window cannot be recognized must not enter the messaging zone")
    }

    func testTerminalWithCommandTitleNeverQualifies() {
        // Ghostty: misjudged as messaging-like by its social category, but its window titles are command
        // names.
        let ids = MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
            windows: [win("com.mitchellh.ghostty", "dev@mac: ~/Projects")],
            titleMatchesAppName: matcher(["com.mitchellh.ghostty": "Ghostty"])
        )
        XCTAssertTrue(ids.isEmpty)
    }

    func testWeChatWithOnlyNonMainWindowDoesNotQualifyThisRound() {
        // Main window closed, only "Notes" left: unrecognizable right now. The caller avoids flapping via
        // "one pass puts it on the list for good"; this decision only reports the present truthfully.
        let ids = MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
            windows: [win("com.tencent.xinWeChat", "笔记")],
            titleMatchesAppName: matcher(["com.tencent.xinWeChat": "微信"])
        )
        XCTAssertTrue(ids.isEmpty)
    }

    // MARK: - Edge cases

    func testAppLevelFallbackCannotProveIdentifiability() {
        // An app-* fallback entry is not a real window; it does not count even if its title happens to equal
        // the app name.
        let ids = MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
            windows: [win("com.tencent.xinWeChat", "微信", fallback: true)],
            titleMatchesAppName: matcher(["com.tencent.xinWeChat": "微信"])
        )
        XCTAssertTrue(ids.isEmpty)
    }

    func testEmptyBundleIDIgnored() {
        let ids = MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
            windows: [win("", "微信")],
            titleMatchesAppName: { _, _ in true }
        )
        XCTAssertTrue(ids.isEmpty)
    }

    func testMultipleAppsResolveIndependently() {
        let ids = MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
            windows: [win("com.tencent.qq", "QQ"),
                      win("com.apple.MobileSMS", "10691420171100425"),
                      win("com.tencent.xinWeChat", "微信")],
            titleMatchesAppName: matcher(["com.tencent.qq": "QQ",
                                          "com.apple.MobileSMS": "信息",
                                          "com.tencent.xinWeChat": "微信"])
        )
        XCTAssertEqual(ids, ["com.tencent.qq", "com.tencent.xinWeChat"])
    }

    func testNoWindowsYieldsEmpty() {
        XCTAssertTrue(MessagingZoneAdmission.mainWindowIdentifiableBundleIDs(
            windows: [], titleMatchesAppName: { _, _ in true }
        ).isEmpty)
    }
}
