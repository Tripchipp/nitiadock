import XCTest

/// fork: Settings > Advanced > "Multiple displays" (`ForkMultiDisplayChoice`).
@MainActor
final class ForkMultiDisplayChoiceTests: XCTestCase {
    private let pinned = TaskbarScreenPlacement.pinned(PinnedScreenSelection(uuid: "U-1", name: "Studio"))

    func testEveryPlacementMapsToOneChoice() {
        XCTAssertEqual(ForkMultiDisplayChoice(placement: .allScreensPerDisplay), .eachDisplayOwnApps)
        XCTAssertEqual(ForkMultiDisplayChoice(placement: .allScreens), .sameOnEveryDisplay)
        XCTAssertEqual(ForkMultiDisplayChoice(placement: .followMouse), .singleBar)
        XCTAssertEqual(ForkMultiDisplayChoice(placement: pinned), .singleBar)
    }

    func testPickingAMultiDisplayChoiceSetsThatPlacement() {
        for current in [TaskbarScreenPlacement.followMouse, pinned, .allScreens, .allScreensPerDisplay] {
            XCTAssertEqual(ForkMultiDisplayChoice.eachDisplayOwnApps.placement(replacing: current), .allScreensPerDisplay)
            XCTAssertEqual(ForkMultiDisplayChoice.sameOnEveryDisplay.placement(replacing: current), .allScreens)
        }
    }

    func testPickingSingleBarFallsBackToFollowMouse() {
        XCTAssertEqual(ForkMultiDisplayChoice.singleBar.placement(replacing: .allScreens), .followMouse)
        XCTAssertEqual(ForkMultiDisplayChoice.singleBar.placement(replacing: .allScreensPerDisplay), .followMouse)
    }

    func testPickingSingleBarWhileSingleKeepsThePinnedDisplay() {
        XCTAssertEqual(ForkMultiDisplayChoice.singleBar.placement(replacing: pinned), pinned)
        XCTAssertEqual(ForkMultiDisplayChoice.singleBar.placement(replacing: .followMouse), .followMouse)
    }

    func testStoreRoundTripKeepsTheChoice() {
        let suite = "ForkMultiDisplayChoiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppSettingsStore(defaults: defaults)

        store.setTaskbarScreenPlacement(ForkMultiDisplayChoice.sameOnEveryDisplay.placement(replacing: store.taskbarScreenPlacement))
        XCTAssertEqual(ForkMultiDisplayChoice(placement: AppSettingsStore(defaults: defaults).taskbarScreenPlacement), .sameOnEveryDisplay)

        store.setTaskbarScreenPlacement(ForkMultiDisplayChoice.eachDisplayOwnApps.placement(replacing: store.taskbarScreenPlacement))
        XCTAssertEqual(ForkMultiDisplayChoice(placement: AppSettingsStore(defaults: defaults).taskbarScreenPlacement), .eachDisplayOwnApps)
    }
}
