import XCTest
@testable import NitiaDock

@MainActor
final class AppMembershipControllerTests: XCTestCase {

    private var kept: KeptAppStore!
    private var drawer: DrawerStore!
    private var messaging: MessagingAppStore!
    private var controller: AppMembershipController!

    private func makeDefaults() -> UserDefaults {
        let suite = "test-membership-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    override func setUp() {
        super.setUp()
        let defaults = makeDefaults()
        kept = KeptAppStore(defaults: defaults)
        drawer = DrawerStore(defaults: defaults)
        messaging = MessagingAppStore(defaults: defaults)
        controller = AppMembershipController(
            keptAppStore: kept,
            drawerStore: drawer,
            messagingStore: messaging
        )
    }

    // MARK: - applyDragLanding (stash landing also sets kept; every drag-in turns it on again)

    func testApplyDragLandingEnablesKeptOnlyWhenEndedInDrawerFromStripOrMessaging() {
        for source in [DragSource.strip, .drawer, .folder, .messaging] {
            for endedInDrawer in [true, false] {
                let defaults = makeDefaults()
                let kept = KeptAppStore(defaults: defaults)
                let drawer = DrawerStore(defaults: defaults)
                let messaging = MessagingAppStore(defaults: defaults)
                let controller = AppMembershipController(keptAppStore: kept, drawerStore: drawer, messagingStore: messaging)
                if endedInDrawer { drawer.add("com.example.app") }
                controller.applyDragLanding(bundleID: "com.example.app", originSource: source)
                let expected = endedInDrawer && (source == .strip || source == .messaging)
                XCTAssertEqual(kept.contains("com.example.app"), expected, "source=\(source) endedInDrawer=\(endedInDrawer)")
                XCTAssertEqual(drawer.contains("com.example.app"), endedInDrawer, "setting kept on landing must not change drawer")
            }
        }
    }

    func testApplyDragLandingReEnablesKeptAfterManualUncheck() {
        drawer.add("com.example.app")
        controller.applyDragLanding(bundleID: "com.example.app", originSource: .strip)
        XCTAssertTrue(kept.contains("com.example.app"))
        controller.setKept("com.example.app", enabled: false)
        XCTAssertFalse(kept.contains("com.example.app"))
        controller.applyDragLanding(bundleID: "com.example.app", originSource: .messaging)
        XCTAssertTrue(kept.contains("com.example.app"), "not a one-time seed: dragging in again turns it back on")
    }

    // MARK: - setKept (changes only kept, can coexist with messaging)

    func testSetKeptAddsWithoutChangingDrawerPlacement() {
        drawer.add("com.example.app")
        controller.setKept("com.example.app", enabled: true)
        XCTAssertTrue(kept.contains("com.example.app"))
        XCTAssertTrue(drawer.contains("com.example.app"))
    }

    func testSetKeptCoexistsWithMessagingIdentity() {
        messaging.mark("com.example.app")
        controller.setKept("com.example.app", enabled: true)
        XCTAssertTrue(kept.contains("com.example.app"))
        XCTAssertTrue(messaging.contains("com.example.app"))
    }

    /// Reversed 2026-08-20: Finder also uses the unified "Keep in Dock", checked by default through seeding,
    /// and can be unchecked and rechecked.
    func testSetKeptAcceptsFinderBothWays() {
        let finder = FinderTaskbarPolicy.bundleID
        // fork: upstream asserts the seed here; whether Finder starts kept is ForkDefaults' call.
        // Both directions of the toggle are still exercised below either way.
        XCTAssertEqual(kept.contains(finder), ForkDefaults.keepsFinderByDefault)
        controller.setKept(finder, enabled: false)
        XCTAssertFalse(kept.contains(finder))
        controller.setKept(finder, enabled: true)
        XCTAssertTrue(kept.contains(finder))
    }

    func testMoveToDrawerAcceptsFinder() {
        let finder = FinderTaskbarPolicy.bundleID
        controller.moveToDrawer(finder)
        XCTAssertTrue(drawer.contains(finder))
    }

    func testUnsetKeptLeavesDrawerPlacementAndMessagingUntouched() {
        controller.setKept("com.example.app", enabled: true)
        drawer.add("com.example.app")
        messaging.mark("com.example.app")
        controller.setKept("com.example.app", enabled: false)
        XCTAssertFalse(kept.contains("com.example.app"))
        XCTAssertTrue(drawer.contains("com.example.app"))
        XCTAssertTrue(messaging.contains("com.example.app"))
    }

    func testMoveToDrawerPreservesKept() {
        controller.setKept("com.example.app", enabled: true)
        controller.moveToDrawer("com.example.app")
        XCTAssertTrue(kept.contains("com.example.app"))
        XCTAssertTrue(drawer.contains("com.example.app"))
    }

    // MARK: - markMessaging (first join sets kept, never changes drawer)

    func testMarkMessagingFirstJoinSeedsKeptAndKeepsDrawer() {
        drawer.add("com.example.app")
        controller.markMessaging("com.example.app")
        XCTAssertTrue(messaging.contains("com.example.app"))
        XCTAssertTrue(kept.contains("com.example.app"))     // first join sets kept
        XCTAssertTrue(drawer.contains("com.example.app"))   // placement untouched
    }

    func testMarkMessagingAgainDoesNotReopenUserRemovedKept() {
        controller.markMessaging("com.example.app")            // first time: sets kept
        controller.setKept("com.example.app", enabled: false)  // user unchecks keep
        controller.markMessaging("com.example.app")            // already a member: not set again
        XCTAssertTrue(messaging.contains("com.example.app"))
        XCTAssertFalse(kept.contains("com.example.app"))
    }

