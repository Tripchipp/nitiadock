import XCTest
@testable import NitiaDock

/// Name side of the messaging zone absorption criterion "window title == app name".
///
/// These tests exist because of a real-device bug (2026-08-11): app names used to be queried from
/// LaunchServices every frame, and one transient empty result dropped Feishu and WeChat out of absorption
/// **at the same time**. Each app then rendered a card in both the messaging zone and the live zone, the
/// whole row widened and pushed the right side away, and the mismatch stuck until the next unrelated reorder.
/// QQ was never affected because its bundle-derived names already include `qq`; that asymmetry was the
/// evidence that located the root cause.
final class AppNameRegistryTests: XCTestCase {

    /// Controllable dual loader: the bundle names are fixed, the running name can glitch at any time.
    private final class Env {
        var bundleNames: [String: Set<String>] = [:]
        var runningNames: [String: String] = [:]
        private(set) var bundleLoadCount = 0
        private(set) var runningLoadCount = 0

        func makeRegistry() -> AppNameRegistry {
            AppNameRegistry(
                bundleNamesLoader: { [unowned self] bid in
                    self.bundleLoadCount += 1
                    return self.bundleNames[bid] ?? []
                },
                runningNameLoader: { [unowned self] bid in
                    self.runningLoadCount += 1
                    return self.runningNames[bid]
                }
            )
        }
    }

    // MARK: - Product aliases (2026-08-23)

    /// WeChat's main window is titled `Weixin` in the English UI: the bundle names only have wechat and the
    /// running name is the Chinese name, none of which equal it. The alias table must apply on **both**
    /// entry-creation paths (matches first / observe first).
    func testProductAliasMatchesWeixinTitle() {
        let env = Env()
        env.bundleNames["com.tencent.xinWeChat"] = ["wechat"]
        env.runningNames["com.tencent.xinWeChat"] = "微信"
        let registry = env.makeRegistry()
        XCTAssertTrue(registry.matches(title: "Weixin", bundleID: "com.tencent.xinWeChat"))
        XCTAssertTrue(registry.matches(title: " weixin ", bundleID: "com.tencent.xinWeChat"), "aliases are normalized too")
        XCTAssertTrue(registry.matches(title: "微信", bundleID: "com.tencent.xinWeChat"), "aliases are additive, existing names are unaffected")

        let observedFirst = env.makeRegistry()
        observedFirst.observe(name: "微信", for: "com.tencent.xinWeChat")
        XCTAssertTrue(observedFirst.matches(title: "Weixin", bundleID: "com.tencent.xinWeChat"))
    }

    func testProductAliasIsScopedToItsBundle() {
        let env = Env()
        env.bundleNames["com.electron.lark"] = ["feishu", "lark"]
        XCTAssertFalse(env.makeRegistry().matches(title: "Weixin", bundleID: "com.electron.lark"))
    }

    // MARK: - Regression lock for this bug

    /// Once a running name has been observed successfully, matching must continue however much LaunchServices
    /// glitches. If this fails, the duplicate Feishu/WeChat card bug is back.
    func testObservedNameSurvivesLaterLookupFailure() {
        let env = Env()
        env.bundleNames["com.electron.lark"] = ["feishu", "lark"]   // measured: the Chinese name is not in the bundle
        env.runningNames["com.electron.lark"] = "飞书"
        let registry = env.makeRegistry()

        XCTAssertTrue(registry.matches(title: "飞书", bundleID: "com.electron.lark"))

        // LaunchServices glitches: the query starts returning nil.
        env.runningNames.removeValue(forKey: "com.electron.lark")

        XCTAssertTrue(registry.matches(title: "飞书", bundleID: "com.electron.lark"),
                      "a remembered name must not be dropped because of one failed query")
    }

    /// After a successful observation there are no more queries: part of the fix, and the basis for zero
    /// LaunchServices I/O per frame.
    func testRunningLookupStopsAfterFirstSuccess() {
        let env = Env()
        env.bundleNames["com.tencent.xinWeChat"] = ["wechat"]
        env.runningNames["com.tencent.xinWeChat"] = "微信"
        let registry = env.makeRegistry()

        for _ in 0..<5 {
            XCTAssertTrue(registry.matches(title: "微信", bundleID: "com.tencent.xinWeChat"))
        }
        XCTAssertEqual(env.runningLoadCount, 1)
        XCTAssertEqual(env.bundleLoadCount, 1, "bundle names are read from disk only once too")
    }

    // MARK: - Self-healing: a partial set must not be treated as a complete cache

