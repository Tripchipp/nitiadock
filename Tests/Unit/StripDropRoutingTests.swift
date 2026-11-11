import XCTest

/// Pure geometric routing for external files dragged onto the taskbar (StripDropRouting.route).
/// Layout assumed: "strip" space, shelf at x=100..144, folder chips 52pt wide with 8pt spacing starting at
/// x=152.
final class StripDropRoutingTests: XCTestCase {
    func testTrashRoutingAndApplicationPriority() {
        let trash = CGRect(x: 320, y: 0, width: 40, height: 54)
        for shelf: CGRect? in [nil, .zero, CGRect(x: 0, y: 0, width: 40, height: 54)] {
            for x: CGFloat in [320, 340, 360, 380] {
                XCTAssertEqual(StripDropRouting.route(location: CGPoint(x: x, y: 20), isApplicationDrag: false, isTrashItemDrag: false,
                    shelfFrame: shelf, trashFrame: trash, folderFrames: [:], orderedPaths: []), .trash)
                XCTAssertEqual(StripDropRouting.route(location: CGPoint(x: x, y: 20), isApplicationDrag: true, isTrashItemDrag: false,
                    shelfFrame: shelf, trashFrame: trash, folderFrames: [:], orderedPaths: []), .keepApp)
            }
        }
        for frame: CGRect? in [nil, .zero] {
            XCTAssertEqual(StripDropRouting.route(location: CGPoint(x: 350, y: 20), isApplicationDrag: false, isTrashItemDrag: false,
                shelfFrame: nil, trashFrame: frame, folderFrames: [:], orderedPaths: []), .none)
        }
    }
    private let shelf = CGRect(x: 100, y: 0, width: 44, height: 52)

