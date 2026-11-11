import XCTest

final class TaskbarDisplaySetTests: XCTestCase {
    func testDiffKeepsCurrentOrderForAddedAndKept() {
        let diff = TaskbarDisplaySet.diff(previous: ["A", "B", "C"], current: ["C", "D", "A"])
        XCTAssertEqual(diff.added, ["D"])
        XCTAssertEqual(diff.removed, ["B"])
        XCTAssertEqual(diff.kept, ["C", "A"])
    }

    func testDiffEmptyToSomething() {
        let diff = TaskbarDisplaySet.diff(previous: [], current: ["A"])
        XCTAssertEqual(diff, TaskbarDisplaySet.Diff(added: ["A"], removed: [], kept: []))
    }

    func testDesiredUnitKeysSingleUnitForFollowMouseAndPinned() {
        XCTAssertEqual(TaskbarDisplaySet.desiredUnitKeys(placement: .followMouse, connectedKeys: ["A", "B"]), [nil])
        let pinned = TaskbarScreenPlacement.pinned(PinnedScreenSelection(uuid: "B", name: "LG"))
        XCTAssertEqual(TaskbarDisplaySet.desiredUnitKeys(placement: pinned, connectedKeys: ["A", "B"]), [nil])
    }

    func testDesiredUnitKeysOnePerDisplayForAllScreensModes() {
        XCTAssertEqual(TaskbarDisplaySet.desiredUnitKeys(placement: .allScreens, connectedKeys: ["A", "B"]), ["A", "B"])
        XCTAssertEqual(
            TaskbarDisplaySet.desiredUnitKeys(placement: .allScreensPerDisplay, connectedKeys: ["B"]),
            ["B"]
        )
    }

    /// An empty screen set (all unplugged / no UUID readable) degrades to a single unit; the taskbar does not
    /// vanish.
    func testDesiredUnitKeysFallsBackToSingleUnitWhenNoDisplays() {
        XCTAssertEqual(TaskbarDisplaySet.desiredUnitKeys(placement: .allScreens, connectedKeys: []), [nil])
    }
}
