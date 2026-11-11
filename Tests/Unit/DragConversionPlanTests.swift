import XCTest

final class DragConversionPlanTests: XCTestCase {

    // MARK: - drawerDragOutMode

    func testEmptyBundleIDRejects() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "", isMessagingMember: false, isInSnapshot: true, isRunningProcess: true, hasRealWindow: true, isKept: true), .reject)
    }

    /// 2026-08-20: Finder can go into the drawer, so it can also
    /// be dragged back to the taskbar like an ordinary app.
    func testFinderDragsOutLikeAnOrdinaryApp() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: FinderTaskbarPolicy.bundleID, isMessagingMember: false,
            isInSnapshot: true, isRunningProcess: true, hasRealWindow: true, isKept: true), .unstash)
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: FinderTaskbarPolicy.bundleID, isMessagingMember: false,
            isInSnapshot: true, isRunningProcess: true, hasRealWindow: false, isKept: true), .keepPlacement)
    }

    func testRunningMessagingMemberReleasesToMessaging() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "com.example.chat", isMessagingMember: true, isInSnapshot: true, isRunningProcess: true, hasRealWindow: false, isKept: false), .releaseToMessaging)
    }

    /// The messaging check must come before the real-window check: a running
    /// messaging app has a main window and must not fall into unstash.
    func testMessagingPrecedesRealWindowCheck() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "com.example.chat", isMessagingMember: true, isInSnapshot: true, isRunningProcess: true, hasRealWindow: true, isKept: false), .releaseToMessaging)
    }

    /// Rejected only when neither running nor checked as
    /// kept: releasing it there really would make it vanish.
    func testMessagingMemberNeitherRunningNorKeptRejects() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "com.example.chat", isMessagingMember: true, isInSnapshot: false,
            isRunningProcess: false, hasRealWindow: false, isKept: false), .reject)
    }

    /// **Regression lock**: process running but absent from the window inventory
    /// (WeChat with its main window closed is like this): it must be releasable.
    /// The criterion must share its source with the messaging zone's own visibility rule
    /// and must not check the window inventory (measured 2026-08-20, confirmed in logs).
    func testRunningWithNoTrackedWindowStillReleases() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "com.tencent.xinWeChat", isMessagingMember: true, isInSnapshot: false,
            isRunningProcess: true, hasRealWindow: false, isKept: false), .releaseToMessaging)
    }

    /// Not running but checked as kept: the messaging zone shows it
    /// anyway (unified keep model), so it can be released back too.
    func testKeptButNotRunningMessagingMemberReleases() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "com.example.chat", isMessagingMember: true, isInSnapshot: false,
            isRunningProcess: false, hasRealWindow: false, isKept: true), .releaseToMessaging)
    }

    func testRealWindowUnstashes() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "com.example.app", isMessagingMember: false, isInSnapshot: true, isRunningProcess: true, hasRealWindow: true, isKept: false), .unstash)
    }

    func testKeptAppWithoutSnapshotUsesKeepPlacement() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "com.example.app", isMessagingMember: false, isInSnapshot: false, isRunningProcess: false, hasRealWindow: false, isKept: true), .keepPlacement)
    }

    func testRunningFallbackUsesKeepPlacementWithoutKept() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "com.example.app", isMessagingMember: false, isInSnapshot: true, isRunningProcess: true, hasRealWindow: false, isKept: false), .keepPlacement)
    }

    func testInactiveUncheckedPlacementRejects() {
        XCTAssertEqual(DragConversionPlan.drawerDragOutMode(
            bundleID: "com.example.app", isMessagingMember: false, isInSnapshot: false, isRunningProcess: false, hasRealWindow: false, isKept: false), .reject)
    }

    // MARK: - endAction

    func testStripAndFolderNeverRouteHere() {
        XCTAssertEqual(DragConversionPlan.endAction(
            source: .strip, isConvertedToStrip: false, isOverDropZone: true, isMessagingMember: false), .none)
        XCTAssertEqual(DragConversionPlan.endAction(
            source: .folder, isConvertedToStrip: false, isOverDropZone: true, isMessagingMember: false), .none)
    }

    func testMessagingChipOverDropZoneStashes() {
        XCTAssertEqual(DragConversionPlan.endAction(
            source: .messaging, isConvertedToStrip: false, isOverDropZone: true, isMessagingMember: true), .stashMessagingChip)
    }

    /// Messaging chip released on desktop / folder zone / live zone (none is a drop zone) -> stays put.
    func testMessagingChipOutsideDropZoneDoesNothing() {
        XCTAssertEqual(DragConversionPlan.endAction(
            source: .messaging, isConvertedToStrip: false, isOverDropZone: false, isMessagingMember: true), .none)
    }

    func testConvertedDrawerDragCommits() {
        XCTAssertEqual(DragConversionPlan.endAction(
            source: .drawer, isConvertedToStrip: true, isOverDropZone: true, isMessagingMember: false), .commitDrawerToStrip)
        XCTAssertEqual(DragConversionPlan.endAction(
            source: .drawer, isConvertedToStrip: true, isOverDropZone: false, isMessagingMember: false), .commitDrawerToStrip)
    }

    func testUnconvertedDrawerDropOnStripFallbackUnstashes() {
        XCTAssertEqual(DragConversionPlan.endAction(
            source: .drawer, isConvertedToStrip: false, isOverDropZone: true, isMessagingMember: false), .fallbackUnstash)
    }

    /// A messaging member's drawer icon never takes the downgrade unstash: release
    /// on the taskbar (outside the messaging zone) -> stays in the drawer.
    func testMessagingMemberNeverFallbackUnstashes() {
        XCTAssertEqual(DragConversionPlan.endAction(
            source: .drawer, isConvertedToStrip: false, isOverDropZone: true, isMessagingMember: true), .none)
    }

    func testUnconvertedDrawerDropOutsideDoesNothing() {
        XCTAssertEqual(DragConversionPlan.endAction(
            source: .drawer, isConvertedToStrip: false, isOverDropZone: false, isMessagingMember: false), .none)
    }

    // MARK: - Landing a drag into the drawer -> kept turned on automatically

    /// Turned on only when brought in from outside the drawer (taskbar / messaging zone).
    func testDropFromOutsideIntoDrawerEnablesKept() {
        XCTAssertTrue(DragConversionPlan.enablesKeptOnDrop(originSource: .strip, endedInDrawer: true))
        XCTAssertTrue(DragConversionPlan.enablesKeptOnDrop(originSource: .messaging, endedInDrawer: true))
    }

    /// Drag source is the drawer = it was already inside (reorder
    /// inside the drawer, withdrawn promotion), not a "drag in".
    func testDragStartingInDrawerNeverEnablesKept() {
        XCTAssertFalse(DragConversionPlan.enablesKeptOnDrop(originSource: .drawer, endedInDrawer: true))
    }

    /// Folder chips are fully isolated from stash semantics and never take this path.
    func testFolderDragNeverEnablesKept() {
        XCTAssertFalse(DragConversionPlan.enablesKeptOnDrop(originSource: .folder, endedInDrawer: true))
    }

    /// Not in the drawer after landing -> never turned on, wherever it came from
    /// (undo, downgrade removal and promotion into the taskbar all take this branch).
    func testNotEndingInDrawerNeverEnablesKept() {
        for source in [DragSource.strip, .drawer, .folder, .messaging] {
            XCTAssertFalse(DragConversionPlan.enablesKeptOnDrop(originSource: source, endedInDrawer: false))
        }
    }
}
