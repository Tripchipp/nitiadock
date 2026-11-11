import XCTest

/// Pure decision layer for rescan admission (ScanAdmissionDecision).
///
/// The core negative case is the first: when the raw AX list is non-empty but no eligible window survives
/// filtering, it must be rejected. The old implementation checked `!snaps.isEmpty` and also adopted apps that
/// had only fake windows; a live AppEntry with zero seats is never deleted, so the taskbar keeps an app-*
/// card that cannot be removed. Filtering must happen inside `prepare` (not as a number passed in by the
/// caller), otherwise the failure mode "production code passes snaps.count by mistake" cannot be tested.
final class ScanAdmissionDecisionTests: XCTestCase {

    /// Fake window: a real AXWindowSnapshot holds a non-optional AXUIElement that unit tests cannot
    /// construct, so the pure decision layer is generic.
    private struct FakeWindow: Equatable {
        let name: String
        let eligible: Bool
    }

    private func isEligible(_ w: FakeWindow) -> Bool { w.eligible }

    private let identityA = ScanAdmissionDecision.ProcessIdentity(
        pid: 4242, startTimeSec: 1_700_000_000, startTimeUsec: 123_456, bundleID: "com.example.app"
    )

    private func verdict(
        _ prepared: ScanAdmissionDecision.Prepared<FakeWindow>,
        probed: ScanAdmissionDecision.ProcessIdentity? = nil,
        current: ScanAdmissionDecision.ProcessIdentity? = nil,
        isRegularNonSelf: Bool = true,
        isTerminated: Bool = false,
        alreadyTracked: Bool = false
    ) -> ScanAdmissionDecision.Verdict {
        ScanAdmissionDecision.verdict(
            prepared,
            probedIdentity: probed ?? identityA,
            currentIdentity: current ?? identityA,
            isRegularNonSelf: isRegularNonSelf,
            isTerminated: isTerminated,
            alreadyTracked: alreadyTracked
        )
    }

    // MARK: - Filter wiring (core)

    /// 3 raw windows, all ineligible → eligible is empty → rejected. This locks exactly the wiring of this
    /// fix.
    func testRawWindowsPresentButNoneEligibleIsRejected() {
        let raw = [
            FakeWindow(name: "transparent panel", eligible: false),
            FakeWindow(name: "extension window", eligible: false),
            FakeWindow(name: "system internal", eligible: false)
        ]
        let prepared = ScanAdmissionDecision.prepare(rawWindows: raw, isEligible: isEligible)

        XCTAssertEqual(prepared.rawCount, 3)
        XCTAssertTrue(prepared.eligible.isEmpty)
        XCTAssertFalse(prepared.readFailed)
        XCTAssertEqual(verdict(prepared), .skipNoEligible)
    }

    /// Mixed set: what is carried out must be the one filtered window itself, not the raw array.
    func testMixedWindowsCarryOnlyEligibleOnes() {
        let keeper = FakeWindow(name: "real window", eligible: true)
        let raw = [FakeWindow(name: "fake window", eligible: false), keeper, FakeWindow(name: "fake window 2", eligible: false)]
        let prepared = ScanAdmissionDecision.prepare(rawWindows: raw, isEligible: isEligible)

        XCTAssertEqual(prepared.rawCount, 3)
        XCTAssertEqual(prepared.eligible, [keeper])
        XCTAssertEqual(verdict(prepared), .admit)
    }

    /// An AX read failure (.unread) and "read 0 windows" are different things, each with its own outcome.
    func testUnreadIsDistinctFromEmpty() {
        let unread = ScanAdmissionDecision.prepare(rawWindows: nil, isEligible: isEligible)
        XCTAssertTrue(unread.readFailed)
        XCTAssertEqual(unread.rawCount, 0)
        XCTAssertEqual(verdict(unread), .skipUnread)

        let empty = ScanAdmissionDecision.prepare(rawWindows: [FakeWindow](), isEligible: isEligible)
        XCTAssertFalse(empty.readFailed)
        XCTAssertEqual(verdict(empty), .skipNoEligible)
    }

