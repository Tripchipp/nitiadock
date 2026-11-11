import CoreGraphics

/// Landing classification when a pinned folder chip drag is released (pure function, unit tested).
///
/// Coordinates: the caller first converts `DragController.globalLocation`
/// (screen coordinates) with `stripPoint(from:)`
/// into a point in "strip" local coordinates, then passes it to `classify`. `stripVisibleRect` is the visible
/// area of the taskbar content (in "strip" local coordinates simply `(0,0)`-`stripRootScreenRect.size`, which
/// excludes the transparent shadowPadding edge by nature, no extra conversion needed). `folderZoneMaxX` is
/// the right edge of the pinned zone (shelf + folder chips) in the same coordinate system.
/// No buffer on the boundaries: the requirement is that the hit
/// range follows the visible area, with no large buffer zone.
enum FolderChipDropZone: Equatable {
    /// Still inside the pinned zone: the reorder was already
    /// committed live during the drag, release does nothing more.
    case folderZone
    /// Dropped on the taskbar's window zone: unpin + open the folder's
    /// real Finder window (the caller's job, not this type's).
    case liveZone
    /// Dropped outside the taskbar's visible range: remove the pin.
    case outsideStrip

    static func classify(point: CGPoint, stripVisibleRect: CGRect, folderZoneMaxX: CGFloat,
                         trashMinX: CGFloat?) -> FolderChipDropZone {
        guard stripVisibleRect.contains(point) else { return .outsideStrip }
        if let trashMinX, point.x >= trashMinX { return .folderZone }
        return point.x <= folderZoneMaxX ? .folderZone : .liveZone
    }
}

/// Screen-coordinate geometry snapshot for a pinned folder drag.
///
/// The final mouseUp location of `DragController` is in screen coordinates; this wraps the pure
/// conversion so the final landing no longer depends on SwiftUI gesture callbacks. `stripScreenRect`
/// is the screen frame of the taskbar's visible content area, without shadowPadding.
struct FolderChipDropGeometry: Equatable {
    let stripScreenRect: CGRect
    let folderZoneMaxX: CGFloat
    let trashMinX: CGFloat?

    func classify(screenPoint: CGPoint) -> FolderChipDropZone {
        guard stripScreenRect != .zero else { return .outsideStrip }
        let localPoint = CGPoint(
            x: screenPoint.x - stripScreenRect.minX,
            y: stripScreenRect.maxY - screenPoint.y
        )
        return FolderChipDropZone.classify(
            point: localPoint,
            stripVisibleRect: CGRect(origin: .zero, size: stripScreenRect.size),
            folderZoneMaxX: folderZoneMaxX,
            trashMinX: trashMinX
        )
    }
}
