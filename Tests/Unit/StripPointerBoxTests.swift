import XCTest
@testable import NitiaDock

/// Taskbar enter / exit hysteresis box (`StripPointerBox`): both profiles are tested; run this before
/// changing values.
final class StripPointerBoxTests: XCTestCase {
    private let strip = CGRect(x: 100, y: 0, width: 600, height: 54)
    private let reach: CGFloat = 62

    private func box(_ x: CGFloat, _ y: CGFloat, _ profile: StripPointerBox.Profile) -> StripPointerBox {
        StripPointerBox.classify(pointer: CGPoint(x: x, y: y), stripRect: strip, rightReach: reach, profile: profile)
    }

    func testInsideIsEnterAndNotOutInBothProfiles() {
        XCTAssertEqual(box(300, 20, .drawerConversion), StripPointerBox(enter: true, clearlyOut: false))
        XCTAssertEqual(box(300, 20, .stripPresence), StripPointerBox(enter: true, clearlyOut: false))
    }

    /// Drawer conversion profile: above, enter 16 / exit 40, with a hysteresis band between.
    func testDrawerConversionTopBand() {
        XCTAssertTrue(box(300, 54 + 15, .drawerConversion).enter)
        XCTAssertEqual(box(300, 54 + 30, .drawerConversion), StripPointerBox(enter: false, clearlyOut: false))
        XCTAssertTrue(box(300, 54 + 41, .drawerConversion).clearlyOut)
    }

    /// Collapse-on-drag-out profile: above, enter 0 / exit 6. The pointer counts as gone once it leaves the
    /// bar's top, matched to native Dock screen recordings (2026-09-03).
    func testStripPresenceTopBandMatchesTheNativeDock() {
        XCTAssertTrue(box(300, 54, .stripPresence).enter)
        XCTAssertEqual(box(300, 54 + 3, .stripPresence), StripPointerBox(enter: false, clearlyOut: false))
        XCTAssertTrue(box(300, 54 + 7, .stripPresence).clearlyOut)
        XCTAssertFalse(box(300, 54 + 7, .drawerConversion).clearlyOut, "the drawer profile is not out yet at this height")
    }

    /// Below and at the sides the two profiles are identical.
    func testBottomAndSidesAreShared() {
        for profile in [StripPointerBox.Profile.drawerConversion, .stripPresence] {
            XCTAssertEqual(box(300, -16, profile), StripPointerBox(enter: false, clearlyOut: false))
            XCTAssertTrue(box(300, -25, profile).clearlyOut)
            XCTAssertEqual(box(100 - 16, 20, profile), StripPointerBox(enter: false, clearlyOut: false))
            XCTAssertTrue(box(100 - 25, 20, profile).clearlyOut)
        }
    }

    /// The capsule on the right counts as part of the bar: the cursor on it is still enter, and out only
    /// starts 16pt right of the capsule.
    func testCapsuleCountsAsOnTheStrip() {
        for profile in [StripPointerBox.Profile.drawerConversion, .stripPresence] {
            XCTAssertTrue(box(700 + reach - 1, 20, profile).enter)
            XCTAssertEqual(box(700 + reach + 10, 20, profile), StripPointerBox(enter: false, clearlyOut: false))
            XCTAssertTrue(box(700 + reach + 17, 20, profile).clearlyOut)
        }
    }

    func testEnterAndOutAreNeverBothTrue() {
        for profile in [StripPointerBox.Profile.drawerConversion, .stripPresence] {
            for x in stride(from: 0, through: 900, by: 7) {
                for y in stride(from: -60, through: 120, by: 5) {
                    let b = box(CGFloat(x), CGFloat(y), profile)
                    XCTAssertFalse(b.enter && b.clearlyOut, "(\(x), \(y)) \(profile)")
                }
            }
        }
    }
}
