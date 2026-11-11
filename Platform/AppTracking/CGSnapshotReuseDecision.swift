import CoreGraphics
import Foundation

/// Reuse gate for the full CG list on the event read path (DOCK_CG_SNAPSHOT_REUSE=0 disables).
///
/// Background: the background task of `scheduleEventRead` used to capture a full `.optionAll` list **every
/// time** (measured ~1.5ms CPU each in a 449-entry environment), and the 0.5s frontmost poll takes this path
/// every tick: in active use 2Hz × 1.5ms is the largest single item left after the idle work. On the vast
/// majority of ticks the full list is bit-identical to the previous one.
///
/// Gate: first capture a cheap on-screen probe (~0.2ms, same criteria as `captureOnScreenWindowIDs`). If all
/// static conditions pass and the probe set equals the probe set of the cached round -> reuse the cached full
/// list; if any fails -> capture a fresh full list and refresh the cache. Tab switch / window close /
/// minimize / Space change / display change all alter the on-screen set, so the probe sees them at once ->
/// fresh capture, bit-identical to the gate being off. The only thing deferred is a "purely off-screen change
/// with no AX / workspace event at all" (events are covered by the global generation), capped by
/// `defaultMaxCacheAge`; the 5s reconcile batch path always captures fresh and never uses this gate.
///
/// Hard ordering rule: **probe first, full capture second**. The other way round the probe is later than the
/// full capture, and a change between the two puts "old full list + new probe" into the cache: the next
/// tick's probe matches and a full list missing the change is reused. With the probe first the same change
/// only costs one more capture on the next tick, the conservative direction.
enum CGSnapshotReuseDecision {
    /// Cache lifetime cap (seconds, monotonic clock). Age is computed at ticket assembly on the main thread,
    /// and the background AX read (≤~0.5s) makes the real age slightly larger than the judged value. The cap
    /// already includes this margin; do not lower it to the same order as the read duration.
    static let defaultMaxCacheAge: TimeInterval = 2.0

    enum FreshReason: Equatable {
        case disabled          // kill switch: not even the probe is captured, bit-for-bit as before the gate
        case noCache
        case cachedCaptureFailed
        case cacheExpired
        case eventSinceCache   // an AX / workspace event since the cached round (global generation changed)
        case absenceClockRunning
        case phantomCandidate
        case observerInactive  // this pid's AXObserver is missing -> events cannot arrive at all, the generation criterion is void
        case probeChanged
    }

    /// Verdict on the static conditions (the part known at ticket assembly on the main thread). The probe
    /// comparison happens in the background task (`probeVerdict`).
    enum PreVerdict: Equatable {
        case captureWithoutProbe          // kill switch path
        case captureAndPrime(FreshReason) // capture a fresh full list and relink the cache chain with the same round's probe
        case probeThenCompare
    }

    struct Input: Equatable {
        let reuseEnabled: Bool
        let hasCache: Bool
        let cachedCaptureFailed: Bool
        let cacheAge: TimeInterval
        let generationMatches: Bool
        let hasAbsenceClock: Bool
        let hasPhantomCandidate: Bool
        let observerActive: Bool
    }

    static func preVerdict(_ input: Input) -> PreVerdict {
        guard input.reuseEnabled else { return .captureWithoutProbe }
        guard input.hasCache else { return .captureAndPrime(.noCache) }
        if input.cachedCaptureFailed { return .captureAndPrime(.cachedCaptureFailed) }
        if input.cacheAge >= defaultMaxCacheAge || input.cacheAge < 0 {
            return .captureAndPrime(.cacheExpired)
        }
        if !input.generationMatches { return .captureAndPrime(.eventSinceCache) }
        if input.hasAbsenceClock { return .captureAndPrime(.absenceClockRunning) }
        if input.hasPhantomCandidate { return .captureAndPrime(.phantomCandidate) }
        if !input.observerActive { return .captureAndPrime(.observerInactive) }
        return .probeThenCompare
    }

    enum ProbeVerdict: Equatable {
        case reuse
        case captureAndPrime(FreshReason)
    }

    /// The probe set is compared only against **the probe set of the cached round**. The probe criteria
    /// (onScreenOnly + excludeDesktopElements, layer-0) differ from those of the on-screen flag in the full
    /// list; never compare it with `snapshot.onScreenWindowIDs`.
    static func probeVerdict(probe: Set<CGWindowID>, cachedProbe: Set<CGWindowID>) -> ProbeVerdict {
        probe == cachedProbe ? .reuse : .captureAndPrime(.probeChanged)
    }
}
