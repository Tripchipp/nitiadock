import CoreGraphics
import Foundation

/// Landing routing for external files dragged onto the taskbar (pure function, unit tested).
///
/// All input coordinates are in the `"strip"` space: `onDrop` must be attached to **the same view
/// layer that defines that coordinate space** (settled in review: the DropDelegate location and
/// `geo.frame(in: .named("strip"))` must share a source, never attach it to a layer inside or
/// outside `.padding(shadowPadding)`). Horizontal routing only: anywhere over the taskbar counts
/// as a valid height, and vertical hits are guaranteed by the layer onDrop is attached to.
enum StripDropRouting {
    /// Baseline for the medium tier. When the taskbar is scaled, callers pass `defaultHeadSlack * scale`.
    static let defaultHeadSlack: CGFloat = 8

    enum Target: Equatable {
        /// Dropped on the shelf -> stage (any file/folder, a reference, nothing is moved).
        case stash
        case trash
        /// Dropped on a pinned folder chip -> move the sources into that folder.
        case moveInto(path: String)
        /// Dropped in the folder zone -> pin the directory at display
        /// index `index` (directories only, filtered by the caller).
        case pin(insertIndex: Int)
        /// An app bundle is being dragged -> check "Keep in Dock" + land at the cursor position.
        /// **The whole bar is its landing**, with no index: the insertion slot in the live zone is
        /// computed by `StripBlockLanding` from `chipFrames` (see `handleExternalApplicationDrop`).
        case keepApp
        /// Anywhere else -> reject.
        case none
    }

    /// - Parameters:
    ///   - location: Drop location ("strip" space).
    ///   - isApplicationDrag: Whether an app bundle is being dragged. **No default value**: omitting
    ///     it would silently compile into "apps take the file branch", which is exactly why this
    ///     parameter exists: an `.app` is a directory in the file system, and `.moveInto` is a real
    ///     file move/cross-volume copy that would move the user's app out of Applications.
    ///     It is a pure function argument rather than a disk
    ///     read here so this safety boundary can be unit tested.
    ///   - isTrashItemDrag: every dragged URL is inside a Trash (`TrashPath`). **No default**, for
    ///     the same reason as `isApplicationDrag`: an omission would compile into "stash a reference
    ///     into the Trash" or "move a Trash item with our own file access". Checked before the app gate.
    ///   - shelfFrame: Shelf frame (reported by its own PreferenceKey, **not mixed into folderFrames**).
    ///     **nil = the user turned the shelf off**. Callers must pass `showShelf ? frame : nil`
    ///     straight from the setting, not wait for the PreferenceKey to clear the old frame:
    ///     `ShelfFramePreferenceKey.reduce` deliberately ignores `.zero`, so the old frame stays,
    ///     and a drop at the old position after turning it off would still be misjudged as `.stash`.
    ///   - folderFrames: Folder chip frames (key = StripEntry id, i.e. "folder-<path>").
    ///   - orderedPaths: Current display order of pinned folders (PinnedFolderStore.folderPaths).
    ///   - headSlack: Margin **left** of the first folder that still counts as the folder zone. Without
    ///     a shelf it is the only landing for "insert at index 0": the whole first chip is judged
    ///     `.moveInto` first, so without this margin nothing could ever be inserted at the front.
    ///   - tailSlack: Margin right of the last folder that still counts as the folder zone
    ///     (with a shelf and no folders it hangs off the shelf's right side, covering the
    ///     empty-zone case of "dragging a directory in to pin for the first time").
    static func route(location: CGPoint,
                      isApplicationDrag: Bool,
                      isTrashItemDrag: Bool,
                      shelfFrame: CGRect?,
                      trashFrame: CGRect?,
                      folderFrames: [String: CGRect],
                      orderedPaths: [String],
                      headSlack: CGFloat = defaultHeadSlack,
                      tailSlack: CGFloat = 24) -> Target {
        // Trash items are refused everywhere on the bar, the Trash chip and app landing included.
        if isTrashItemDrag { return .none }

        // ⚠️ Safety gate, right after the Trash line: apps always take Keep, never .moveInto / .pin / .stash.
        // The whole taskbar is their landing: the user's intuition is
        // "drag onto the Dock", so a drop on the window zone must count.
        if isApplicationDrag { return .keepApp }

        if let trashFrame, trashFrame != .zero, location.x >= trashFrame.minX { return .trash }

        let frames = orderedPaths.compactMap { folderFrames["folder-" + $0] }

        // Left edge of the zone: with a shelf it is the shelf's left edge (and a drop on
        // it = stage); without one, fall back to the headSlack left of the first folder.
        // With neither -> the pinned zone does not exist at all, reject the whole bar.
        if let shelfFrame {
            guard shelfFrame != .zero else { return .none }   // shelf is on but its frame is not ready (first frame): do not accept
            if location.x < shelfFrame.minX { return .none }
            if location.x <= shelfFrame.maxX { return .stash }
        } else {
            guard let zoneMinX = frames.map(\.minX).min() else { return .none }
            if location.x < zoneMinX - headSlack { return .none }
        }

        // onDrop covers the valid height of the whole taskbar and routing keeps
        // its existing purely horizontal semantics; contains cannot be used, or
        // the padding above and below a chip would unexpectedly fall back to pin.
        if let path = orderedPaths.first(where: { path in
            guard let frame = folderFrames["folder-" + path] else { return false }
            return location.x >= frame.minX && location.x <= frame.maxX
        }) {
            return .moveInto(path: path)
        }

        guard let zoneMaxX = (frames.map(\.maxX).max() ?? shelfFrame?.maxX).map({ $0 + tailSlack }) else {
            return .none
        }
        guard location.x <= zoneMaxX else { return .none }

        // Insertion index = number of folders whose midpoint is left of the
        // drop point (dropped on a chip's left half -> insert before it).
        let index = orderedPaths.filter { path in
            guard let frame = folderFrames["folder-" + path] else { return false }
            return frame.midX < location.x
        }.count
        return .pin(insertIndex: index)
    }
}

