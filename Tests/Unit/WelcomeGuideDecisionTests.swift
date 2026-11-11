import XCTest
@testable import NitiaDock

/// Criteria for showing the first-run welcome guide.
///
/// What really must be locked here is that **"unreadable" and "read false" are handled separately**: the
/// former is a transient failure, ask again next time; only the latter means "show it". Confusing them goes
/// wrong in different directions at different cost: treating it as "show" nags the user when unreadable,
/// treating it as "mark seen" swallows the guide forever after one CFPreferences hiccup, and the user would
/// never notice the latter.
final class WelcomeGuideDecisionTests: XCTestCase {
    func testPresentsWhenDockIsVisibleAndNothingHasBeenSeen() {
        XCTAssertEqual(
            WelcomeGuideDecision.evaluate(
                hasSeenWelcome: false,
                canWriteDockPreferences: true,
                dockAutohideEnabled: false
            ),
            .present
        )
    }

    func testAlreadySeenNeverPresentsAgain() {
        // Seen is seen; none of the later conditions should overturn it, including the user switching the
        // Dock back to always visible afterwards.
        for dockAutohide in [true, false, nil] as [Bool?] {
            XCTAssertEqual(
                WelcomeGuideDecision.evaluate(
                    hasSeenWelcome: true,
                    canWriteDockPreferences: true,
                    dockAutohideEnabled: dockAutohide
                ),
                .skipAndMarkSeen,
                "dockAutohideEnabled = \(String(describing: dockAutohide))"
            )
        }
    }

    func testDockAlreadyHiddenSkipsAndMarksSeen() {
        // The guide no longer makes sense. Mark it, so the user is not suddenly stopped by a
        // "first-run guide" when deliberately switching the Dock back to always visible some day.
        XCTAssertEqual(
            WelcomeGuideDecision.evaluate(
                hasSeenWelcome: false,
                canWriteDockPreferences: true,
                dockAutohideEnabled: true
            ),
            .skipAndMarkSeen
        )
    }

    func testSandboxedSkipsAndMarksSeen() {
        // The sandbox cannot write Dock preferences; no button is better than one that
        // always fails. Sandboxing is permanent, so drop the guide on this machine outright.
        XCTAssertEqual(
            WelcomeGuideDecision.evaluate(
                hasSeenWelcome: false,
                canWriteDockPreferences: false,
                dockAutohideEnabled: false
            ),
            .skipAndMarkSeen
        )
    }

    /// **This is why the whole type exists.**
    ///
    /// `currentAutohideState()` returning nil means "not read this time", not "the Dock does not auto-hide".
    /// Then it must neither show (no evidence) nor mark seen: that would let one transient read failure
    /// swallow the guide forever.
    func testUnreadableDockStateSkipsWithoutMarking() {
        XCTAssertEqual(
            WelcomeGuideDecision.evaluate(
                hasSeenWelcome: false,
                canWriteDockPreferences: true,
                dockAutohideEnabled: nil
            ),
            .skipWithoutMarking
        )
    }

    /// Unreadable + sandbox: the sandbox rule wins because it is permanent; no point reading in vain on every
    /// launch.
    func testSandboxWinsOverUnreadableState() {
        XCTAssertEqual(
            WelcomeGuideDecision.evaluate(
                hasSeenWelcome: false,
                canWriteDockPreferences: false,
                dockAutohideEnabled: nil
            ),
            .skipAndMarkSeen
        )
    }

    // MARK: - Checkboxes → which keys to write

    /// This step is where the two minimize options are most easily swapped, and tests that only build
    /// `NativeDockRecommendations` cannot catch it, so all four combinations are asserted field by field.
    func testFullSelectionMapsToAllThreeWrites() {
        let recommendations = WelcomeGuideSelection.recommended.recommendations(hideDelay: 999)
        XCTAssertEqual(recommendations.autoHideDelay, 999)
        XCTAssertTrue(recommendations.minimizeEffectScale)
        XCTAssertTrue(recommendations.minimizeIntoAppIcon)
        XCTAssertFalse(recommendations.isEmpty)
    }

    func testHideOnlySelectionLeavesMinimizeKeysUntouched() {
        let recommendations = WelcomeGuideSelection(
            hidesDock: true,
            usesScaleMinimizeEffect: false,
            minimizesIntoAppIcon: false
        ).recommendations(hideDelay: 999)
        XCTAssertEqual(recommendations.autoHideDelay, 999)
        XCTAssertFalse(recommendations.minimizeEffectScale)
        XCTAssertFalse(recommendations.minimizeIntoAppIcon)
    }

    /// Hide unchecked = autohide is **not touched at all** (nil), not "write a default".
    func testMinimizeOnlySelectionCarriesNoAutoHideDelay() {
        let recommendations = WelcomeGuideSelection(
            hidesDock: false,
            usesScaleMinimizeEffect: true,
            minimizesIntoAppIcon: true
        ).recommendations(hideDelay: 999)
        XCTAssertNil(recommendations.autoHideDelay)
        XCTAssertTrue(recommendations.minimizeEffectScale)
        XCTAssertTrue(recommendations.minimizeIntoAppIcon)
    }

    /// The two minimize options are independent, do not swap them.
    func testEachMinimizeOptionMapsToItsOwnField() {
        let scaleOnly = WelcomeGuideSelection(
            hidesDock: false,
            usesScaleMinimizeEffect: true,
            minimizesIntoAppIcon: false
        ).recommendations(hideDelay: 999)
        XCTAssertTrue(scaleOnly.minimizeEffectScale)
        XCTAssertFalse(scaleOnly.minimizeIntoAppIcon)

        let iconOnly = WelcomeGuideSelection(
            hidesDock: false,
            usesScaleMinimizeEffect: false,
            minimizesIntoAppIcon: true
        ).recommendations(hideDelay: 999)
        XCTAssertFalse(iconOnly.minimizeEffectScale)
        XCTAssertTrue(iconOnly.minimizeIntoAppIcon)
    }

    func testEmptySelectionMapsToEmptyRecommendations() {
        let selection = WelcomeGuideSelection(
            hidesDock: false,
            usesScaleMinimizeEffect: false,
            minimizesIntoAppIcon: false
        )
        XCTAssertTrue(selection.isEmpty)
        XCTAssertTrue(selection.recommendations(hideDelay: 999).isEmpty)
    }
}
