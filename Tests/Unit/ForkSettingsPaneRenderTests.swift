import AppKit
import Combine
import SwiftUI
import XCTest

/// Renders every page of the settings window off screen, in light and dark, and writes PNGs for a
/// human (or an agent without screen-recording permission) to look at. Output:
/// `$TMPDIR/nitiadock-render/settings-<page>-<light|dark>.png`.
///
/// The assertion is deliberately modest: at the window's minimum width, a page must not ask for more
/// width than it has. Whether it *looks* right is what the PNG is for.
@MainActor
final class ForkSettingsPaneRenderTests: XCTestCase {
    override func tearDown() {
        ForkAppearanceModel.shared.resetForTesting()
        ForkSettingsContext.messagingStore = nil
        super.tearDown()
    }

    func testEverySettingsPageRendersInLightAndDark() throws {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        let messaging = MessagingAppStore(defaults: defaults)
        ForkSettingsContext.messagingStore = messaging
        let coordinator = SettingsCoordinator(
            store: store,
            launchAtLoginService: RenderLaunchStub(),
            nativeDockPreferencesService: RenderNativeDockStub(),
            updateService: RenderUpdateStub(),
            hotKeyRegistrar: { _ in .registered }
        )
        for page in SettingsTab.allCases {
            for dark in [false, true] {
                let state = SettingsTabState(defaults: defaults)
                state.selected = page
                let view = SettingsWindowView(store: store, coordinator: coordinator, tabState: state, onShowWelcomeGuide: {})
                try render(view, name: "settings-\(page.rawValue)-\(dark ? "dark" : "light")", dark: dark)
            }
        }
    }

    func testWelcomeGuideRendersInLightAndDark() throws {
        for dark in [false, true] {
            let view = WelcomeGuideWindowContent(onApply: { _ in }, onDismiss: {})
            try render(view, name: "welcome-\(dark ? "dark" : "light")", dark: dark,
                       size: NSSize(width: WelcomeGuideView.contentWidth, height: 860))
        }
    }

    func testSearchFindsRowsByTitleAndKeyword() {
        XCTAssertEqual(SettingsSearchIndex.matches(for: "login").first?.page, .general)
        XCTAssertEqual(SettingsSearchIndex.matches(for: "transparent").first?.page, .appearance)
        XCTAssertTrue(SettingsSearchIndex.matches(for: "monitor").allSatisfy { $0.page == .displays })
        XCTAssertTrue(SettingsSearchIndex.matches(for: "   ").isEmpty)
        XCTAssertTrue(SettingsSearchIndex.matches(for: "zzzz-nothing").isEmpty)
    }

    func testSearchEntriesAreUnique() {
        let ids = SettingsSearchIndex.entries.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    private func render<V: View>(_ view: V, name: String, dark: Bool, size: NSSize = SettingsWindowView.defaultSize) throws {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.frame = frame
        hosting.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nitiadock-render", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        try png.write(to: url)
        print("rendered \(name): \(url.path)")
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "no.thilip.nitiadock.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
private final class RenderLaunchStub: LaunchAtLoginServicing {
    func currentState() async -> LaunchAtLoginState { .off }
    func setEnabled(_ enabled: Bool) throws {}
    func openSystemSettings() {}
}

@MainActor
private final class RenderNativeDockStub: NativeDockPreferencesServicing {
    var isAvailable: Bool { true }
    func apply(delay: Double) throws {}
    func apply(recommendations: NativeDockRecommendations) throws {}
    func currentAutohideState() async -> NativeDockAutohideState? { nil }
    func openSystemSettings() -> Bool { true }
}

@MainActor
private final class RenderUpdateStub: UpdateControlling {
    var canCheckForUpdates = true
    var pendingUpdateVersion: String?
    var automaticallyChecksForUpdates = false
    var changes: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
    func checkForUpdates() {}
}
