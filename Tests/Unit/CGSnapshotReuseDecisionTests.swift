import CoreGraphics
import XCTest

/// Pure decision lock for the CG full-table reuse gate: static
/// condition order, probe comparison, kill-switch bypass.
final class CGSnapshotReuseDecisionTests: XCTestCase {
    private func input(
        reuseEnabled: Bool = true,
        hasCache: Bool = true,
        cachedCaptureFailed: Bool = false,
        cacheAge: TimeInterval = 0.5,
        generationMatches: Bool = true,
        hasAbsenceClock: Bool = false,
        hasPhantomCandidate: Bool = false,
        observerActive: Bool = true
    ) -> CGSnapshotReuseDecision.Input {
        CGSnapshotReuseDecision.Input(
            reuseEnabled: reuseEnabled,
            hasCache: hasCache,
            cachedCaptureFailed: cachedCaptureFailed,
            cacheAge: cacheAge,
            generationMatches: generationMatches,
            hasAbsenceClock: hasAbsenceClock,
            hasPhantomCandidate: hasPhantomCandidate,
            observerActive: observerActive
        )
    }

    func testAllConditionsHeldProceedsToProbe() {
        XCTAssertEqual(CGSnapshotReuseDecision.preVerdict(input()), .probeThenCompare)
    }

    func testKillSwitchSkipsProbeEntirely() {
        XCTAssertEqual(
            CGSnapshotReuseDecision.preVerdict(input(reuseEnabled: false)),
            .captureWithoutProbe
        )
    }

    func testNoCacheCapturesAndPrimes() {
        XCTAssertEqual(
            CGSnapshotReuseDecision.preVerdict(input(hasCache: false)),
            .captureAndPrime(.noCache)
        )
    }

    func testFailedCachedCaptureNeverReused() {
        XCTAssertEqual(
            CGSnapshotReuseDecision.preVerdict(input(cachedCaptureFailed: true)),
            .captureAndPrime(.cachedCaptureFailed)
        )
    }

    func testExpiredCacheCaptures() {
        XCTAssertEqual(
            CGSnapshotReuseDecision.preVerdict(
                input(cacheAge: CGSnapshotReuseDecision.defaultMaxCacheAge)
            ),
            .captureAndPrime(.cacheExpired)
        )
    }

    func testNegativeAgeIsExpiredNotEternal() {
        // A monotonic clock anomaly (e.g. an injected test clock going
        // backwards) is treated as expired; it must not widen the reuse window.
        XCTAssertEqual(
            CGSnapshotReuseDecision.preVerdict(input(cacheAge: -1)),
            .captureAndPrime(.cacheExpired)
        )
    }

    func testEventGenerationMismatchCaptures() {
        XCTAssertEqual(
            CGSnapshotReuseDecision.preVerdict(input(generationMatches: false)),
            .captureAndPrime(.eventSinceCache)
        )
    }

    func testAbsenceClockForcesCapture() {
        XCTAssertEqual(
            CGSnapshotReuseDecision.preVerdict(input(hasAbsenceClock: true)),
            .captureAndPrime(.absenceClockRunning)
        )
    }

    func testPhantomCandidateForcesCapture() {
        XCTAssertEqual(
            CGSnapshotReuseDecision.preVerdict(input(hasPhantomCandidate: true)),
            .captureAndPrime(.phantomCandidate)
        )
    }

    func testInactiveObserverForcesCapture() {
        // Observer gone -> AX events cannot arrive -> the generation criterion is void, must capture fresh.
        XCTAssertEqual(
            CGSnapshotReuseDecision.preVerdict(input(observerActive: false)),
            .captureAndPrime(.observerInactive)
        )
    }

    func testProbeMatchReuses() {
        XCTAssertEqual(
            CGSnapshotReuseDecision.probeVerdict(probe: [1, 2, 3], cachedProbe: [1, 2, 3]),
            .reuse
        )
    }

    func testProbeChangeCaptures() {
        XCTAssertEqual(
            CGSnapshotReuseDecision.probeVerdict(probe: [1, 2], cachedProbe: [1, 2, 3]),
            .captureAndPrime(.probeChanged)
        )
        XCTAssertEqual(
            CGSnapshotReuseDecision.probeVerdict(probe: [1, 2, 4], cachedProbe: [1, 2, 3]),
            .captureAndPrime(.probeChanged)
        )
    }
}
