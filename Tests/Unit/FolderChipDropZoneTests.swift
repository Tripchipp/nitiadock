import XCTest

/// Drop-zone classification when a dragged pinned-folder chip is released (FolderChipDropZone.classify).
/// Layout assumed: "strip" local coordinates, visible area 0..400 x 0..92, pinned zone right edge at x=200.
final class FolderChipDropZoneTests: XCTestCase {
    func testTrashIsNoOpButOutsideStripStillWins() {
        let geometry = FolderChipDropGeometry(stripScreenRect: CGRect(x: 100, y: 500, width: 400, height: 92),
                                              folderZoneMaxX: 200, trashMinX: 320)
        XCTAssertEqual(geometry.classify(screenPoint: CGPoint(x: 440, y: 550)), .folderZone)
        XCTAssertEqual(geometry.classify(screenPoint: CGPoint(x: 501, y: 550)), .outsideStrip)
        XCTAssertEqual(geometry.classify(screenPoint: CGPoint(x: 440, y: 600)), .outsideStrip)
        XCTAssertEqual(geometry.classify(screenPoint: CGPoint(x: 400, y: 550)), .liveZone)
    }
    private let stripVisibleRect = CGRect(x: 0, y: 0, width: 400, height: 92)
    private let folderZoneMaxX: CGFloat = 200

    func testPointWithinFolderZoneClassifiesAsFolderZone() {
        let zone = FolderChipDropZone.classify(point: CGPoint(x: 100, y: 40),
                                               stripVisibleRect: stripVisibleRect,
                                               folderZoneMaxX: folderZoneMaxX, trashMinX: nil)
        XCTAssertEqual(zone, .folderZone)
    }

    func testPointRightOfFolderZoneButInsideStripClassifiesAsLiveZone() {
        let zone = FolderChipDropZone.classify(point: CGPoint(x: 300, y: 40),
                                               stripVisibleRect: stripVisibleRect,
                                               folderZoneMaxX: folderZoneMaxX, trashMinX: nil)
        XCTAssertEqual(zone, .liveZone)
    }

    func testPointOutsideStripHorizontallyClassifiesAsOutsideStrip() {
        let left = FolderChipDropZone.classify(point: CGPoint(x: -10, y: 40),
                                               stripVisibleRect: stripVisibleRect,
                                               folderZoneMaxX: folderZoneMaxX, trashMinX: nil)
        let right = FolderChipDropZone.classify(point: CGPoint(x: 410, y: 40),
                                                stripVisibleRect: stripVisibleRect,
                                                folderZoneMaxX: folderZoneMaxX, trashMinX: nil)
        XCTAssertEqual(left, .outsideStrip)
        XCTAssertEqual(right, .outsideStrip)
    }

    func testPointOutsideStripVerticallyClassifiesAsOutsideStrip() {
        let above = FolderChipDropZone.classify(point: CGPoint(x: 100, y: -5),
                                                stripVisibleRect: stripVisibleRect,
                                                folderZoneMaxX: folderZoneMaxX, trashMinX: nil)
        let below = FolderChipDropZone.classify(point: CGPoint(x: 100, y: 100),
                                                stripVisibleRect: stripVisibleRect,
                                                folderZoneMaxX: folderZoneMaxX, trashMinX: nil)
        XCTAssertEqual(above, .outsideStrip)
        XCTAssertEqual(below, .outsideStrip)
    }

    func testNoBufferJustOutsideStripEdgeIsOutsideStrip() {
        // The hit range follows the visible area with no large buffer: 1pt outside the edge already counts as
        // moved out.
        let zone = FolderChipDropZone.classify(point: CGPoint(x: 400.5, y: 40),
                                               stripVisibleRect: stripVisibleRect,
                                               folderZoneMaxX: folderZoneMaxX, trashMinX: nil)
        XCTAssertEqual(zone, .outsideStrip)
    }

    func testExactlyOnStripEdgeIsStillInside() {
        let zone = FolderChipDropZone.classify(point: CGPoint(x: 399.9, y: 40),
                                               stripVisibleRect: stripVisibleRect,
                                               folderZoneMaxX: folderZoneMaxX, trashMinX: nil)
        XCTAssertEqual(zone, .liveZone)
    }

    func testExactlyAtFolderZoneBoundaryIsFolderZone() {
        let zone = FolderChipDropZone.classify(point: CGPoint(x: 200, y: 40),
                                               stripVisibleRect: stripVisibleRect,
                                               folderZoneMaxX: folderZoneMaxX, trashMinX: nil)
        XCTAssertEqual(zone, .folderZone)
    }

    func testJustPastFolderZoneBoundaryIsLiveZone() {
        let zone = FolderChipDropZone.classify(point: CGPoint(x: 200.1, y: 40),
                                               stripVisibleRect: stripVisibleRect,
                                               folderZoneMaxX: folderZoneMaxX, trashMinX: nil)
        XCTAssertEqual(zone, .liveZone)
    }

    func testScreenPointWithinFolderZoneClassifiesAsFolderZone() {
        let geometry = FolderChipDropGeometry(stripScreenRect: CGRect(x: 100, y: 500, width: 400, height: 92),
                                              folderZoneMaxX: folderZoneMaxX, trashMinX: nil)
        let zone = geometry.classify(screenPoint: CGPoint(x: 250, y: 552))
        XCTAssertEqual(zone, .folderZone)
    }

    func testScreenPointWithinLiveZoneClassifiesAsLiveZone() {
        let geometry = FolderChipDropGeometry(stripScreenRect: CGRect(x: 100, y: 500, width: 400, height: 92),
                                              folderZoneMaxX: folderZoneMaxX, trashMinX: nil)
        let zone = geometry.classify(screenPoint: CGPoint(x: 401, y: 552))
        XCTAssertEqual(zone, .liveZone)
    }

    func testScreenPointJustOutsideStripClassifiesAsOutsideStrip() {
        let geometry = FolderChipDropGeometry(stripScreenRect: CGRect(x: 100, y: 500, width: 400, height: 92),
                                              folderZoneMaxX: folderZoneMaxX, trashMinX: nil)
        let zone = geometry.classify(screenPoint: CGPoint(x: 501, y: 552))
        XCTAssertEqual(zone, .outsideStrip)
    }
}
