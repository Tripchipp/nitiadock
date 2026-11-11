import XCTest
@testable import NitiaDock

/// Invariant lock for the three membership stores (kept / drawer / messaging) after running all public
/// mutations:
/// - Finder is never in the messaging zone;
/// - messaging identity and opt-out never hold at once;
/// - the three tables have no blanks and no duplicates;
/// - the UserDefaults domain contains only current keys + frozen legacy keys, and the frozen legacy keys
///   are byte-identical (a code rollback still reads the same data).
@MainActor
final class AppMembershipInvariantTests: XCTestCase {
    private static let liveKeys: Set<String> = [
        "keptAppBundleIDsV3", "keptAppFinderSeededV1",
        "messagingBundleIDsV2", "messagingOptOutBundleIDsV2",
        "drawerBundleIDs",
    ]
    private static let frozenSeed: [String: [String]] = [
        "keptAppBundleIDsV2": ["com.legacy.v2"],
        "keptAppBundleIDs": ["com.legacy.v1"],
        "pinnedAppBundleIDs": ["com.legacy.pinned"],
        "messagingBundleIDs": ["com.legacy.messaging"],
        "messagingOptOutBundleIDs": ["com.legacy.optout"],
    ]

    private var suite = ""
    private var defaults: UserDefaults!
    private var kept: KeptAppStore!
    private var drawer: DrawerStore!
    private var messaging: MessagingAppStore!
    private var controller: AppMembershipController!

    override func setUp() {
        super.setUp()
        suite = "test-membership-invariants-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        for (key, value) in Self.frozenSeed { defaults.set(value, forKey: key) }
        kept = KeptAppStore(defaults: defaults)
        drawer = DrawerStore(defaults: defaults)
        messaging = MessagingAppStore(defaults: defaults)
        controller = AppMembershipController(keptAppStore: kept, drawerStore: drawer, messagingStore: messaging)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func assertInvariants(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
        let finder = FinderTaskbarPolicy.bundleID
        XCTAssertFalse(messaging.contains(finder), "[\(step)] Finder is in the messaging zone", file: file, line: line)
        let optOut = Set(defaults.stringArray(forKey: "messagingOptOutBundleIDsV2") ?? [])
        XCTAssertTrue(optOut.isDisjoint(with: messaging.bundleIDs), "[\(step)] messaging identity and opt-out both hold", file: file, line: line)
        for (name, list) in [("kept", kept.bundleIDs), ("drawer", drawer.bundleIDs), ("messaging", messaging.bundleIDs)] {
            XCTAssertEqual(Set(list).count, list.count, "[\(step)] \(name) has duplicates", file: file, line: line)
            XCTAssertFalse(list.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, "[\(step)] \(name) has blanks", file: file, line: line)
        }
        let keys = Set(defaults.persistentDomain(forName: suite)?.keys.map { $0 } ?? [])
        let allowed = Self.liveKeys.union(Self.frozenSeed.keys)
        XCTAssertTrue(keys.isSubset(of: allowed), "[\(step)] unregistered keys found: \(keys.subtracting(allowed))", file: file, line: line)
        for (key, value) in Self.frozenSeed {
            XCTAssertEqual(defaults.stringArray(forKey: key), value, "[\(step)] frozen legacy key was rewritten: \(key)", file: file, line: line)
        }
    }

    func testEveryPublicMutationKeepsTheInvariants() {
        assertInvariants("init")
        controller.setKept("com.example.a", enabled: true); assertInvariants("setKept on")
        controller.setKept("  ", enabled: true); assertInvariants("setKept blank")
        controller.setKept("com.example.a", enabled: true); assertInvariants("setKept twice")
        controller.moveToDrawer("com.example.a"); assertInvariants("moveToDrawer")
        controller.moveToDrawer("com.example.a"); assertInvariants("moveToDrawer twice")
        controller.applyDragLanding(bundleID: "com.example.b", originSource: .strip); assertInvariants("landing not in drawer")
        drawer.add("com.example.b")
        controller.applyDragLanding(bundleID: "com.example.b", originSource: .strip); assertInvariants("landing in drawer")
        controller.markMessaging("com.example.c"); assertInvariants("markMessaging")
        controller.markMessaging("com.example.c"); assertInvariants("markMessaging twice")
        controller.markMessaging(FinderTaskbarPolicy.bundleID); assertInvariants("markMessaging finder (rejected)")
        messaging.reorder(draggedID: "com.example.c", relativeTo: "com.example.c", after: true); assertInvariants("reorder self")
        controller.unmarkMessaging("com.example.c"); assertInvariants("unmarkMessaging")
        controller.autoRegisterMessaging(runningBundleIDs: ["com.example.c", "Mattermost.Desktop"],
                                         mainWindowIdentifiableBundleIDs: ["com.example.c", "Mattermost.Desktop"])
        assertInvariants("autoRegister")
        XCTAssertFalse(messaging.contains("com.example.c"), "after opt-out, auto-registration must not add it back")
        controller.setKept("com.example.a", enabled: false); assertInvariants("setKept off")
        drawer.remove("com.example.a"); assertInvariants("drawer remove")
        controller.reconcileInvalidMemberships(); assertInvariants("reconcile")
        XCTAssertTrue(kept.contains("com.example.b"))
    }

    func testFinderInMessagingIsRepairedOnStartup() {
        // Simulated bad data: a Finder messaging identity written by an old version.
        defaults.set([FinderTaskbarPolicy.bundleID, "com.example.c"], forKey: "messagingBundleIDsV2")
        let messaging = MessagingAppStore(defaults: defaults)
        let controller = AppMembershipController(keptAppStore: kept, drawerStore: drawer, messagingStore: messaging)
        XCTAssertTrue(messaging.contains(FinderTaskbarPolicy.bundleID))
        controller.reconcileInvalidMemberships()
        XCTAssertFalse(messaging.contains(FinderTaskbarPolicy.bundleID))
        XCTAssertTrue(messaging.contains("com.example.c"), "the repair clears only Finder and leaves others alone")
    }
}
