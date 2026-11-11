import CoreGraphics
import Foundation

struct AppTrackerCGWindowSnapshot: Equatable {
    let allWindowIDs: Set<CGWindowID>
    let onScreenWindowIDs: Set<CGWindowID>
    /// Layer-0 window ids grouped by owner pid (for the shadow tab pool: CG(pid) − AX-exposed set =
    /// ordered-out background tabs).
    let windowIDsByPID: [pid_t: Set<CGWindowID>]
    /// The AX inventory has no alpha attribute; filled in by CG window id from the same round, for the
    /// alpha=0 filter in admission.
    let alphaByWindowID: [CGWindowID: Double]
    /// `kCGWindowBounds` of layer-0 windows (Quartz global coordinates). The multi-display ④ 5s tick uses it
    /// to recompute "which display" for **all** seats, including pids skipped by the skip gate that got no AX
    /// read. Display attribution only, not a replacement for AX frames.
    let boundsByWindowID: [CGWindowID: CGRect]
    /// The CG query itself failed (returned nil). Not the same as "really no layer-0 windows": any gate that
    /// uses this snapshot as a "nothing changed" criterion (periodic skip, scan gate) must give up skipping
    /// when it sees this flag and take the full path. Existing consumers do not read it; downstream behavior
    /// on failure is bit-for-bit as before.
    let captureFailed: Bool

    init(
        allWindowIDs: Set<CGWindowID>,
        onScreenWindowIDs: Set<CGWindowID>,
        windowIDsByPID: [pid_t: Set<CGWindowID>],
        alphaByWindowID: [CGWindowID: Double],
        boundsByWindowID: [CGWindowID: CGRect] = [:],
        captureFailed: Bool = false
    ) {
        self.allWindowIDs = allWindowIDs
        self.onScreenWindowIDs = onScreenWindowIDs
        self.windowIDsByPID = windowIDsByPID
        self.alphaByWindowID = alphaByWindowID
        self.boundsByWindowID = boundsByWindowID
        self.captureFailed = captureFailed
    }

    static var failed: AppTrackerCGWindowSnapshot {
        AppTrackerCGWindowSnapshot(
            allWindowIDs: [],
            onScreenWindowIDs: [],
            windowIDsByPID: [:],
            alphaByWindowID: [:],
            boundsByWindowID: [:],
            captureFailed: true
        )
    }

    static func capture() -> AppTrackerCGWindowSnapshot {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return .failed
        }
        return parse(windowInfo)
    }

    static func captureOnScreenWindowIDs() -> Set<CGWindowID> {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return layerZeroWindowIDs(in: windowInfo)
    }

    static func parse(_ windowInfo: [[String: Any]]) -> AppTrackerCGWindowSnapshot {
        var allWindowIDs: Set<CGWindowID> = []
        var onScreenWindowIDs: Set<CGWindowID> = []
        var windowIDsByPID: [pid_t: Set<CGWindowID>] = [:]
        var alphaByWindowID: [CGWindowID: Double] = [:]
        var boundsByWindowID: [CGWindowID: CGRect] = [:]

        for info in windowInfo {
            guard let windowID = layerZeroWindowID(in: info) else { continue }
            allWindowIDs.insert(windowID)
            if info[kCGWindowIsOnscreen as String] as? Bool == true {
                onScreenWindowIDs.insert(windowID)
            }
            if let ownerPID = info[kCGWindowOwnerPID as String] as? Int {
                windowIDsByPID[pid_t(ownerPID), default: []].insert(windowID)
            }
            if let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue {
                alphaByWindowID[windowID] = alpha
            }
            if let dict = info[kCGWindowBounds as String] as? NSDictionary,
               let rect = CGRect(dictionaryRepresentation: dict) {
                boundsByWindowID[windowID] = rect
            }
        }

        return AppTrackerCGWindowSnapshot(
            allWindowIDs: allWindowIDs,
            onScreenWindowIDs: onScreenWindowIDs,
            windowIDsByPID: windowIDsByPID,
            alphaByWindowID: alphaByWindowID,
            boundsByWindowID: boundsByWindowID
        )
    }

    private static func layerZeroWindowIDs(in windowInfo: [[String: Any]]) -> Set<CGWindowID> {
        Set(windowInfo.compactMap(layerZeroWindowID(in:)))
    }

    private static func layerZeroWindowID(in info: [String: Any]) -> CGWindowID? {
        guard let layer = info[kCGWindowLayer as String] as? Int,
              layer == 0,
              let number = info[kCGWindowNumber as String] as? Int else {
            return nil
        }
        return CGWindowID(number)
    }
}
