import XCTest

final class HoverPollThrottleTests: XCTestCase {
    func testFirstEventRunsImmediately() {
        var t = HoverPollThrottle(minInterval: 1.0 / 30.0)
        XCTAssertEqual(t.eventArrived(now: 100), .run)
    }

    func testEventInsideWindowSchedulesOneTrailing() {
        var t = HoverPollThrottle(minInterval: 0.033)
        _ = t.eventArrived(now: 100)
        guard case .scheduleTrailing(let after) = t.eventArrived(now: 100.010) else {
            return XCTFail("should schedule a trailing call")
        }
        XCTAssertEqual(after, 0.023, accuracy: 0.0001)
        // Trailing call scheduled; later events inside the window are all dropped.
        XCTAssertEqual(t.eventArrived(now: 100.015), .drop)
        XCTAssertEqual(t.eventArrived(now: 100.020), .drop)
    }

    func testTrailingFiredResetsWindowFromFireTime() {
        var t = HoverPollThrottle(minInterval: 0.033)
        _ = t.eventArrived(now: 100)
        _ = t.eventArrived(now: 100.010)
        t.trailingFired(now: 100.033)
        // A new window after the trailing call: an immediate event is still throttled, and passes once the
        // window elapses.
        XCTAssertNotEqual(t.eventArrived(now: 100.040), .run)
        XCTAssertEqual(t.eventArrived(now: 100.070), .run)
    }

    func testQuietGapRunsImmediately() {
        var t = HoverPollThrottle(minInterval: 0.033)
        _ = t.eventArrived(now: 100)
        XCTAssertEqual(t.eventArrived(now: 105), .run)
    }

    func testResetClearsPendingTrailing() {
        var t = HoverPollThrottle(minInterval: 0.033)
        _ = t.eventArrived(now: 100)
        _ = t.eventArrived(now: 100.010)   // trailing scheduled
        t.reset()
        XCTAssertEqual(t.eventArrived(now: 100.011), .run)
    }
}
