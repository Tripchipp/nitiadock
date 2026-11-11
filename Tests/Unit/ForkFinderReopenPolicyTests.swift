import XCTest

/// fork: `ForkFinderReopenPolicy`, the decision to open a window for a Finder started from outside.
final class ForkFinderReopenPolicyTests: XCTestCase {
    func testOpensWhenActiveWindowlessAndNotRightAfterStart() {
        XCTAssertTrue(ForkFinderReopenPolicy.shouldOpenWindow(isActive: true, onScreenWindowCount: 0, secondsSinceAppStart: 60))
    }

    func testDoesNothingWhenFinderIsNotTheActiveApp() {
        XCTAssertFalse(ForkFinderReopenPolicy.shouldOpenWindow(isActive: false, onScreenWindowCount: 0, secondsSinceAppStart: 60))
    }

    func testDoesNothingWhenFinderAlreadyHasAWindow() {
        XCTAssertFalse(ForkFinderReopenPolicy.shouldOpenWindow(isActive: true, onScreenWindowCount: 1, secondsSinceAppStart: 60))
    }

    func testDoesNothingRightAfterNitiaDockStarted() {
        XCTAssertFalse(ForkFinderReopenPolicy.shouldOpenWindow(isActive: true, onScreenWindowCount: 0, secondsSinceAppStart: 3))
    }

    func testCountsOnlyNormalLevelWindowsOfThePid() {
        func info(pid: Int32, layer: Int, width: Double, height: Double) -> [String: Any] {
            [
                kCGWindowOwnerPID as String: pid,
                kCGWindowLayer as String: layer,
                kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": width, "Height": height],
            ]
        }
        let infos = [
            info(pid: 10, layer: 0, width: 800, height: 600),    // Finder window
            info(pid: 10, layer: 0, width: 800, height: 600),    // second Finder window
            info(pid: 10, layer: 25, width: 1440, height: 24),   // menu-bar level
            info(pid: 10, layer: -2147483623, width: 1440, height: 900), // desktop
            info(pid: 10, layer: 0, width: 20, height: 20),      // helper
            info(pid: 11, layer: 0, width: 800, height: 600),    // another app
        ]
        XCTAssertEqual(ForkFinderReopenPolicy.onScreenWindowCount(in: infos, pid: 10), 2)
        XCTAssertEqual(ForkFinderReopenPolicy.onScreenWindowCount(in: [], pid: 10), 0)
    }
}
