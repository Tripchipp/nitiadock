import XCTest

/// fork: `ForkSettingsDockPolicy`, the Settings window's presence on the bar.
final class ForkSettingsDockPolicyTests: XCTestCase {
    func testSwitchesToRegularOnlyFromAccessory() {
        XCTAssertTrue(ForkSettingsDockPolicy.shouldSwitchToRegular(isAccessory: true))
        XCTAssertFalse(ForkSettingsDockPolicy.shouldSwitchToRegular(isAccessory: false))
    }

    func testRestoresAccessoryOnlyWhenWeSwitchedAndTheUserClosedIt() {
        XCTAssertTrue(ForkSettingsDockPolicy.shouldRestoreAccessory(switchedByUs: true, isRegular: true, closedFromOutside: false))
        XCTAssertFalse(ForkSettingsDockPolicy.shouldRestoreAccessory(switchedByUs: false, isRegular: true, closedFromOutside: false))
        XCTAssertFalse(ForkSettingsDockPolicy.shouldRestoreAccessory(switchedByUs: true, isRegular: false, closedFromOutside: false))
    }

    func testClosingFromOutsideLeavesThePolicyToThePermissionMachine() {
        XCTAssertFalse(ForkSettingsDockPolicy.shouldRestoreAccessory(switchedByUs: true, isRegular: true, closedFromOutside: true))
    }

    /// NitiaDock's own bundle id must not be filtered out of the window tracker, or the Settings
    /// card could never appear. The upstream constant is another app's id; this pins that.
    func testTrackerSelfFilterDoesNotMatchTheForksBundleId() {
        XCTAssertNotEqual(DockWindowEligibilityPolicy.selfBundleIdentifier, "no.thilip.nitiadock")
    }
}
