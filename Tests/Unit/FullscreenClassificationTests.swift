import XCTest

final class FullscreenClassificationTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    // Regression: the Finder desktop pseudo-window (role=AXScrollArea, frame exactly the full screen) must
    // not count as fullscreen
    func testDesktopPseudoWindowWithExactScreenFrameIsNotFullscreen() {
        XCTAssertFalse(FullscreenWindowClassifier.isFullscreen(
            role: "AXScrollArea", isAXFullscreen: false, windowFrame: screen, screenCGFrame: screen))
    }

    func testUnreadableRoleIsNotFullscreenEvenWithExactScreenFrame() {
        XCTAssertFalse(FullscreenWindowClassifier.isFullscreen(
            role: nil, isAXFullscreen: false, windowFrame: screen, screenCGFrame: screen))
    }

    func testUnreadableRoleIsNotFullscreenEvenWithAXFullscreenFlag() {
        XCTAssertFalse(FullscreenWindowClassifier.isFullscreen(
            role: nil, isAXFullscreen: true, windowFrame: nil, screenCGFrame: screen))
    }

    func testNativeFullscreenWindowIsFullscreen() {
        XCTAssertTrue(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: true, windowFrame: screen, screenCGFrame: screen))
    }

    func testNativeFullscreenWithUnreadableFrameIsFullscreen() {
        XCTAssertTrue(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: true, windowFrame: nil, screenCGFrame: screen))
    }

    func testNativeFullscreenOnAnotherScreenIsNotFullscreenHere() {
        let otherScreen = CGRect(x: 1512, y: -200, width: 1920, height: 1080)
        XCTAssertFalse(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: true, windowFrame: otherScreen, screenCGFrame: screen))
    }

    // Fullscreen tiling (true split view): AXFullScreen=true but only half the screen wide (shape measured
    // 2026-08-30, scaled to the test screen). This is the fix for the old width clause (width > screen×0.7),
    // which rejected it and left the taskbar covering split-view content.
    func testSplitViewTileOnThisScreenIsFullscreen() {
        let leftTile = CGRect(x: 0, y: 20, width: 754, height: 962)
        XCTAssertTrue(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: true, windowFrame: leftTile, screenCGFrame: screen))
        let rightTile = CGRect(x: 756, y: 20, width: 756, height: 962)
        XCTAssertTrue(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: true, windowFrame: rightTile, screenCGFrame: screen))
    }

    // Takes over the multi-display guardrail: a window whose body is on the neighboring screen and only pokes
    // a few dozen points into this one must not count as fullscreen on this screen. The old width clause used
    // to block such windows as a side effect; with area attribution, this case pins the behavior.
    func testFullscreenWindowMostlyOnNeighborScreenIsNotFullscreenHere() {
        let mostlyElsewhere = CGRect(x: 1480, y: -200, width: 1920, height: 1080)
        XCTAssertFalse(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: true, windowFrame: mostlyElsewhere, screenCGFrame: screen))
    }

    // Desktop tiling (the default "split" on macOS 26): half width but AXFullScreen=false, takes the frame
    // fallback and must not count as fullscreen. It is an ordinary window on an ordinary desktop and the bar
    // shows as usual (covering that half is a lift avoidance matter, not hiding).
    func testDesktopTiledHalfWindowIsNotFullscreen() {
        let tiled = CGRect(x: 756, y: 20, width: 756, height: 962)
        XCTAssertFalse(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: false, windowFrame: tiled, screenCGFrame: screen))
    }

    // Borderless fullscreen without the AXFullScreen flag (games/HTML5) still takes the frame≈full-screen
    // fallback
    func testBorderlessScreenSizedWindowIsFullscreen() {
        let nearScreen = screen.insetBy(dx: 2, dy: 2)
        XCTAssertTrue(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: false, windowFrame: nearScreen, screenCGFrame: screen))
    }

    func testOrdinaryWindowIsNotFullscreen() {
        let partial = CGRect(x: 253, y: 125, width: 1127, height: 689)
        XCTAssertFalse(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: false, windowFrame: partial, screenCGFrame: screen))
    }

    func testRealWindowWithUnreadableFrameIsNotFullscreen() {
        XCTAssertFalse(FullscreenWindowClassifier.isFullscreen(
            role: "AXWindow", isAXFullscreen: false, windowFrame: nil, screenCGFrame: screen))
    }

    // MARK: - Membership on all desktops (issue #19)

    func testMembershipIsHealthyWhenWindowCoversEveryDesktop() {
        XCTAssertEqual(
            AllSpacesMembership.missingSpaceIDs(windowSpaceIDs: [1, 3, 1020], desktopSpaceIDs: [1, 3, 1020]),
            [])
    }

    // This is the issue #19 symptom: after leaving fullscreen only the current desktop is left
    func testMembershipCollapsedToCurrentDesktopIsReported() {
        XCTAssertEqual(
            AllSpacesMembership.missingSpaceIDs(windowSpaceIDs: [1], desktopSpaceIDs: [1, 3, 1020]),
            [3, 1020])
    }

    // A window that is also on a fullscreen Space is fine (that is how it looks the moment it enters
    // fullscreen)
    func testExtraFullscreenSpaceMembershipIsNotAProblem() {
        XCTAssertEqual(
            AllSpacesMembership.missingSpaceIDs(windowSpaceIDs: [1, 3, 1013], desktopSpaceIDs: [1, 3]),
            [])
    }

    // With a single desktop there is no desktop to lose, never trigger the repair
    func testSingleDesktopNeverReportsMissing() {
        XCTAssertEqual(
            AllSpacesMembership.missingSpaceIDs(windowSpaceIDs: [], desktopSpaceIDs: [1]),
            [])
    }

    func testEmptyDesktopListNeverReportsMissing() {
        XCTAssertEqual(
            AllSpacesMembership.missingSpaceIDs(windowSpaceIDs: [1], desktopSpaceIDs: []),
            [])
    }

    // A single repair may fail, so retries must be allowed, but not without limit
    func testRepairRetriesAreBounded() {
        XCTAssertTrue(AllSpacesMembership.shouldRetry(attempt: 0))
        XCTAssertTrue(AllSpacesMembership.shouldRetry(attempt: 2))
        XCTAssertFalse(AllSpacesMembership.shouldRetry(attempt: 3))
        XCTAssertFalse(AllSpacesMembership.shouldRetry(attempt: 4))
    }
}
