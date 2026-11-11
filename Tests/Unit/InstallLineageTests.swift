import XCTest
@testable import NitiaDock

final class InstallLineageTests: XCTestCase {
    func testMissingDomainIsPristine() {
        XCTAssertEqual(InstallLineage.classify(persistentDomain: nil), .pristine)
    }

    func testEmptyDomainIsPristine() {
        XCTAssertEqual(InstallLineage.classify(persistentDomain: [:]), .pristine)
    }

    func testAnyExistingKeyIsPriorUse() {
        XCTAssertEqual(InstallLineage.classify(persistentDomain: ["existing": true]), .priorUse)
    }

    func testVersion075DefaultDomainIsPriorUse() {
        let domain: [String: Any] = [
            "com.tungsten.edge.dockSize": "medium",
            "com.tungsten.edge.hoverStyle": "standard",
            "com.tungsten.edge.autoHide.nativeDock.delay": 1.0,
            "com.tungsten.edge.autoHide.nativeDock.lastEnabledDelay": 1.0,
            "com.tungsten.edge.autoHide.edge.delay": 0.1,
            "com.tungsten.edge.autoHide.edge.lastEnabledDelay": 0.1,
            "keptAppBundleIDsV3": [String](),
            "messagingBundleIDsV2": [String](),
            "messagingOptOutBundleIDsV2": [String](),
        ]

        XCTAssertEqual(InstallLineage.classify(persistentDomain: domain), .priorUse)
    }

    func testMissingBundleIdentifierFailsClosed() {
        XCTAssertEqual(InstallLineage.capture(bundleID: nil), .priorUse)
        XCTAssertEqual(InstallLineage.capture(bundleID: ""), .priorUse)
    }
}