    // MARK: - Process generation (pid reuse)

    private func eligiblePrepared() -> ScanAdmissionDecision.Prepared<FakeWindow> {
        ScanAdmissionDecision.prepare(
            rawWindows: [FakeWindow(name: "real window", eligible: true)],
            isEligible: isEligible
        )
    }

    func testSameIdentityAdmits() {
        XCTAssertEqual(verdict(eligiblePrepared(), probed: identityA, current: identityA), .admit)
    }

    func testDifferentPIDIsIdentityMismatch() {
        let other = ScanAdmissionDecision.ProcessIdentity(
            pid: 9999, startTimeSec: identityA.startTimeSec, startTimeUsec: identityA.startTimeUsec,
            bundleID: identityA.bundleID
        )
        XCTAssertEqual(verdict(eligiblePrepared(), probed: identityA, current: other), .skipIdentityMismatch)
    }

    func testDifferentBundleIDIsIdentityMismatch() {
        let other = ScanAdmissionDecision.ProcessIdentity(
            pid: identityA.pid, startTimeSec: identityA.startTimeSec, startTimeUsec: identityA.startTimeUsec,
            bundleID: "com.example.other"
        )
        XCTAssertEqual(verdict(eligiblePrepared(), probed: identityA, current: other), .skipIdentityMismatch)
    }

    /// The real signature of pid reuse: same pid, same bundleID, but a different start time (any difference
    /// in seconds or microseconds counts).
    func testDifferentStartTimeIsIdentityMismatch() {
        let laterSec = ScanAdmissionDecision.ProcessIdentity(
            pid: identityA.pid, startTimeSec: 1_700_000_099, startTimeUsec: identityA.startTimeUsec,
            bundleID: identityA.bundleID
        )
        XCTAssertEqual(verdict(eligiblePrepared(), probed: identityA, current: laterSec), .skipIdentityMismatch)

        let laterUsec = ScanAdmissionDecision.ProcessIdentity(
            pid: identityA.pid, startTimeSec: identityA.startTimeSec, startTimeUsec: 999_999,
            bundleID: identityA.bundleID
        )
        XCTAssertEqual(verdict(eligiblePrepared(), probed: identityA, current: laterUsec), .skipIdentityMismatch)
    }

    /// Start time missing on one side = the process is gone; reject conservatively and wait for the next
    /// rescan.
    func testMissingStartTimeOnOneSideIsIdentityMismatch() {
        let missing = ScanAdmissionDecision.ProcessIdentity(
            pid: identityA.pid, startTimeSec: nil, startTimeUsec: nil, bundleID: identityA.bundleID
        )
        XCTAssertEqual(verdict(eligiblePrepared(), probed: identityA, current: missing), .skipIdentityMismatch)
        XCTAssertEqual(verdict(eligiblePrepared(), probed: missing, current: identityA), .skipIdentityMismatch)
    }

    /// Missing on both sides does not pass either: "neither side knows" is no evidence of the same process.
    func testMissingStartTimeOnBothSidesIsIdentityMismatch() {
        let missing = ScanAdmissionDecision.ProcessIdentity(
            pid: identityA.pid, startTimeSec: nil, startTimeUsec: nil, bundleID: identityA.bundleID
        )
        XCTAssertEqual(verdict(eligiblePrepared(), probed: missing, current: missing), .skipIdentityMismatch)
    }

    // MARK: - Process state (rechecked at callback)

    func testAlreadyTrackedIsRejectedEvenWithEligibleWindows() {
        XCTAssertEqual(verdict(eligiblePrepared(), alreadyTracked: true), .skipAlreadyTracked)
    }

    func testTerminatedIsRejectedEvenWithEligibleWindows() {
        XCTAssertEqual(verdict(eligiblePrepared(), isTerminated: true), .skipTerminated)
    }

    func testNonRegularIsRejectedEvenWithEligibleWindows() {
        XCTAssertEqual(verdict(eligiblePrepared(), isRegularNonSelf: false), .skipNotRegular)
    }
}
