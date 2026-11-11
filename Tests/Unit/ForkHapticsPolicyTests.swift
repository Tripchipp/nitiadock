import XCTest

/// fork: `ForkHapticsPolicy` and the haptic setting.
@MainActor
final class ForkHapticsPolicyTests: XCTestCase {
    func testTapsOnAppAndWindowChipsOnly() {
        XCTAssertTrue(ForkHapticsPolicy.tapsOnHover(ofChipID: "tabgrp-44803-s7"))   // a window card
        XCTAssertTrue(ForkHapticsPolicy.tapsOnHover(ofChipID: "cgw-24635"))
        XCTAssertTrue(ForkHapticsPolicy.tapsOnHover(ofChipID: "app-com.apple.finder"))   // kept / app-level icon
        XCTAssertTrue(ForkHapticsPolicy.tapsOnHover(ofChipID: "msg-app-com.microsoft.teams2"))
        XCTAssertFalse(ForkHapticsPolicy.tapsOnHover(ofChipID: "shelf"))
        XCTAssertFalse(ForkHapticsPolicy.tapsOnHover(ofChipID: "trash"))
        XCTAssertFalse(ForkHapticsPolicy.tapsOnHover(ofChipID: "folder-/Users/x/Downloads"))
        XCTAssertFalse(ForkHapticsPolicy.tapsOnHover(ofChipID: "extghost-com.apple.Safari"))
        XCTAssertFalse(ForkHapticsPolicy.tapsOnHover(ofChipID: "zone-divider-0"))
        XCTAssertFalse(ForkHapticsPolicy.tapsOnHover(ofChipID: ""))
    }

    func testSettingIsOffByDefaultAndPersists() {
        let suite = "ForkHapticsPolicyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppSettingsStore(defaults: defaults)
        XCTAssertFalse(store.hapticFeedback)
        store.setHapticFeedback(true)
        XCTAssertTrue(AppSettingsStore(defaults: defaults).hapticFeedback)
        store.setHapticFeedback(false)
        XCTAssertFalse(AppSettingsStore(defaults: defaults).hapticFeedback)
    }
}