    /// If the first frame of a cold start happens to glitch, the partial "bundle names only" set must not be
    /// pinned forever: that would turn a transient failure into a permanent one, worse than before the fix.
    /// Retry every time until an observation succeeds.
    func testKeepsRetryingUntilFirstSuccessfulObservation() {
        let env = Env()
        env.bundleNames["com.electron.lark"] = ["feishu", "lark"]
        let registry = env.makeRegistry()

        XCTAssertFalse(registry.matches(title: "飞书", bundleID: "com.electron.lark"))
        XCTAssertFalse(registry.matches(title: "飞书", bundleID: "com.electron.lark"))
        XCTAssertEqual(env.runningLoadCount, 2, "must keep retrying until an observation succeeds")

        env.runningNames["com.electron.lark"] = "飞书"
        XCTAssertTrue(registry.matches(title: "飞书", bundleID: "com.electron.lark"))
    }

    /// An empty / whitespace-only running name does not count as a successful observation, otherwise it would
    /// block the retry path.
    func testBlankRunningNameDoesNotCountAsObserved() {
        let env = Env()
        env.bundleNames["com.electron.lark"] = ["lark"]
        env.runningNames["com.electron.lark"] = "   "
        let registry = env.makeRegistry()

        XCTAssertFalse(registry.matches(title: "飞书", bundleID: "com.electron.lark"))
        env.runningNames["com.electron.lark"] = "飞书"
        XCTAssertTrue(registry.matches(title: "飞书", bundleID: "com.electron.lark"))
    }

    // MARK: - The independent bundle-derived name path (why QQ never mismatches)

    func testBundleDerivedNameMatchesWithoutAnySuccessfulLookup() {
        let env = Env()
        env.bundleNames["com.tencent.qq"] = ["qq"]     // the running name can never be found
        let registry = env.makeRegistry()

        XCTAssertTrue(registry.matches(title: "QQ", bundleID: "com.tencent.qq"))
    }

    // MARK: - Direct external feed (names that come free with NSWorkspace launch notifications)

    func testObserveSeedsBothBundleAndRunningNamesWithoutLookup() {
        let env = Env()
        env.bundleNames["com.electron.lark"] = ["feishu", "lark"]
        let registry = env.makeRegistry()

        registry.observe(name: "飞书", for: "com.electron.lark")

        XCTAssertEqual(registry.knownNames(for: "com.electron.lark"), ["feishu", "lark", "飞书"],
                       "feeding must bring the bundle names along, otherwise they can never be filled in later")
        XCTAssertEqual(env.runningLoadCount, 0, "an authoritative name already exists, no further query")
    }

    func testObserveIsMonotonic() {
        let env = Env()
        env.bundleNames["com.foo.bar"] = []
        let registry = env.makeRegistry()

        registry.observe(name: "Foo", for: "com.foo.bar")
        registry.observe(name: "福", for: "com.foo.bar")

        XCTAssertEqual(registry.knownNames(for: "com.foo.bar"), ["foo", "福"])
    }

    func testObserveIgnoresBlankName() {
        let env = Env()
        env.bundleNames["com.foo.bar"] = ["bar"]
        env.runningNames["com.foo.bar"] = "Bar"
        let registry = env.makeRegistry()

        registry.observe(name: "  ", for: "com.foo.bar")
        // An empty feed must not count as a successful observation, otherwise the real name could never be
        // filled in.
        XCTAssertTrue(registry.matches(title: "Bar", bundleID: "com.foo.bar"))
    }

    // MARK: - Invalidation

    func testInvalidateClearsEverythingAndRelearns() {
        let env = Env()
        env.bundleNames["com.electron.lark"] = ["lark"]
        env.runningNames["com.electron.lark"] = "飞书"
        let registry = env.makeRegistry()
        XCTAssertTrue(registry.matches(title: "飞书", bundleID: "com.electron.lark"))

        // The app changed version and its name changed too.
        registry.invalidate(bundleID: "com.electron.lark")
        env.runningNames["com.electron.lark"] = "Lark"

        XCTAssertEqual(registry.knownNames(for: "com.electron.lark"), ["lark"])
        XCTAssertFalse(registry.matches(title: "飞书", bundleID: "com.electron.lark"))
    }

    // MARK: - Normalization and empty titles

    func testEmptyOrBlankTitleNeverMatches() {
        let env = Env()
        env.bundleNames["com.foo.bar"] = ["bar", ""]
        let registry = env.makeRegistry()

        XCTAssertFalse(registry.matches(title: "", bundleID: "com.foo.bar"))
        XCTAssertFalse(registry.matches(title: "   \n ", bundleID: "com.foo.bar"))
    }

    func testMatchingTrimsAndLowercases() {
        let env = Env()
        env.bundleNames["com.foo.bar"] = []
        env.runningNames["com.foo.bar"] = "  MyApp  "
        let registry = env.makeRegistry()

        XCTAssertTrue(registry.matches(title: "myapp", bundleID: "com.foo.bar"))
        XCTAssertTrue(registry.matches(title: " MYAPP ", bundleID: "com.foo.bar"))
        XCTAssertFalse(registry.matches(title: "my app", bundleID: "com.foo.bar"))
    }

    func testUnknownBundleMatchesNothing() {
        let env = Env()
        let registry = env.makeRegistry()
        XCTAssertFalse(registry.matches(title: "Whatever", bundleID: "com.unknown"))
    }
}
