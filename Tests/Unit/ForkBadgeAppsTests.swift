import XCTest

/// fork: the user-editable list of apps that get an unread badge.
@MainActor
final class ForkBadgeAppsTests: XCTestCase {
    func testSeedGivesOutlookAndMailABadgeIdentity() {
        let store = MessagingAppStore(defaults: makeDefaults())
        XCTAssertEqual(store.extraBadgeBundleIDs, ForkDefaults.extraBadgeBundleIDs)
        XCTAssertTrue(store.isMessagingApp("com.microsoft.Outlook"))
        XCTAssertTrue(store.isMessagingApp("com.apple.mail"))
        XCTAssertTrue(store.extraBadgeAppsAreDefault)
    }

    func testTheRequestedChatAppsAreAlreadyUpstreamBuiltIns() {
        // The brief's Teams / Messages / Slack need no fork entry; this pins that assumption, so an
        // upstream change to its whitelist shows up here rather than as a silently missing badge.
        for id in ["com.microsoft.teams2", "com.apple.MobileSMS", "com.tinyspeck.slackmacgap"] {
            XCTAssertTrue(MessagingAppStore.builtinMessagingIDs.contains(id), id)
        }
    }

    func testExtraBadgeAppsNeverEnterTheMessagingZone() {
        let store = MessagingAppStore(defaults: makeDefaults())
        let added = store.autoRegister(
            runningBundleIDs: ["com.microsoft.Outlook", "com.apple.mail"],
            mainWindowIdentifiableBundleIDs: ["com.microsoft.Outlook", "com.apple.mail"]
        )
        XCTAssertEqual(added, [], "badge identity must not pin a mail client into the messaging zone")
        XCTAssertEqual(store.bundleIDs, [])
    }

    func testAddRemoveAndPersist() {
        let defaults = makeDefaults()
        let store = MessagingAppStore(defaults: defaults)
        store.addExtraBadgeApp("  com.example.tracker ")
        store.addExtraBadgeApp("com.example.tracker")
        store.addExtraBadgeApp("")
        XCTAssertEqual(store.extraBadgeBundleIDs, ForkDefaults.extraBadgeBundleIDs + ["com.example.tracker"])
        XCTAssertTrue(store.isMessagingApp("com.example.tracker"))
        XCTAssertFalse(store.extraBadgeAppsAreDefault)

        store.removeExtraBadgeApp("com.apple.mail")
        XCTAssertFalse(store.isMessagingApp("com.apple.mail"))
        XCTAssertEqual(MessagingAppStore(defaults: defaults).extraBadgeBundleIDs,
                       ["com.microsoft.Outlook", "com.example.tracker"])
    }

    func testAnEmptiedListStaysEmptyAcrossRestarts() {
        let defaults = makeDefaults()
        let store = MessagingAppStore(defaults: defaults)
        for id in store.extraBadgeBundleIDs { store.removeExtraBadgeApp(id) }
        XCTAssertEqual(MessagingAppStore(defaults: defaults).extraBadgeBundleIDs, [])
    }

    func testRestoreDefaultsRemovesTheKey() {
        let defaults = makeDefaults()
        let store = MessagingAppStore(defaults: defaults)
        store.removeExtraBadgeApp("com.apple.mail")
        store.resetExtraBadgeApps()
        XCTAssertEqual(store.extraBadgeBundleIDs, ForkDefaults.extraBadgeBundleIDs)
        XCTAssertNil(defaults.object(forKey: "com.tungsten.edge.badges.extraBundleIDs"))
    }

    func testEditingTheListRepublishesTheZoneListSoBadgeTargetsAreRecomputed() {
        let store = MessagingAppStore(defaults: makeDefaults())
        var publishes = 0
        let subscription = store.$bundleIDs.dropFirst().sink { _ in publishes += 1 }
        store.addExtraBadgeApp("com.example.tracker")
        store.removeExtraBadgeApp("com.example.tracker")
        XCTAssertEqual(publishes, 2)
        XCTAssertEqual(store.bundleIDs, [], "the zone list itself is unchanged")
        subscription.cancel()
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "com.tungsten.edge.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
