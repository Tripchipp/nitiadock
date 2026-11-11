import CoreGraphics
import XCTest

/// fork: the hideable drawer (`AppSettingsStore.showDrawer`).
@MainActor
final class ForkHideDrawerTests: XCTestCase {
    func testShowDrawerStartsAtForkDefaultAndPersists() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(store.showDrawer, ForkDefaults.showDrawer)

        store.setShowDrawer(!ForkDefaults.showDrawer)
        XCTAssertEqual(AppSettingsStore(defaults: defaults).showDrawer, !ForkDefaults.showDrawer)
    }

    func testShowDrawerIsIndependentOfShowShelf() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        store.setShowDrawer(true)
        store.setShowShelf(false)
        let reloaded = AppSettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.showDrawer)
        XCTAssertFalse(reloaded.showShelf)
    }

    func testDisabledDrawerStoreLooksEmptyButKeepsTheStoredList() {
        let defaults = makeDefaults()
        let drawer = DrawerStore(defaults: defaults)
        drawer.add("com.example.a")
        drawer.add("com.example.b")

        drawer.setEnabled(false)
        XCTAssertEqual(drawer.bundleIDs, [])
        XCTAssertFalse(drawer.contains("com.example.a"))
        XCTAssertEqual(defaults.stringArray(forKey: "drawerBundleIDs"), ["com.example.a", "com.example.b"],
                       "hiding the drawer must not rewrite what is on disk")

        drawer.setEnabled(true)
        XCTAssertEqual(drawer.bundleIDs, ["com.example.a", "com.example.b"])
    }

    func testDisabledDrawerStoreIgnoresWrites() {
        let defaults = makeDefaults()
        let drawer = DrawerStore(defaults: defaults)
        drawer.add("com.example.a")
        drawer.setEnabled(false)

        drawer.add("com.example.b")
        drawer.remove("com.example.a")

        drawer.setEnabled(true)
        XCTAssertEqual(drawer.bundleIDs, ["com.example.a"])
        XCTAssertEqual(DrawerStore(defaults: defaults).bundleIDs, ["com.example.a"])
    }

    func testStripStaysCentredAndGainsTheCapsuleReserveWhenDrawerIsHidden() {
        let metrics = PanelLayoutMetrics.standard
        let screen = PanelScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949),
            safeAreaTop: 0
        )

        // Content that fits: identical frame either way.
        let fitsWith = PanelGeometry.dockTargetFrame(contentWidth: 620, on: screen, metrics: metrics)
        let fitsWithout = PanelGeometry.dockTargetFrame(contentWidth: 620, on: screen, metrics: metrics,
                                                        reservesCapsule: false)
        XCTAssertEqual(fitsWith, fitsWithout)
        XCTAssertEqual(fitsWithout.midX, screen.frame.midX)

        // Content wider than the screen: the cap grows by the reserve on both sides, still centred.
        let wideWith = PanelGeometry.dockTargetFrame(contentWidth: 5000, on: screen, metrics: metrics)
        let wideWithout = PanelGeometry.dockTargetFrame(contentWidth: 5000, on: screen, metrics: metrics,
                                                        reservesCapsule: false)
        XCTAssertEqual(wideWithout.width - wideWith.width, 2 * (metrics.capsuleGap + metrics.capsuleWidth))
        XCTAssertEqual(wideWithout.midX, screen.frame.midX)
        XCTAssertEqual(wideWithout.width - 2 * metrics.shadowPadding, screen.frame.width - 2 * metrics.outerMargin)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "com.tungsten.edge.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
