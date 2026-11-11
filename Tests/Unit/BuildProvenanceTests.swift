import XCTest
@testable import NitiaDock

final class BuildProvenanceTests: XCTestCase {
    func testInstalledReleaseBuildGetsNoSuffix() {
        XCTAssertNil(BuildProvenance.suffix(
            isDebugBuild: false,
            bundlePath: "/Applications/NitiaDock.app"
        ))
    }

    func testDebugBuildIsMarkedRegardlessOfLocation() {
        // Incident scene: the login item was pinned to
        // DerivedData, so this is the bundle that came up at boot.
        XCTAssertEqual(BuildProvenance.suffix(
            isDebugBuild: true,
            bundlePath: "/Users/dev/Projects/NitiaDock/build/DerivedData/Build/Products/Debug/NitiaDock.app"
        ), String(localized: "Debug Build"))
        // A dev build is still a dev build even when copied into /Applications:
        // the Debug check takes priority over the location check.
        XCTAssertEqual(BuildProvenance.suffix(
            isDebugBuild: true,
            bundlePath: "/Applications/NitiaDock.app"
        ), String(localized: "Debug Build"))
    }

    func testReleaseBuildOutsideApplicationsIsMarked() {
        XCTAssertEqual(BuildProvenance.suffix(
            isDebugBuild: false,
            bundlePath: "/Users/dev/Projects/NitiaDock/build/ReleaseDD/Build/Products/Release/NitiaDock.app"
        ), String(localized: "Not Installed"))
        // The rollback backup bundle is also outside /Applications and must be recognized too.
        XCTAssertEqual(BuildProvenance.suffix(
            isDebugBuild: false,
            bundlePath: "/Users/dev/Projects/nitiadock-rebuild-artifacts/2026-07-25-stage4/rollback/NitiaDock.app"
        ), String(localized: "Not Installed"))
    }

    func testInstalledPrefixRequiresTrailingSlashSoLookalikePathsAreNotInstalled() {
        // Without the trailing slash this path would be misjudged as the installed location.
        XCTAssertEqual(BuildProvenance.suffix(
            isDebugBuild: false,
            bundlePath: "/ApplicationsOld/NitiaDock.app"
        ), String(localized: "Not Installed"))
    }

    func testVersionTitleAppendsSuffixWithSeparator() {
        XCTAssertEqual(BuildProvenance.versionTitle(
            version: "0.7.0",
            build: "8",
            isDebugBuild: true,
            bundlePath: "/anywhere/NitiaDock.app"
        ), String(format: String(localized: "Version %@ (%@)"), "0.7.0", "8") + " · " + String(localized: "Debug Build"))

        XCTAssertEqual(BuildProvenance.versionTitle(
            version: "0.7.0",
            build: "8",
            isDebugBuild: false,
            bundlePath: "/Applications/NitiaDock.app"
        ), String(format: String(localized: "Version %@ (%@)"), "0.7.0", "8"))
    }

    func testVersionTitleDegradesExactlyLikeTheOldImplementation() {
        let installed = "/Applications/NitiaDock.app"
        XCTAssertEqual(BuildProvenance.versionTitle(
            version: "0.7.0", build: nil, isDebugBuild: false, bundlePath: installed
        ), String(format: String(localized: "Version %@"), "0.7.0"))
        XCTAssertEqual(BuildProvenance.versionTitle(
            version: nil, build: "8", isDebugBuild: false, bundlePath: installed
        ), String(format: String(localized: "Version (%@)"), "8"))
        XCTAssertNil(BuildProvenance.versionTitle(
            version: nil, build: nil, isDebugBuild: false, bundlePath: installed
        ))
    }

    func testSuffixStillAppendsWhenOnlyOneOfVersionOrBuildIsPresent() {
        XCTAssertEqual(BuildProvenance.versionTitle(
            version: "0.7.0", build: nil, isDebugBuild: true, bundlePath: "/tmp/x.app"
        ), String(format: String(localized: "Version %@"), "0.7.0") + " · " + String(localized: "Debug Build"))
        // With both missing the whole row is hidden, and the suffix must not conjure a row out of nothing.
        XCTAssertNil(BuildProvenance.versionTitle(
            version: nil, build: nil, isDebugBuild: true, bundlePath: "/tmp/x.app"
        ))
    }
}
