import AppKit
import Combine
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let store: AppSettingsStore
    private let coordinator: SettingsCoordinator
    /// The General page's "Show Guide" button. The guide window belongs to `AppDelegate`, and this
    /// must go straight to `showWelcomeWindow()` (see the note there).
    private let onShowWelcomeGuide: () -> Void
    private var window: NSWindow?
    private var hostingView: NSHostingView<SettingsWindowView>?
    /// Keeps the settings window on the system's light/dark appearance (see `makeWindow`).
    private var appearanceSubscription: AnyCancellable?
    /// Makes the app a regular app while Settings is open, so it has a card on the taskbar.
    private let forkDockPresence = ForkSettingsDockPresence()
    /// Set while `close()` (the permission-loss path) closes the window, so the activation policy is
    /// left to the permission machine.
    private var closingFromOutside = false
    private var hasPresented = false
    private let tabState = SettingsTabState()

    private static let frameAutosaveName = "NitiaDockSettingsWindow"

    init(
        store: AppSettingsStore,
        coordinator: SettingsCoordinator,
        onShowWelcomeGuide: @escaping () -> Void
    ) {
        self.store = store
        self.coordinator = coordinator
        self.onShowWelcomeGuide = onShowWelcomeGuide
    }

    func present() {
        let window = window ?? makeWindow()
        let host = NSHostingView(
            rootView: SettingsWindowView(
                store: store,
                coordinator: coordinator,
                tabState: tabState,
                onShowWelcomeGuide: onShowWelcomeGuide
            )
        )
        window.contentView = host
        hostingView = host
        repairPlacement(isFirstPresentation: !hasPresented)
        hasPresented = true
        forkDockPresence.settingsWillShow()   // before the activation, so the tracker admits the app
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Opens the window on a given page.
    func present(page: SettingsTab) {
        tabState.selected = page
        present()
    }

    /// Outside close (permission lost). `close()` triggers `windowWillClose`, which cleans up.
    func close() {
        closingFromOutside = true
        window?.close()
        closingFromOutside = false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window, notification.object as? NSWindow === window else { return }
        window.contentView = NSView()
        hostingView = nil
        forkDockPresence.settingsDidClose(fromOutside: closingFromOutside)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsWindowView.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ForkBranding.settingsTitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentMinSize = SettingsWindowView.minimumSize
        window.level = .normal
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.center()
        window.setFrameAutosaveName(Self.frameAutosaveName)
        // The app pins `NSApp.appearance` to light for the taskbar's glass, and a nil window
        // appearance would inherit that. The settings window is a normal window, so it gets the
        // system's appearance explicitly and follows it live.
        appearanceSubscription = ForkAppearanceModel.shared.$systemIsDark
            .sink { [weak window] isDark in
                window?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
            }
        self.window = window
        return window
    }

    private func repairPlacement(isFirstPresentation: Bool) {
        guard let window else { return }
        let titlebarHeight = max(1, window.frame.height - window.contentLayoutRect.height)
        guard let repaired = AccessoryWindowPresentation.repairedFrame(
            windowFrame: window.frame,
            titlebarHeight: titlebarHeight,
            visibleFrames: NSScreen.screens.map(\.visibleFrame),
            preferredVisibleFrame: preferredScreen()?.visibleFrame,
            isFirstPresentation: isFirstPresentation
        ) else { return }
        window.setFrame(repaired, display: false)
    }

    private func preferredScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? window?.screen ?? NSScreen.main
    }
}
