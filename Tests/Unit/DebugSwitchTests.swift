import XCTest

/// Polarity lock for `DebugSwitch`: the `!= "0"` / `== "1"` semantics
/// of each call site before the migration must be kept verbatim.
final class DebugSwitchTests: XCTestCase {
    func testKillSwitchIsOnUnlessExplicitlyZero() {
        let s = DebugSwitch.eventAxAsync
        XCTAssertEqual(s.kind, .killSwitch)
        XCTAssertTrue(s.isEnabled(in: [:]))
        XCTAssertTrue(s.isEnabled(in: [s.rawValue: "1"]))
        XCTAssertTrue(s.isEnabled(in: [s.rawValue: "false"]), "only the literal \"0\" turns it off, same as before the migration")
        XCTAssertFalse(s.isEnabled(in: [s.rawValue: "0"]))
    }

    func testTraceIsOffUnlessExplicitlyOne() {
        let s = DebugSwitch.hoverTrace
        XCTAssertEqual(s.kind, .trace)
        XCTAssertFalse(s.isEnabled(in: [:]))
        XCTAssertFalse(s.isEnabled(in: [s.rawValue: "true"]), "only the literal \"1\" turns it on, same as before the migration")
        XCTAssertTrue(s.isEnabled(in: [s.rawValue: "1"]))
    }

    func testValueReturnsRawStringOrNil() {
        let s = DebugSwitch.reconcileAxTimeoutMs
        XCTAssertEqual(s.kind, .value)
        XCTAssertNil(s.value(in: [:]))
        XCTAssertEqual(s.value(in: [s.rawValue: " 250 "]), " 250 ")
    }

    func testEveryCaseHasDockPrefixAndUniqueRawValue() {
        let raws = DebugSwitch.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, raws.count)
        for raw in raws { XCTAssertTrue(raw.hasPrefix("DOCK_"), raw) }
    }
}