    /// Finder can be kept and can go into the drawer, but still cannot enter the messaging zone.
    func testMarkMessagingRejectsFinder() {
        let finder = FinderTaskbarPolicy.bundleID
        controller.markMessaging(finder)
        XCTAssertFalse(messaging.contains(finder))
    }

    // MARK: - autoRegisterMessaging (first detection sets kept, scans do not turn it back on)

    func testAutoRegisterMessagingSeedsKeptForNewMembers() {
        let chat = "com.tencent.xinWeChat"   // builtin whitelist
        controller.autoRegisterMessaging(runningBundleIDs: [chat],
                                         mainWindowIdentifiableBundleIDs: [chat])
        XCTAssertTrue(messaging.contains(chat))
        XCTAssertTrue(kept.contains(chat))
    }

    func testAutoRegisterMessagingDoesNotReopenUserRemovedKept() {
        let chat = "com.tencent.xinWeChat"
        // First seen: sets kept
        controller.autoRegisterMessaging(runningBundleIDs: [chat],
                                         mainWindowIdentifiableBundleIDs: [chat])
        controller.setKept(chat, enabled: false)                   // user unchecks keep
        // Scan again: already a member
        controller.autoRegisterMessaging(runningBundleIDs: [chat],
                                         mainWindowIdentifiableBundleIDs: [chat])
        XCTAssertTrue(messaging.contains(chat))
        XCTAssertFalse(kept.contains(chat))
    }

    func testAutoRegisterMessagingSkipsAppWithoutIdentifiableMainWindow() {
        // Apps like Messages whose main window can never be recognized do not enter the messaging zone, so
        // kept is not set for them.
        let messages = "com.apple.MobileSMS"  // builtin whitelist
        controller.autoRegisterMessaging(runningBundleIDs: [messages],
                                         mainWindowIdentifiableBundleIDs: [])
        XCTAssertFalse(messaging.contains(messages))
        XCTAssertFalse(kept.contains(messages))
    }

    // MARK: - unmarkMessaging (clears only the messaging identity, keeps kept + drawer)

    func testUnmarkMessagingKeepsKeptAndDrawer() {
        controller.markMessaging("com.example.app") // messaging + kept
        drawer.add("com.example.app")
        controller.unmarkMessaging("com.example.app")
        XCTAssertFalse(messaging.contains("com.example.app"))
        XCTAssertTrue(kept.contains("com.example.app"))
        XCTAssertTrue(drawer.contains("com.example.app"))
    }

    func testMessagingMenuDescriptorRoundTripPreservesAsymmetricSemantics() throws {
        let bundleID = "com.example.app"
        drawer.add(bundleID)

        let unchecked = try XCTUnwrap(LauncherMembershipItem.items(
            surface: .strip,
            bundleID: bundleID,
            isKept: false,
            isMessaging: false,
            controller: controller
        ).last)
        XCTAssertEqual(unchecked.label, String(localized: "Pin to Messaging Zone"))
        XCTAssertEqual(unchecked.isChecked, false)
        unchecked.action()
        XCTAssertTrue(messaging.contains(bundleID))
        XCTAssertTrue(kept.contains(bundleID), "first mark should still set kept")
        XCTAssertTrue(drawer.contains(bundleID), "marking does not change drawer placement")

        let checked = try XCTUnwrap(LauncherMembershipItem.items(
            surface: .drawer,
            bundleID: bundleID,
            isKept: true,
            isMessaging: true,
            controller: controller
        ).last)
        XCTAssertEqual(checked.label, String(localized: "Pin to Messaging Zone"))
        XCTAssertEqual(checked.isChecked, true)
        checked.action()
        XCTAssertFalse(messaging.contains(bundleID))
        XCTAssertTrue(kept.contains(bundleID), "unmarking does not change kept")
        XCTAssertTrue(drawer.contains(bundleID), "unmarking does not change drawer placement")
    }

    // MARK: - reconcileInvalidMemberships (clears only Finder's messaging identity)

    /// Runs on every launch: may only clear the messaging identity. Clearing the drawer would wipe a Finder
    /// the user dragged in themselves (2026-08-20).
    func testReconcileClearsOnlyFinderMessagingAndKeepsDrawerPlacement() {
        let finder = FinderTaskbarPolicy.bundleID
        drawer.add(finder)
        messaging.mark(finder)
        controller.reconcileInvalidMemberships()
        XCTAssertTrue(drawer.contains(finder))
        XCTAssertFalse(messaging.contains(finder))
    }

    func testReconcilePreservesKeptMessagingOverlap() {
        controller.setKept("com.example.app", enabled: true)
        messaging.mark("com.example.app")
        controller.reconcileInvalidMemberships()
        XCTAssertTrue(kept.contains("com.example.app"))
        XCTAssertTrue(messaging.contains("com.example.app"))
    }

    // MARK: - DrawerStore migration

    func testDrawerStoreMigratesLaunchFavoriteKey() {
        let defaults = makeDefaults()
        defaults.set(["com.example.fav1", "com.example.fav2"], forKey: "launchFavoriteBundleIDs")
        defaults.set(["com.example.existing"], forKey: "drawerBundleIDs")
        let migrated = DrawerStore(defaults: defaults)
        XCTAssertTrue(migrated.contains("com.example.fav1"))
        XCTAssertTrue(migrated.contains("com.example.fav2"))
        XCTAssertTrue(migrated.contains("com.example.existing"))
        XCTAssertNil(defaults.stringArray(forKey: "launchFavoriteBundleIDs"))
    }
}
