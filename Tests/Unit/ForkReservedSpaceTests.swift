import CoreGraphics
import XCTest

/// fork: "Reserve screen space for the taskbar", pure geometry and the two-strike ledger.
final class ForkReservedSpaceTests: XCTestCase {
    // A 1512x982 screen with a 33pt menu bar, a hidden Dock, and a bar whose top is at 62
    // (8pt margin + 54pt bar). The band therefore ends at 64 (2pt clearance).
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let visible = CGRect(x: 0, y: 0, width: 1512, height: 949)
    private let barTop: CGFloat = 62
    private var bandTop: CGFloat { barTop + ForkReservedSpace.clearance }

    private func decide(_ window: CGRect, barTop: CGFloat? = nil, visible: CGRect? = nil) -> ForkReservedSpace.Decision {
        ForkReservedSpace.decision(window: window, screenFrame: screen, visibleFrame: visible ?? self.visible,
                                   barTop: barTop ?? self.barTop)
    }

    // MARK: Geometry

    func testWindowAboveTheBandIsLeftAlone() {
        XCTAssertEqual(decide(CGRect(x: 100, y: 64, width: 800, height: 600)), .clear)
        XCTAssertEqual(decide(CGRect(x: 100, y: 300, width: 800, height: 600)), .clear)
        // Within rounding of the band's top still counts as clear.
        XCTAssertEqual(decide(CGRect(x: 100, y: 63.5, width: 800, height: 600)), .clear)
    }

    func testWindowDippingIntoTheBandMovesUpWithoutChangingSize() {
        let window = CGRect(x: 100, y: 10, width: 800, height: 600)
        XCTAssertEqual(decide(window), .move(to: CGRect(x: 100, y: 64, width: 800, height: 600)))
    }

    func testTheBandSpansTheFullScreenWidth() {
        // Far left corner, nowhere near a centred bar: still reserved space.
        let window = CGRect(x: 0, y: 0, width: 300, height: 200)
        XCTAssertEqual(decide(window), .move(to: CGRect(x: 0, y: 64, width: 300, height: 200)))
    }

    func testWindowThatExactlyFitsMovesRatherThanResizes() {
        let room = visible.maxY - bandTop
        let window = CGRect(x: 50, y: 0, width: 700, height: room)
        XCTAssertEqual(decide(window), .move(to: CGRect(x: 50, y: bandTop, width: 700, height: room)))
    }

    func testWindowTooTallToFitIsShrunkWithItsTopUnderTheMenuBar() throws {
        let window = CGRect(x: 50, y: 20, width: 700, height: 929)   // top already at the menu bar
        let target = try XCTUnwrap(decide(window).target)
        XCTAssertEqual(decide(window), .resize(to: target))
        XCTAssertEqual(target.maxY, visible.maxY)
        XCTAssertEqual(target.minY, bandTop)
        XCTAssertEqual(target.minX, window.minX)
        XCTAssertEqual(target.width, window.width)
    }

    func testTargetsNeverLeaveTheVisibleArea() {
        for height in stride(from: CGFloat(120), through: 1000, by: 55) {
            for y in stride(from: CGFloat(-40), through: 60, by: 20) {
                guard let target = decide(CGRect(x: 10, y: y, width: 500, height: height)).target else { continue }
                XCTAssertGreaterThanOrEqual(target.minY, bandTop)
                XCTAssertLessThanOrEqual(target.maxY, visible.maxY + ForkReservedSpace.tolerance)
                XCTAssertLessThanOrEqual(target.height, height + ForkReservedSpace.tolerance, "never grows a window")
            }
        }
    }

    func testBottomMarginRaisesTheBand() {
        // 60pt margin + 54pt bar.
        let window = CGRect(x: 100, y: 80, width: 800, height: 500)
        XCTAssertEqual(decide(window), .clear)
        XCTAssertEqual(decide(window, barTop: 114), .move(to: CGRect(x: 100, y: 116, width: 800, height: 500)))
    }

    func testAVisibleDockThatReservesMoreWins() {
        let dockVisible = CGRect(x: 0, y: 90, width: 1512, height: 859)
        let window = CGRect(x: 100, y: 70, width: 800, height: 500)
        XCTAssertEqual(decide(window, visible: dockVisible), .move(to: CGRect(x: 100, y: 90, width: 800, height: 500)))
    }

    func testWindowMostlyOnAnotherDisplayIsNotThisScreensBusiness() {
        let window = CGRect(x: 1400, y: 0, width: 800, height: 600)   // 112 of 800pt wide on this screen
        XCTAssertEqual(decide(window), .skip(.notOnThisScreen))
    }

    func testWindowCoveringTheWholeScreenIsSkipped() {
        XCTAssertEqual(decide(screen), .skip(.coversScreen))
    }