    private func frames(_ paths: [String], startX: CGFloat = 152) -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        var x = startX
        for path in paths {
            result["folder-" + path] = CGRect(x: x, y: 0, width: 52, height: 52)
            x += 60
        }
        return result
    }

    func testHitShelfStashes() {
        let target = StripDropRouting.route(location: CGPoint(x: 120, y: 26),
                                            isApplicationDrag: false, isTrashItemDrag: false,
                                            shelfFrame: shelf, trashFrame: nil, folderFrames: [:], orderedPaths: [])
        XCTAssertEqual(target, .stash)
    }

    func testLeftOfShelfIsNone() {
        let target = StripDropRouting.route(location: CGPoint(x: 50, y: 26),
                                            isApplicationDrag: false, isTrashItemDrag: false,
                                            shelfFrame: shelf, trashFrame: nil, folderFrames: [:], orderedPaths: [])
        XCTAssertEqual(target, .none)
    }

    func testZeroShelfFrameRejectsEverything() {
        let target = StripDropRouting.route(location: CGPoint(x: 120, y: 26),
                                            isApplicationDrag: false, isTrashItemDrag: false,
                                            shelfFrame: .zero, trashFrame: nil, folderFrames: [:], orderedPaths: [])
        XCTAssertEqual(target, .none)
    }

    func testNoFoldersPinsAtZeroWithinTailSlack() {
        // Within the 24pt slack past the shelf's right edge 144 → first pin, insert at 0.
        let target = StripDropRouting.route(location: CGPoint(x: 160, y: 26),
                                            isApplicationDrag: false, isTrashItemDrag: false,
                                            shelfFrame: shelf, trashFrame: nil, folderFrames: [:], orderedPaths: [])
        XCTAssertEqual(target, .pin(insertIndex: 0))
    }

    func testDropOnLeftHalfOfFirstFolderMovesIntoIt() {
        let paths = ["/a", "/b"]
        // The first chip is at 152..204; both halves are a move-into target.
        let target = StripDropRouting.route(location: CGPoint(x: 160, y: 26),
                                            isApplicationDrag: false, isTrashItemDrag: false,
                                            shelfFrame: shelf, trashFrame: nil, folderFrames: frames(paths), orderedPaths: paths)
        XCTAssertEqual(target, .moveInto(path: "/a"))
    }

    func testDropOnRightHalfOfFirstFolderMovesIntoIt() {
        let paths = ["/a", "/b"]
        let target = StripDropRouting.route(location: CGPoint(x: 190, y: 26),
                                            isApplicationDrag: false, isTrashItemDrag: false,
                                            shelfFrame: shelf, trashFrame: nil, folderFrames: frames(paths), orderedPaths: paths)
        XCTAssertEqual(target, .moveInto(path: "/a"))
    }

    func testDropUsesHorizontalChipBand() {
        let paths = ["/a"]
        let target = StripDropRouting.route(location: CGPoint(x: 180, y: 200),
                                            isApplicationDrag: false, isTrashItemDrag: false,
                                            shelfFrame: shelf, trashFrame: nil, folderFrames: frames(paths), orderedPaths: paths)
        XCTAssertEqual(target, .moveInto(path: "/a"))
    }

    func testGapBetweenFoldersStillPins() {
        let paths = ["/a", "/b"]
        // First card's right edge 204, second's left edge 212; x=208 is a real 8pt gap.
        let target = StripDropRouting.route(location: CGPoint(x: 208, y: 26),
                                            isApplicationDrag: false, isTrashItemDrag: false,
                                            shelfFrame: shelf, trashFrame: nil, folderFrames: frames(paths), orderedPaths: paths)
        XCTAssertEqual(target, .pin(insertIndex: 1))
    }

    func testMissingFrameDoesNotBecomeMoveTarget() {
        let paths = ["/a", "/b"]
        let partial = ["folder-/b": CGRect(x: 212, y: 0, width: 52, height: 52)]
        let target = StripDropRouting.route(location: CGPoint(x: 160, y: 26),
                                            isApplicationDrag: false, isTrashItemDrag: false,
                                            shelfFrame: shelf, trashFrame: nil, folderFrames: partial, orderedPaths: paths)
        XCTAssertEqual(target, .pin(insertIndex: 0))
    }

    func testTailSlackAfterLastFolderPinsAtEnd() {
        let paths = ["/a", "/b"]
        // Within the +24 slack past the second chip's right edge 264 → append at the end (2).
        let target = StripDropRouting.route(location: CGPoint(x: 276, y: 26),
                                            isApplicationDrag: false, isTrashItemDrag: false,
                                            shelfFrame: shelf, trashFrame: nil, folderFrames: frames(paths), orderedPaths: paths)
        XCTAssertEqual(target, .pin(insertIndex: 2))
    }

    func testFarRightIsNone() {
        let paths = ["/a", "/b"]
        let target = StripDropRouting.route(location: CGPoint(x: 400, y: 26),
                                            isApplicationDrag: false, isTrashItemDrag: false,
                                            shelfFrame: shelf, trashFrame: nil, folderFrames: frames(paths), orderedPaths: paths)
        XCTAssertEqual(target, .none)
    }

    // MARK: - Shelf off (shelfFrame = nil)

    func testHiddenShelfStillMovesIntoFolders() {
        let paths = ["/a", "/b"]
        let target = StripDropRouting.route(location: CGPoint(x: 160, y: 26),
                                            isApplicationDrag: false, isTrashItemDrag: false,
                                            shelfFrame: nil, trashFrame: nil, folderFrames: frames(paths), orderedPaths: paths)
        XCTAssertEqual(target, .moveInto(path: "/a"))
    }

    func testHiddenShelfKeepsHeadSlackForInsertAtZero() {
        let paths = ["/a", "/b"]
        // The first chip's left edge is 152, headSlack 8 → 144..152 is the only landing for "insert at the
        // front". Without it the whole first chip is judged moveInto first, and inserting at 0 becomes
        // impossible.
        let target = StripDropRouting.route(location: CGPoint(x: 147, y: 26),
                                            isApplicationDrag: false, isTrashItemDrag: false,
                                            shelfFrame: nil, trashFrame: nil, folderFrames: frames(paths), orderedPaths: paths)
        XCTAssertEqual(target, .pin(insertIndex: 0))
    }

    func testHiddenShelfRejectsLeftOfHeadSlack() {
        let paths = ["/a"]
        let target = StripDropRouting.route(location: CGPoint(x: 120, y: 26),
                                            isApplicationDrag: false, isTrashItemDrag: false,
                                            shelfFrame: nil, trashFrame: nil, folderFrames: frames(paths), orderedPaths: paths)
        XCTAssertEqual(target, .none, "with the shelf off, its former position must not accept any drop")
    }

    func testHiddenShelfStillPinsInGapAndTailSlack() {
        let paths = ["/a", "/b"]
        XCTAssertEqual(
            StripDropRouting.route(location: CGPoint(x: 208, y: 26),
                                   isApplicationDrag: false, isTrashItemDrag: false,
                                   shelfFrame: nil, trashFrame: nil, folderFrames: frames(paths), orderedPaths: paths),
            .pin(insertIndex: 1)
        )
        XCTAssertEqual(
            StripDropRouting.route(location: CGPoint(x: 276, y: 26),
                                   isApplicationDrag: false, isTrashItemDrag: false,
                                   shelfFrame: nil, trashFrame: nil, folderFrames: frames(paths), orderedPaths: paths),
            .pin(insertIndex: 2)
        )
    }

    func testHiddenShelfWithNoFoldersRejectsEverything() {
        // Shelf off + no pinned folders → the folder zone does not exist and the taskbar has no
        // landing at all. Accepted limit: the way back is re-checking "Show Shelf" in the menu.
        for x in [CGFloat(50), 120, 160, 400] {
            XCTAssertEqual(
                StripDropRouting.route(location: CGPoint(x: x, y: 26),
                                       isApplicationDrag: false, isTrashItemDrag: false,
                                       shelfFrame: nil, trashFrame: nil, folderFrames: [:], orderedPaths: []),
                .none
            )
        }
    }

    // MARK: - Dragging an app (safety boundary)

    /// **The most important case in this file**: an app only ever gets `.keepApp`. `.moveInto` is a real
    /// file move (move on the same volume, copy across volumes): letting one app through means moving it
    /// out of Applications; `.pin` would pin it as a folder tile that expands the internals of the `.app`
    /// (a real bug before 2026-09-07: `.app` is itself a directory, so `isDirectoryKey` cannot tell).
    func testApplicationDragNeverReachesAnyFileTarget() {
        let paths = ["/a", "/b"]
        let folders = frames(paths)
        // On the shelf, on the first folder tile, in the gap between tiles, tail slack, outside the bar, far
        // left of the bar: all covered.
        for x in [CGFloat(0), 50, 120, 147, 160, 190, 208, 276, 400, 2000] {
            for shelfFrame in [shelf, nil] {
                let target = StripDropRouting.route(location: CGPoint(x: x, y: 26),
                                                    isApplicationDrag: true, isTrashItemDrag: false,
                                                    shelfFrame: shelfFrame, trashFrame: nil,
                                                    folderFrames: folders, orderedPaths: paths)
                XCTAssertEqual(target, .keepApp, "x=\(x) shelf=\(String(describing: shelfFrame))")
            }
        }
    }

    /// Shelf off + no pinned folders = the file path has no landing anywhere
    /// (accepted limit), but apps can still land: that is the entry point added here.
    func testApplicationDragLandsEvenWithNoFileDropTargetAtAll() {
        for x in [CGFloat(50), 120, 160, 400] {
            XCTAssertEqual(
                StripDropRouting.route(location: CGPoint(x: x, y: 26),
                                       isApplicationDrag: true, isTrashItemDrag: false,
                                       shelfFrame: nil, trashFrame: nil,
                                       folderFrames: [:], orderedPaths: []),
                .keepApp
            )
        }
    }

    /// Reverse lock: for non-apps `.keepApp` never appears (otherwise ordinary files would check Keep too).
    func testNonApplicationDragNeverKeepsAnApp() {
        let paths = ["/a", "/b"]
        for x in [CGFloat(0), 50, 120, 147, 160, 208, 276, 400] {
            XCTAssertNotEqual(
                StripDropRouting.route(location: CGPoint(x: x, y: 26),
                                       isApplicationDrag: false, isTrashItemDrag: false,
                                       shelfFrame: shelf, trashFrame: nil,
                                       folderFrames: frames(paths), orderedPaths: paths),
                .keepApp
            )
        }
    }

    // MARK: - Make-room gap

    func testGhostInsertsBeforeOrAfterTheAnchor() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(StripDropRouting.ghostInsertionIndex(orderedIDs: ids, targetID: "a", after: false), 0)
        XCTAssertEqual(StripDropRouting.ghostInsertionIndex(orderedIDs: ids, targetID: "a", after: true), 1)
        XCTAssertEqual(StripDropRouting.ghostInsertionIndex(orderedIDs: ids, targetID: "c", after: true), 3)
    }

    /// The anchor was computed last frame; this frame that card may be gone (app quit / display filter). Must
    /// land at the end and never return an out-of-range index: the projection layer passes it straight to
    /// `insert(at:)`.
    func testGhostFallsToTailWhenAnchorIsGone() {
        let ids = ["a", "b"]
        XCTAssertEqual(StripDropRouting.ghostInsertionIndex(orderedIDs: ids, targetID: "gone", after: false), 2)
        XCTAssertEqual(StripDropRouting.ghostInsertionIndex(orderedIDs: ids, targetID: nil, after: true), 2)
        XCTAssertEqual(StripDropRouting.ghostInsertionIndex(orderedIDs: [], targetID: "a", after: true), 0)
    }

    /// **The crux of the gate**: with the pointer resting in the gap, the two cards are equidistant and the
    /// decision flips between "right of the left neighbor" and "left of the right neighbor", which are the
    /// same slot. Folding to an index must normalize them, otherwise each flip is a "position unchanged yet
    /// the whole taskbar recomputed" pass.
    func testEquivalentAnchorsCollapseToTheSameSlot() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(
            StripDropRouting.ghostInsertionIndex(orderedIDs: ids, targetID: "a", after: true),
            StripDropRouting.ghostInsertionIndex(orderedIDs: ids, targetID: "b", after: false)
        )
        XCTAssertEqual(
            StripDropRouting.ghostInsertionIndex(orderedIDs: ids, targetID: "b", after: true),
            StripDropRouting.ghostInsertionIndex(orderedIDs: ids, targetID: "c", after: false)
        )
    }

    /// Criterion of the change gate. Feeding the same slot repeatedly must be judged "unchanged".
    func testGhostEqualityGatesRedraws() {
        let a = StripDropGhost(bundleID: "com.foo", insertIndex: 2)
        XCTAssertEqual(a, StripDropGhost(bundleID: "com.foo", insertIndex: 2))
        XCTAssertNotEqual(a, StripDropGhost(bundleID: "com.foo", insertIndex: 3))
        XCTAssertNotEqual(a, StripDropGhost(bundleID: "com.other", insertIndex: 2))
    }

    func testHiddenShelfIgnoresStaleShelfCoordinates() {
        // The view side must pass nil, not the old frame: this locks "passing nil never hits the stash
        // again".
        let paths = ["/a"]
        let onShelfSpot = CGPoint(x: 120, y: 26)
        XCTAssertEqual(
            StripDropRouting.route(location: onShelfSpot,
                                   isApplicationDrag: false, isTrashItemDrag: false,
                                   shelfFrame: shelf, trashFrame: nil, folderFrames: frames(paths), orderedPaths: paths),
            .stash
        )
        XCTAssertEqual(
            StripDropRouting.route(location: onShelfSpot,
                                   isApplicationDrag: false, isTrashItemDrag: false,
                                   shelfFrame: nil, trashFrame: nil, folderFrames: frames(paths), orderedPaths: paths),
            .none
        )
    }

    func testOnlyTheTrashDropsTheCursorBadge() {
        XCTAssertTrue(StripDropRouting.usesGenericOperation(hoveredTarget: .trash, proposedIsCopy: true, sourceAllowsGeneric: true))
        let others: [StripDropRouting.Target?] = [nil, .none, .stash, .keepApp, .moveInto(path: "/tmp/a"), .pin(insertIndex: 0)]
        for target in others {
            XCTAssertFalse(StripDropRouting.usesGenericOperation(hoveredTarget: target, proposedIsCopy: true, sourceAllowsGeneric: true),
                           "\(String(describing: target))")
        }
    }

    func testAFolderOnTheSameVolumeDropsTheBadgeBecauseTheFileMoves() {
        let folder = StripDropRouting.Target.moveInto(path: "/tmp/a")
        XCTAssertTrue(StripDropRouting.usesGenericOperation(
            hoveredTarget: folder, proposedIsCopy: true, sourceAllowsGeneric: true, moveIntoStaysOnVolume: true))
        // Another volume: the file is copied, so the plus stays.
        XCTAssertFalse(StripDropRouting.usesGenericOperation(
            hoveredTarget: folder, proposedIsCopy: true, sourceAllowsGeneric: true, moveIntoStaysOnVolume: false))
        // The flag means nothing for other targets.
        XCTAssertFalse(StripDropRouting.usesGenericOperation(
            hoveredTarget: .stash, proposedIsCopy: true, sourceAllowsGeneric: true, moveIntoStaysOnVolume: true))
    }

    func testTrashKeepsTheAnswerWhenGenericIsNotOffered() {
        // ⌥ held: the source offers copy only.
        XCTAssertFalse(StripDropRouting.usesGenericOperation(hoveredTarget: .trash, proposedIsCopy: true, sourceAllowsGeneric: false))
        // A refusal (e.g. Trash items) stays a refusal.
        XCTAssertFalse(StripDropRouting.usesGenericOperation(hoveredTarget: .trash, proposedIsCopy: false, sourceAllowsGeneric: true))
    }
}
