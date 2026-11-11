import XCTest

@MainActor
final class MessagingAppStoreTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "test-messaging-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeStore(_ ids: [String], defaults: UserDefaults? = nil) -> MessagingAppStore {
        let d = defaults ?? makeDefaults()
        let store = MessagingAppStore(defaults: d)
        for id in ids { store.mark(id) }
        return store
    }

    // MARK: - reorder

    func testReorderBeforeAndAfterTarget() {
        let store = makeStore(["a", "b", "c"])
        store.reorder(draggedID: "c", relativeTo: "a", after: false)
        XCTAssertEqual(store.bundleIDs, ["c", "a", "b"])
        store.reorder(draggedID: "c", relativeTo: "b", after: true)
        XCTAssertEqual(store.bundleIDs, ["a", "b", "c"])
    }

    func testReorderToHeadAndTail() {
        let store = makeStore(["a", "b", "c"])
        store.reorder(draggedID: "b", relativeTo: "a", after: false)   // first
        XCTAssertEqual(store.bundleIDs, ["b", "a", "c"])
        store.reorder(draggedID: "b", relativeTo: "c", after: true)    // last
        XCTAssertEqual(store.bundleIDs, ["a", "c", "b"])
    }

    func testReorderMiddle() {
        let store = makeStore(["a", "b", "c", "d"])
        store.reorder(draggedID: "d", relativeTo: "b", after: false)
        XCTAssertEqual(store.bundleIDs, ["a", "d", "b", "c"])
    }

    func testReorderOntoSelfIsNoOp() {
        let store = makeStore(["a", "b"])
        store.reorder(draggedID: "a", relativeTo: "a", after: true)
        XCTAssertEqual(store.bundleIDs, ["a", "b"])
    }

    func testReorderUnknownIDsAreNoOp() {
        let store = makeStore(["a", "b"])
        store.reorder(draggedID: "ghost", relativeTo: "a", after: true)
        XCTAssertEqual(store.bundleIDs, ["a", "b"])
        store.reorder(draggedID: "a", relativeTo: "ghost", after: true)
        XCTAssertEqual(store.bundleIDs, ["a", "b"])
    }

    /// Hidden members (in the drawer or not running, not shown in the zone) keep their relative position:
    /// reorder edits the full persisted array directly.
    func testHiddenMemberKeepsRelativePosition() {
        let store = makeStore(["a", "hidden", "b"])
        store.reorder(draggedID: "a", relativeTo: "b", after: true)
        XCTAssertEqual(store.bundleIDs, ["hidden", "b", "a"])
    }

    func testReorderPersistsAcrossReload() {
        let defaults = makeDefaults()
        let store = makeStore(["a", "b", "c"], defaults: defaults)
        store.reorder(draggedID: "c", relativeTo: "a", after: false)
        let reloaded = MessagingAppStore(defaults: defaults)
        XCTAssertEqual(reloaded.bundleIDs, ["c", "a", "b"])
    }

    // MARK: - V2 key migration

    func testNameListMigratesFromLegacyKeyToV2AndFreezesLegacy() {
        let defaults = makeDefaults()
        defaults.set(["com.chat.legacy"], forKey: "messagingBundleIDs")
        let store = MessagingAppStore(defaults: defaults)
        XCTAssertTrue(store.contains("com.chat.legacy"))
        XCTAssertEqual(defaults.stringArray(forKey: "messagingBundleIDsV2"), ["com.chat.legacy"])
        // Old key frozen, untouched (readable after rollback).
        XCTAssertEqual(defaults.stringArray(forKey: "messagingBundleIDs"), ["com.chat.legacy"])
    }

    func testFreshInstallPersistsEmptyV2Markers() {
        let defaults = makeDefaults()
        _ = MessagingAppStore(defaults: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "messagingBundleIDsV2"), [])
        XCTAssertEqual(defaults.stringArray(forKey: "messagingOptOutBundleIDsV2"), [])
    }

    func testExistingV2KeyPreventsRemigrationFromLegacy() {
        let defaults = makeDefaults()
        defaults.set(["com.v2.only"], forKey: "messagingBundleIDsV2")
        defaults.set(["com.legacy.ignored"], forKey: "messagingBundleIDs")
        let store = MessagingAppStore(defaults: defaults)
        XCTAssertTrue(store.contains("com.v2.only"))
        XCTAssertFalse(store.contains("com.legacy.ignored"))
    }

    func testOptOutMigratesIndependentlyOfNameList() {
        // The list already has V2 and opt-out has only the old key → opt-out migrates on its own (partial
        // migration state).
        let defaults = makeDefaults()
        defaults.set([String](), forKey: "messagingBundleIDsV2")
        defaults.set(["com.tencent.qq"], forKey: "messagingOptOutBundleIDs") // builtin, opted out
        let store = MessagingAppStore(defaults: defaults)
        let added = store.autoRegister(runningBundleIDs: ["com.tencent.qq"],
                                       mainWindowIdentifiableBundleIDs: ["com.tencent.qq"])
        XCTAssertTrue(added.isEmpty) // opt-out migration applied, no re-registration
        XCTAssertEqual(defaults.stringArray(forKey: "messagingOptOutBundleIDsV2"), ["com.tencent.qq"])
    }

    func testMarkReturnsTrueOnFirstJoinFalseAfter() {
        let store = MessagingAppStore(defaults: makeDefaults())
        XCTAssertTrue(store.mark("com.chat.app"))
        XCTAssertFalse(store.mark("com.chat.app"))
    }

    func testAutoRegisterReturnsNewlyAddedIDs() {
        let store = MessagingAppStore(defaults: makeDefaults())
        let chat = "com.tencent.xinWeChat" // builtin whitelist
        let added = store.autoRegister(runningBundleIDs: [chat, "com.not.messaging"],
                                       mainWindowIdentifiableBundleIDs: [chat])
        XCTAssertEqual(added, [chat])
        // Second round adds nothing
        XCTAssertTrue(store.autoRegister(runningBundleIDs: [chat],
                                         mainWindowIdentifiableBundleIDs: [chat]).isEmpty)
    }

    // MARK: - Admission capability bar (no recognizable main window, no messaging zone)

    func testAutoRegisterSkipsWhitelistedAppWithoutIdentifiableMainWindow() {
        // Apple Messages is on the builtin list, but its Catalyst numbered titles never identify a main
        // window → must not register.
        let store = MessagingAppStore(defaults: makeDefaults())
        let messages = "com.apple.MobileSMS"
        XCTAssertTrue(store.autoRegister(runningBundleIDs: [messages],
                                         mainWindowIdentifiableBundleIDs: []).isEmpty)
        XCTAssertFalse(store.contains(messages))
    }

    func testAutoRegisterAdmitsOnceMainWindowBecomesIdentifiable() {
        // Not registered while the main window is closed; it joins the list in the round the main window
        // appears.
        let store = MessagingAppStore(defaults: makeDefaults())
        let chat = "com.tencent.xinWeChat"
        XCTAssertTrue(store.autoRegister(runningBundleIDs: [chat],
                                         mainWindowIdentifiableBundleIDs: []).isEmpty)
        XCTAssertEqual(store.autoRegister(runningBundleIDs: [chat],
                                          mainWindowIdentifiableBundleIDs: [chat]), [chat])
    }

    func testMemberIsNeverReTestedSoItCannotFlapOutOfTheZone() {
        // One pass puts it on the list for good: closing the WeChat main window (unrecognizable right now)
        // must not evict it from the messaging zone.
        let store = MessagingAppStore(defaults: makeDefaults())
        let chat = "com.tencent.xinWeChat"
        XCTAssertEqual(store.autoRegister(runningBundleIDs: [chat],
                                          mainWindowIdentifiableBundleIDs: [chat]), [chat])
        _ = store.autoRegister(runningBundleIDs: [chat], mainWindowIdentifiableBundleIDs: [])
        XCTAssertTrue(store.contains(chat), "a registered member is not removed because its main window is currently unrecognizable")
    }

    func testManualMarkBypassesTheCapabilityGate() {
        // Manual marking is not subject to the admission bar (2026-07-21).
        let store = MessagingAppStore(defaults: makeDefaults())
        XCTAssertTrue(store.mark("com.apple.MobileSMS"))
        XCTAssertTrue(store.contains("com.apple.MobileSMS"))
    }


    // MARK: - isMessagingApp: identity is separate from "in the messaging zone" (2026-08-23)

    func testBuiltinAppIsMessagingAppWithoutEnteringZone() {
        let store = makeStore([])
        XCTAssertTrue(store.isMessagingApp("com.apple.MobileSMS"), "builtin list = identity, no need to be in the zone")
        XCTAssertFalse(store.contains("com.apple.MobileSMS"), "identity is not messaging zone membership")
    }

    func testManualPinGrantsIdentityUntilUnpinnedForUnknownApp() {
        let store = makeStore(["custom.chat"])
        XCTAssertTrue(store.isMessagingApp("custom.chat"))
        store.unmark("custom.chat")
        XCTAssertFalse(store.isMessagingApp("custom.chat"), "an app on neither the list nor the allowlist has no identity source once unpinned")
    }

    /// 2026-08-23 acceptance rework: Messages had earlier been removed from the messaging zone and its red
    /// badge vanished. Unchecking "Pin to messaging zone" only means "do not pin it in the zone"; a builtin
    /// messaging app's red badge must not go with it.
    func testUnpinningBuiltinKeepsIdentity() {
        let store = makeStore(["com.apple.MobileSMS"])
        store.unmark("com.apple.MobileSMS")
        XCTAssertFalse(store.contains("com.apple.MobileSMS"), "not in the zone after unpinning")
        XCTAssertTrue(store.isMessagingApp("com.apple.MobileSMS"), "but still a messaging app, the red badge is still drawn")
    }

    func testUnknownAppIsNotMessagingApp() {
        let store = makeStore([])
        XCTAssertFalse(store.isMessagingApp("com.example.nothing"))
        XCTAssertFalse(store.isMessagingApp(""))
    }
}
