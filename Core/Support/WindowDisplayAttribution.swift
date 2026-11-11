import CoreGraphics
import Foundation

/// Which display a window belongs to (coarse key for multi-display ④, "each display shows only its own
/// windows").
///
/// Pure geometry: the display holding more than half the area; else the largest overlap; no overlap / invalid
/// frame / empty display table -> nil. The criterion reuses `WindowLiftAvoidance.owningContextIndex` (lift
/// avoidance already assigns windows spanning displays by the same area rule). **No fallback to the main
/// display here**: the inventory layer honestly stores "unknown"; falling back to the main display is the job
/// of the taskbar projection layer (`StripDisplayFilter`), otherwise a stale false attribution would stay in
/// the inventory when the main display is unplugged or changed.
enum WindowDisplayAttribution {
    struct Display: Equatable {
        let uuid: String
        /// Quartz global coordinates (top-left origin, anchored on the menu bar display), the same space as
        /// AX `kAXPosition` / CG `kCGWindowBounds`.
        let cgFrame: CGRect
        /// Usable area without the menu bar / system Dock (same space). Cross-display window drags
        /// (`WindowDisplayMove`) place windows by it; attribution still uses `cgFrame`. Omitted = the whole
        /// display.
        let visibleCGFrame: CGRect

        init(uuid: String, cgFrame: CGRect, visibleCGFrame: CGRect? = nil) {
            self.uuid = uuid
            self.cgFrame = cgFrame
            self.visibleCGFrame = visibleCGFrame ?? cgFrame
        }
    }

    struct Table: Equatable {
        let displays: [Display]
        /// The menu bar display (`NSScreen.screens.first`, **not** `NSScreen.main`).
        let primaryUUID: String?

        static let empty = Table(displays: [], primaryUUID: nil)

        var connectedUUIDs: Set<String> { Set(displays.map(\.uuid)) }
    }

    static func displayUUID(for quartzFrame: CGRect?, table: Table) -> String? {
        guard let frame = quartzFrame,
              let index = WindowLiftAvoidance.owningContextIndex(
                  for: frame,
                  screenCGFrames: table.displays.map(\.cgFrame)
              ) else { return nil }
        return table.displays[index].uuid
    }
}
