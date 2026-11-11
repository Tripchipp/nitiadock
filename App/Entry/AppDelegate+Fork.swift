import AppKit
import Combine
import Foundation

// fork: glue between NitiaDock's added settings and upstream's stores. Kept out of AppDelegate.swift
// so upstream merges only ever meet the two lines that call into here.
extension AppDelegate {
    func startForkBindings() {
        ForkSettingsContext.messagingStore = messagingStore
        ForkSettingsContext.connectedScreens = { DisplayIdentity.connectedScreenOptions() }
        ForkSettingsContext.openSettings = { [weak self] in self?.openSettings(nil) }
        ForkFinderReopen.shared.start()
        settingsStore.$hapticFeedback
            .removeDuplicates()
            .sink { ForkHaptics.isEnabled = $0 }
            .store(in: &forkSubscriptions)
        ForkSettingsContext.activationPolicyDidChange = { [weak self] in
            self?.runningApplicationStore.reconcileWithWorkspace()
        }

        // `sink` on a @Published fires immediately with the current value, which is what sets the
        // initial state; `removeDuplicates` keeps later identical writes from republishing the list.
        settingsStore.$showDrawer
            .removeDuplicates()
            .sink { [drawerStore] enabled in drawerStore.setEnabled(enabled) }
            .store(in: &forkSubscriptions)

        // Appearance > card tint "Follow system" needs the *system's* light/dark state. The app pins
        // its own appearance to light, so `effectiveAppearance` would always answer "light"; the
        // global preference and its change notification are the source instead.
        ForkAppearanceModel.shared.setSystemIsDark(Self.systemIsInDarkMode)
        DistributedNotificationCenter.default()
            .publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))
            .receive(on: DispatchQueue.main)
            .sink { _ in ForkAppearanceModel.shared.setSystemIsDark(Self.systemIsInDarkMode) }
            .store(in: &forkSubscriptions)
    }

    // MARK: - Reserve screen space

    /// Called once the taskbar is up, next to upstream's window-lift controller. The controller
    /// holds the orchestrator weakly and goes quiet by itself when the panels are torn down, so
    /// the permission-loss and termination paths need no counterpart to this.
    func startForkReservedSpace(host: TaskbarScreenOrchestrator) {
        let controller = ForkReservedSpaceController(
            host: host,
            upstreamLiftIsEnabled: { [weak self] in self?.settingsStore.windowLiftEnabled ?? false }
        )
        forkReservedSpaceController = controller
        host.onForkUnitVisibilityChanged = { [weak controller] in controller?.barGeometryMayHaveChanged() }

        // `sink` delivers the current value immediately, which is what applies the persisted state.
        settingsStore.$reserveScreenSpace
            .removeDuplicates()
            .sink { [weak controller] enabled in controller?.setEnabled(enabled) }
            .store(in: &forkSubscriptions)

        // Anything that moves the bar, changes its height, or changes whether it is always visible.
        // @Published fires before the value lands; the controller re-reads geometry after a delay.
        Publishers.MergeMany(
            settingsStore.$edgeAutoHideDelay.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settingsStore.$dockSize.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settingsStore.$appearance.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settingsStore.$windowLiftEnabled.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                .map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak controller] in controller?.barGeometryMayHaveChanged() }
        .store(in: &forkSubscriptions)
    }

    private static var systemIsInDarkMode: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }
}
