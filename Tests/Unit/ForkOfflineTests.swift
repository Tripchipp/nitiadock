import XCTest

/// NitiaDock makes no network requests apart from the Sparkle update check.
final class ForkOfflineTests: XCTestCase {
    func testUpdatesUseNitiaDocksOwnFeedAndKey() throws {
        XCTAssertTrue(ForkDefaults.updatesEnabled)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = try XCTUnwrap(NSDictionary(contentsOf: root.appendingPathComponent("Resources/Info.plist")))
        let feed = try XCTUnwrap(plist["SUFeedURL"] as? String)
        XCTAssertTrue(feed.hasPrefix("https://raw.githubusercontent.com/Tripchipp/nitiadock/"), feed)
        XCTAssertNotEqual(plist["SUPublicEDKey"] as? String, "oOwdzOmmoDnopf5WceY+Ts8l3fEFK2zr3aFKc76uFuc=", "upstream's key")
        XCTAssertNil(plist["SUEnableAutomaticChecks"], "automatic checks must stay opt-in (Sparkle asks)")
    }

    /// Tripwire: the app's only network code is the Sparkle updater. A new file that reaches for a
    /// network API fails here, so it gets looked at instead of quietly shipping traffic.
    func testNoNetworkCodeOutsideTheUpdater() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let known: Set<String> = [
            "App/Composition/SparkleUpdateService.swift",
        ]
        let pattern = try NSRegularExpression(
            pattern: #"URLSession|NSURLConnection|NWConnection|NWListener|CFSocket|CFStream|CFNetwork|CFHTTP"#
                + #"|import Network|import Sparkle|<Network/|WKWebView|SPUUpdater|getaddrinfo|\bsocket\(|\bconnect\("#
                + #"|contentsOf:\s*URL\(string|/usr/bin/curl|/usr/bin/nc\b|/usr/bin/ssh\b"#
        )
        let sourceExtensions: Set<String> = ["swift", "m", "mm", "h", "c"]
        var offenders: [String] = []
        for directory in ["App", "Core", "Platform", "UI"] {
            let base = root.appendingPathComponent(directory)
            guard let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in files where sourceExtensions.contains(file.pathExtension) {
                let relative = String(file.path.dropFirst(root.path.count + 1))
                guard !known.contains(relative) else { continue }
                let code = try String(contentsOf: file, encoding: .utf8)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }   // comments may mention them
                    .joined(separator: "\n")
                if pattern.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                    offenders.append(relative)
                }
            }
        }
        XCTAssertEqual(offenders.sorted(), [], "network API used outside SparkleUpdateService")
    }
}
