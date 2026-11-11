import XCTest

/// fork: `ForkForeignWindowCollapse`, an app's windows only as cards on their own display's bar.
final class ForkForeignWindowCollapseTests: XCTestCase {
    private typealias Item = ForkForeignWindowCollapse.Item

    private func window(_ bundle: String, on display: String?, exempt: Bool = false) -> Item {
        Item(bundleID: bundle, displayUUID: display, isRealWindow: true, isExempt: exempt)
    }

    /// This bar is display "A"; "B" is another connected display.
    private func outcomes(_ items: [Item]) -> [ForkForeignWindowCollapse.Outcome] {
        ForkForeignWindowCollapse.outcomes(for: items, isLocal: { $0 == "A" })
    }

    func testLocalWindowsStayAndForeignWindowsOfTheSameAppAreDropped() {
        let result = outcomes([window("x.mail", on: "A"), window("x.mail", on: "B"), window("x.mail", on: "A")])
        XCTAssertEqual(result, [.keep, .drop, .keep])
    }

    func testAppWithOnlyForeignWindowsBecomesOneIconAtTheFirstWindow() {
        let result = outcomes([window("x.mail", on: "B"), window("x.mail", on: "B"), window("x.mail", on: "B")])
        XCTAssertEqual(result, [.icon, .drop, .drop])
    }

    func testAppsAreDecidedIndependentlyAndKeepTheirPlaces() {
        let result = outcomes([
            window("x.mail", on: "B"),
            window("x.edit", on: "A"),
            window("x.mail", on: "B"),
            window("x.edit", on: "B"),
        ])
        XCTAssertEqual(result, [.icon, .keep, .drop, .drop])
    }

    func testUnknownDisplayFollowsTheCallersRule() {
        // The caller routes an unknown display to the primary display; here "A" is not primary.
        let result = ForkForeignWindowCollapse.outcomes(
            for: [window("x.mail", on: nil)], isLocal: { $0 != nil && $0 == "A" })
        XCTAssertEqual(result, [.icon])
        let onPrimary = ForkForeignWindowCollapse.outcomes(for: [window("x.mail", on: nil)], isLocal: { _ in true })
        XCTAssertEqual(onPrimary, [.keep])
    }

    func testOtherEntriesAndExemptAppsAreLeftAlone() {
        let folder = Item(bundleID: nil, displayUUID: nil, isRealWindow: false, isExempt: false)
        let appLevel = Item(bundleID: "x.mail", displayUUID: "B", isRealWindow: false, isExempt: false)
        let result = outcomes([folder, appLevel, window("x.chat", on: "B", exempt: true), window("x.mail", on: "B")])
        XCTAssertEqual(result, [.keep, .keep, .keep, .icon])
    }

    func testNothingToCollapseOnASingleDisplayLikeInput() {
        XCTAssertEqual(outcomes([]), [])
        XCTAssertEqual(outcomes([window("x.mail", on: "A"), window("x.edit", on: "A")]), [.keep, .keep])
    }
}