/// The gap opened by make-way during hover when an app is dragged onto the bar from Finder.
///
/// **It stores an insertion index, not "left/right of which card"**, and that is load-bearing. Once
/// the gap is inserted, every card to its right shifts right by one card width, and the next
/// `dropUpdated` measures the shifted frames. With the pointer resting in the gap the two neighbors
/// are equidistant, so `StripBlockLanding` wavers between "right of the left neighbor" and "left of
/// the right neighbor". Both **mean the same slot**, but as `(id, after)` tuples they are not
/// equal. Storing the tuple would make the gate let through a stream of "position unchanged yet the
/// whole taskbar recomputed" writes (this repo measured "46 whole-bar recomputes in a 1.2s drag").
/// Folded into an index, the two wordings become one and the gate actually holds.
struct StripDropGhost: Equatable {
    let bundleID: String
    /// Position of the gap in the live zone's display order.
    let insertIndex: Int
}

extension StripDropRouting {
    /// Folds the (anchor card, left/right) of `StripBlockLanding`
    /// into an insertion index (pure function, unit tested).
    /// Anchor not in the current display order (the card just vanished / was filtered
    /// out by a screen change) -> land at the end, never return an out-of-range index.
    static func ghostInsertionIndex(orderedIDs: [String], targetID: String?, after: Bool) -> Int {
        guard let targetID, let index = orderedIDs.firstIndex(of: targetID) else {
            return orderedIDs.count
        }
        return after ? index + 1 : index
    }

    /// Whether the strip answers a drag with the generic operation (no cursor badge) instead of
    /// SwiftUI's `.copy` (the green plus). Wherever NitiaDock moves the file itself: over the Trash,
    /// and over a pinned folder on the same volume as the dragged file (`moveIntoStaysOnVolume`; a
    /// folder on another volume really gets a copy and keeps the plus). `.copy` reads as "a copy
    /// goes in", and `.move` is never an option: it tells the source the item left, and Finder
    /// deletes an app it dragged in. A source that does not offer generic (e.g. ⌥ held) keeps `.copy`.
    static func usesGenericOperation(
        hoveredTarget: Target?,
        proposedIsCopy: Bool,
        sourceAllowsGeneric: Bool,
        moveIntoStaysOnVolume: Bool = false
    ) -> Bool {
        guard proposedIsCopy, sourceAllowsGeneric else { return false }
        switch hoveredTarget {
        case .trash: return true
        case .moveInto: return moveIntoStaysOnVolume
        default: return false
        }
    }
}
