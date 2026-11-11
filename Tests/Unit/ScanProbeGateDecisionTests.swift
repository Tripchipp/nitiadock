import CoreGraphics
import XCTest

/// Rescan probe gate decision matrix: three forced-probe fallbacks, two skip criteria, every memory
/// invalidation path.
final class ScanProbeGateDecisionTests: XCTestCase {
    private let identity = ScanAdmissionDecision.ProcessIdentity(
        pid: 4242, startTimeSec: 1, startTimeUsec: 2, bundleID: "com.example.fixture"
    )

    private func conclusiveMemo(cgIDs: Set<CGWindowID> = [77]) -> ScanProbeGateDecision.Memo {
        ScanProbeGateDecision.Memo(identity: identity, lastCGIDs: cgIDs, verdictWasNoEligible: true)
    }

    private func input(
        captureFailed: Bool = false,
        cgWindowIDs: Set<CGWindowID> = [77],
        memo: ScanProbeGateDecision.Memo?,
        workspaceDirty: Bool = false,
        slowFullScanDue: Bool = false
    ) -> ScanProbeGateDecision.Input {
        ScanProbeGateDecision.Input(
            captureFailed: captureFailed,
            cgWindowIDs: cgWindowIDs,
            memo: memo,
            currentIdentity: identity,
            workspaceDirty: workspaceDirty,
            slowFullScanDue: slowFullScanDue
        )
    }

    func testCaptureFailureAlwaysProbes() {
        // CG failure and an empty set are indistinguishable (hard constraint): must probe even with
        // intact memory.
        XCTAssertEqual(
            ScanProbeGateDecision.verdict(input(captureFailed: true, cgWindowIDs: [], memo: conclusiveMemo())),
            .probe(.captureFailed)
        )
    }

    func testSlowFullScanBypassesEverySkip() {
        XCTAssertEqual(
            ScanProbeGateDecision.verdict(input(cgWindowIDs: [], memo: conclusiveMemo(), slowFullScanDue: true)),
            .probe(.fullScanDue)
        )
    }

    func testWorkspaceDirtyBypassesEverySkip() {
        XCTAssertEqual(
            ScanProbeGateDecision.verdict(input(cgWindowIDs: [], memo: conclusiveMemo(), workspaceDirty: true)),
            .probe(.workspaceDirty)
        )
    }

    func testNoCGWindowsSkipsWithoutMemo() {
        // Not a single window in the full CG table (including minimized/hidden/other Spaces) → nothing to
        // admit.
        XCTAssertEqual(
            ScanProbeGateDecision.verdict(input(cgWindowIDs: [], memo: nil)),
            .skipNoCGWindows
        )
    }

    func testNoMemoProbes() {
        XCTAssertEqual(
            ScanProbeGateDecision.verdict(input(memo: nil)),
            .probe(.noMemo)
        )
    }

    func testIdentityChangeInvalidatesMemo() {
        // pid reuse: memory with a mismatched generation must be discarded.
        var stale = conclusiveMemo()
        stale.identity = ScanAdmissionDecision.ProcessIdentity(
            pid: 4242, startTimeSec: 9, startTimeUsec: 9, bundleID: "com.example.fixture"
        )
        XCTAssertEqual(
            ScanProbeGateDecision.verdict(input(memo: stale)),
            .probe(.identityChanged)
        )
    }

    func testCGSetChangeInvalidatesMemo() {
        XCTAssertEqual(
            ScanProbeGateDecision.verdict(input(cgWindowIDs: [77, 78], memo: conclusiveMemo(cgIDs: [77]))),
            .probe(.cgSetChanged)
        )
    }

    func testInconclusiveMemoProbes() {
        // Defensive branch: memory should hold only noEligible outcomes; if another outcome gets in,
        // re-probe.
        var memo = conclusiveMemo()
        memo.verdictWasNoEligible = false
        XCTAssertEqual(
            ScanProbeGateDecision.verdict(input(memo: memo)),
            .probe(.memoNotConclusive)
        )
    }

    func testIntactConclusiveMemoSkips() {
        XCTAssertEqual(
            ScanProbeGateDecision.verdict(input(memo: conclusiveMemo())),
            .skipMemoized
        )
    }
}