    func testNoRoomMeansNoAction() {
        let cramped = CGRect(x: 0, y: 0, width: 1512, height: 200)
        XCTAssertEqual(decide(CGRect(x: 0, y: 0, width: 500, height: 150), visible: cramped), .skip(.noRoom))
    }

    func testGarbageGeometryIsSkipped() {
        XCTAssertEqual(decide(CGRect(x: 0, y: 0, width: 0, height: 100)), .skip(.invalidGeometry))
        XCTAssertEqual(decide(CGRect(x: 0, y: 0, width: 100, height: 100), barTop: .nan), .skip(.invalidGeometry))
    }

    func testAMaximizedWindowGetsTheSameBottomEdgeUpstreamsLiftGivesIt() throws {
        let geometry = WindowLiftAvoidance.Geometry(screenFrame: screen, visibleFrame: visible, taskbarTop: barTop)
        let lifted = try XCTUnwrap(geometry.adjustedFrame(for: visible))
        let target = try XCTUnwrap(decide(visible).target)
        XCTAssertEqual(target, lifted, "the two features must agree, or they would take turns moving the window")
        XCTAssertEqual(decide(lifted), .clear, "and a window upstream already lifted needs nothing from us")
    }

    // MARK: Ledger

    private let key = WindowLiftAvoidance.WindowKey(pid: 42, cgWindowID: 7)

    func testFirstEncounterActs() {
        var ledger = ForkReservedSpace.Ledger()
        XCTAssertTrue(ledger.shouldAct(on: key, now: 100))
    }

    func testAnAppThatPutsTheWindowBackTwiceWins() {
        var ledger = ForkReservedSpace.Ledger()
        XCTAssertTrue(ledger.shouldAct(on: key, now: 100))
        ledger.recordAction(on: key, now: 100, cleared: true)
        XCTAssertTrue(ledger.shouldAct(on: key, now: 101), "back in the band 1s later: strike one, act once more")
        ledger.recordAction(on: key, now: 101, cleared: true)
        XCTAssertFalse(ledger.shouldAct(on: key, now: 102), "and again: strike two, leave it alone")
        XCTAssertTrue(ledger.hasGivenUp(on: key))
        XCTAssertFalse(ledger.shouldAct(on: key, now: 5000), "giving up is permanent for this window")
    }

    func testAClampedWindowIsOnlyWrittenOnce() {
        var ledger = ForkReservedSpace.Ledger()
        XCTAssertTrue(ledger.shouldAct(on: key, now: 100))
        ledger.recordAction(on: key, now: 100, cleared: false)
        // Our own write fires a geometry event; the window is still in the band.
        XCTAssertFalse(ledger.shouldAct(on: key, now: 100.3))
    }

    func testStrikesExpireAfterAQuietPeriod() {
        var ledger = ForkReservedSpace.Ledger()
        _ = ledger.shouldAct(on: key, now: 100)
        ledger.recordAction(on: key, now: 100, cleared: true)
        _ = ledger.shouldAct(on: key, now: 101)
        ledger.recordAction(on: key, now: 101, cleared: true)
        // The user drags it down again much later: that is a fresh, single event.
        let later = 101 + ForkReservedSpace.Ledger.fightWindow + 1
        XCTAssertTrue(ledger.shouldAct(on: key, now: later))
        ledger.recordAction(on: key, now: later, cleared: true)
        XCTAssertTrue(ledger.shouldAct(on: key, now: later + 1))
    }

    func testWindowsAreIndependentAndForgottenWithTheirApp() {
        var ledger = ForkReservedSpace.Ledger()
        let other = WindowLiftAvoidance.WindowKey(pid: 43, cgWindowID: 9)
        _ = ledger.shouldAct(on: key, now: 100)
        ledger.recordAction(on: key, now: 100, cleared: false)
        _ = ledger.shouldAct(on: key, now: 100.2)
        XCTAssertTrue(ledger.hasGivenUp(on: key))
        XCTAssertTrue(ledger.shouldAct(on: other, now: 100.3))

        ledger.forget(pid: 42)
        XCTAssertFalse(ledger.hasGivenUp(on: key))
        ledger.recordAction(on: other, now: 100.3, cleared: true)
        ledger.reset()
        XCTAssertEqual(ledger, ForkReservedSpace.Ledger())
    }

    // MARK: Setting

    @MainActor
    func testSettingIsOffByDefaultAndPersists() {
        let suiteName = "com.tungsten.edge.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = AppSettingsStore(defaults: defaults)
        XCTAssertFalse(store.reserveScreenSpace, "it moves other apps' windows: never on unless the user chose it")
        XCTAssertNil(defaults.object(forKey: "com.tungsten.edge.reserveScreenSpace"))
        store.setReserveScreenSpace(true)
        XCTAssertTrue(AppSettingsStore(defaults: defaults).reserveScreenSpace)
    }
}
