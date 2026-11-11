import XCTest

final class WindowDisplayTitleTests: XCTestCase {
    func testNonemptyTitleIsReturnedUnchanged() {
        XCTAssertEqual(
            WindowDisplayTitle.resolve(rawTitle: "  System Settings  ", fallbackName: "Fallback"),
            "  System Settings  "
        )
    }

    func testMissingOrBlankTitleUsesFallbackName() {
        for title in [nil, "", " \n\t"] as [String?] {
            XCTAssertEqual(
                WindowDisplayTitle.resolve(rawTitle: title, fallbackName: "System Settings"),
                "System Settings"
            )
        }
    }

    func testMissingBundleIdentifierCanUseAppIDAsFallbackName() {
        let appID = "pid-456"

        XCTAssertEqual(
            WindowDisplayTitle.resolve(rawTitle: nil, fallbackName: appID),
            appID
        )
    }


    // MARK: - trimmingAppNameSuffix (issue #41)

    func testTrailingAppNameSuffixIsRemoved() {
        XCTAssertEqual(
            WindowDisplayTitle.trimmingAppNameSuffix("local-dc02 - Google Chrome", appName: "Google Chrome"),
            "local-dc02"
        )
    }

    func testDashVariantsAreRecognized() {
        for separator in [" - ", " — ", " – ", " | ", " · ", "-"] {
            XCTAssertEqual(
                WindowDisplayTitle.trimmingAppNameSuffix("Cursor\(separator)Google Chrome", appName: "Google Chrome"),
                "Cursor",
                "separator '\(separator)' was not recognized"
            )
        }
    }

    func testOnlyTheLastSeparatorIsConsumed() {
        XCTAssertEqual(
            WindowDisplayTitle.trimmingAppNameSuffix("README - macos-dock - Visual Studio Code",
                                                     appName: "Visual Studio Code"),
            "README - macos-dock"
        )
    }

    func testTitleWithoutTheAppNameIsUnchanged() {
        XCTAssertEqual(
            WindowDisplayTitle.trimmingAppNameSuffix("local-dc02", appName: "Google Chrome"),
            "local-dc02"
        )
    }

    func testTitleEqualToTheAppNameIsKept() {
        XCTAssertEqual(
            WindowDisplayTitle.trimmingAppNameSuffix("Google Chrome", appName: "Google Chrome"),
            "Google Chrome"
        )
    }

    /// If only separators / whitespace would remain it must be kept as is, otherwise a window card with no
    /// label appears.
    func testTitleThatWouldBecomeEmptyIsKept() {
        for title in ["- Google Chrome", " - Google Chrome", "— Google Chrome"] {
            XCTAssertEqual(
                WindowDisplayTitle.trimmingAppNameSuffix(title, appName: "Google Chrome"),
                title
            )
        }
    }

    func testAppNameInTheMiddleIsNotTouched() {
        XCTAssertEqual(
            WindowDisplayTitle.trimmingAppNameSuffix("Google Chrome 更新说明", appName: "Google Chrome"),
            "Google Chrome 更新说明"
        )
    }

    /// v1 only handles suffix repetition; apps with the name at the start are returned unchanged (extend when
    /// needed).
    func testLeadingAppNameIsOutOfScopeForNow() {
        XCTAssertEqual(
            WindowDisplayTitle.trimmingAppNameSuffix("Safari — 起始页", appName: "Safari"),
            "Safari — 起始页"
        )
    }

    func testBlankAppNameIsIgnored() {
        XCTAssertEqual(
            WindowDisplayTitle.trimmingAppNameSuffix("local-dc02 - Google Chrome", appName: "   "),
            "local-dc02 - Google Chrome"
        )
    }
}
