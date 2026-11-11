import XCTest

/// fork: `ForkOwnWindowPolicy`, window actions on the app's own windows stay off the AX executor.
final class ForkOwnWindowPolicyTests: XCTestCase {
    private func handles(_ kind: PlatformActionRequest.ActionKind, window: Int32 = 100, own: Int32 = 100,
                         appLevel: Bool = false) -> Bool {
        ForkOwnWindowPolicy.handlesNatively(kind: kind, windowPID: window, ownPID: own, isAppLevelFallback: appLevel)
    }

    func testOwnWindowRaiseMinimizeAndCloseAreHandledNatively() {
        XCTAssertTrue(handles(.activateWindow))
        XCTAssertTrue(handles(.minimizeWindow))
        XCTAssertTrue(handles(.closeWindow))
    }

    func testOtherAppsWindowsStayOnTheAXExecutor() {
        XCTAssertFalse(handles(.activateWindow, window: 200))
        XCTAssertFalse(handles(.minimizeWindow, window: 200))
        XCTAssertFalse(handles(.closeWindow, window: 200))
    }

    func testAppLevelActionsKeepTheirExistingPaths() {
        XCTAssertFalse(handles(.hideApp))
        XCTAssertFalse(handles(.quitApp))
        XCTAssertFalse(handles(.newWindow))
        XCTAssertFalse(handles(.activateWindow, appLevel: true))
    }
}
