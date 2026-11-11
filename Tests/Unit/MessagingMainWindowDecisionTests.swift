import XCTest
@testable import NitiaDock

/// The three rules for identifying the main window in the messaging zone (2026-08-23). Each maps to a real
/// app's shape, do not delete.
final class MessagingMainWindowDecisionTests: XCTestCase {
    private typealias W = MessagingMainWindowDecision.WindowFact
    private let wechat = "com.tencent.xinWeChat"
    private let telegram = "ru.keepcoder.Telegram"

    /// Rule 1: a title match wins even with other windows present (Feishu main window + standalone chat
    /// window).
    func testTitleMatchWinsOverEverything() {
        let id = MessagingMainWindowDecision.mainWindowID(
            bundleID: "com.electron.lark",
            windows: [W(id: "chat", title: "张三"), W(id: "main", title: "飞书")],
            titleMatchesAppName: { $0 == "飞书" }
        )
        XCTAssertEqual(id, "main")
    }

    /// WeChat cold-start shape (measured 2026-08-23): the login window (700×640, its seat remains after
    /// order-out) and the main window are both titled "WeChat", and the login window is created first. Must
    /// pick the main window, not the first one by creation order.
    func testAmongSeveralTitleMatchesTheLargestVisibleWins() {
        let id = MessagingMainWindowDecision.mainWindowID(
            bundleID: wechat,
            windows: [W(id: "login", title: "微信", area: 700 * 640),
                      W(id: "main", title: "微信", area: 1220 * 870)],
            titleMatchesAppName: { $0 == "微信" }
        )
        XCTAssertEqual(id, "main")
    }

    /// The main window is minimized and the login window is not: still must not bind the icon to the login
    /// window? No, the minimized main window yields to the non-minimized one: among same-titled windows "not
    /// minimized" beats "area", otherwise clicking the icon "restores" a window that is never visible.
    func testNonMinimizedTitleMatchBeatsLargerMinimizedOne() {
        let id = MessagingMainWindowDecision.mainWindowID(
            bundleID: wechat,
            windows: [W(id: "big-minimized", title: "微信", isMinimized: true, area: 1220 * 870),
                      W(id: "small-visible", title: "微信", area: 700 * 640)],
            titleMatchesAppName: { $0 == "微信" }
        )
        XCTAssertEqual(id, "small-visible")
    }

    /// All equal: keep the first seen (stable, no flapping between the two).
    func testEqualTitleMatchesKeepFirst() {
        let id = MessagingMainWindowDecision.mainWindowID(
            bundleID: wechat,
            windows: [W(id: "a", title: "微信"), W(id: "b", title: "微信")],
            titleMatchesAppName: { $0 == "微信" }
        )
        XCTAssertEqual(id, "a")
    }

    /// Rule 2: a single-window app whose title is not the app name (the Telegram / Messages / Slack shape).
    func testSingleWindowIsMainEvenWithoutTitleMatch() {
        let id = MessagingMainWindowDecision.mainWindowID(
            bundleID: telegram,
            windows: [W(id: "only", title: "Saved Messages")],
            titleMatchesAppName: { _ in false }
        )
        XCTAssertEqual(id, "only")
    }

    /// Origin, 2026-07-21: WeChat's main window closed leaving only "Notes" → must be "no main window", so
    /// clicking the icon brings the main window back.
    func testWeChatNotesAloneIsNotMain() {
        let id = MessagingMainWindowDecision.mainWindowID(
            bundleID: wechat,
            windows: [W(id: "notes", title: "笔记")],
            titleMatchesAppName: { _ in false }
        )
        XCTAssertNil(id)
    }

    /// The exclusion list only removes: Notes + one window with an unrecognized name → the remaining one is
    /// the main window (WeChat when its alias fails).
    func testExclusionLeavesTheOtherWindowAsMain() {
        let id = MessagingMainWindowDecision.mainWindowID(
            bundleID: wechat,
            windows: [W(id: "notes", title: " 笔记 "), W(id: "main", title: "Weixin")],
            titleMatchesAppName: { _ in false }
        )
        XCTAssertEqual(id, "main", "the exclusion list compares normalized titles")
    }

    /// Rule 3: two or more, none recognized → nil; the caller uses the app-level toggle and does not guess.
    func testAmbiguousWindowsYieldNil() {
        let id = MessagingMainWindowDecision.mainWindowID(
            bundleID: "com.example.chat",
            windows: [W(id: "a", title: "Alice"), W(id: "b", title: "Bob")],
            titleMatchesAppName: { _ in false }
        )
        XCTAssertNil(id)
    }

    func testNoWindowsYieldNil() {
        XCTAssertNil(MessagingMainWindowDecision.mainWindowID(
            bundleID: telegram, windows: [], titleMatchesAppName: { _ in true }))
    }

    /// The exclusion list applies only to its own bundle: another app's only window titled "Notes" is still
    /// the main window.
    func testExclusionIsScopedToItsBundle() {
        let id = MessagingMainWindowDecision.mainWindowID(
            bundleID: "com.example.notesapp",
            windows: [W(id: "n", title: "笔记")],
            titleMatchesAppName: { _ in false }
        )
        XCTAssertEqual(id, "n")
    }
}
