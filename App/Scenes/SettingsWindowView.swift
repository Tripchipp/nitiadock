import AppKit
import SwiftUI

/// The settings window: a sidebar of pages (with search) on the left, the selected page on the
/// right. Every control writes straight through to `AppSettingsStore` or `SettingsCoordinator`, so
/// there is no draft state and the taskbar updates while you change things.
struct SettingsWindowView: View {
    static let defaultSize = NSSize(width: 780, height: 580)
    static let minimumSize = NSSize(width: 700, height: 440)

    @ObservedObject var store: AppSettingsStore
    @ObservedObject var coordinator: SettingsCoordinator
    @ObservedObject var tabState: SettingsTabState
    let onShowWelcomeGuide: () -> Void

    @State private var query = ""
    @State private var highlight: String?
    @State private var presentedAlert: SettingsAlert?

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $tabState.selected, query: $query, onPickResult: pick)
                .frame(width: SettingsMetrics.sidebarWidth)
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(width: 1)
                .accessibilityHidden(true)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.settingsHighlight, highlight)
                .id(tabState.selected)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .alert(item: $presentedAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }

    @ViewBuilder
    private var page: some View {
        switch tabState.selected {
        case .general:
            SettingsGeneralPage(store: store, coordinator: coordinator, onShowWelcomeGuide: onShowWelcomeGuide) {
                presentedAlert = $0
            }
        case .appearance: SettingsAppearancePage(store: store)
        case .windowCards: SettingsWindowCardsPage(store: store)
        case .displays: SettingsDisplaysPage(store: store)
        case .badges: SettingsBadgesPage()
        case .extras: SettingsExtrasPage(store: store)
        case .mouse: SettingsMousePage(store: store)
        case .windows: SettingsWindowManagementPage(store: store)
        case .privacy: SettingsPrivacyPage(store: store, coordinator: coordinator)
        case .about: SettingsAboutPage(coordinator: coordinator)
        }
    }

    private func pick(_ result: SettingsSearchEntry) {
        tabState.selected = result.page
        highlight = result.title
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if highlight == result.title { highlight = nil }
        }
    }
}

// MARK: - Sidebar

struct SettingsSidebar: View {
    @Binding var selection: SettingsTab
    @Binding var query: String
    let onPickResult: (SettingsSearchEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField
                .padding(.horizontal, 12)
                .padding(.top, 44)   // room for the window's traffic lights (the content runs under the title bar)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        pages
                    } else {
                        results
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(SettingsSidebarMaterial().ignoresSafeArea())
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(String(localized: "Search settings"), text: $query)
                .textFieldStyle(.plain)
                .onSubmit {
                    if let first = SettingsSearchIndex.matches(for: query).first { onPickResult(first) }
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: "Clear search"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
    }

    private var pages: some View {
        ForEach(SettingsTab.Group.allCases, id: \.self) { group in
            Text(group.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
                .padding(.top, group == .essentials ? 4 : 14)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            ForEach(group.pages) { page in
                SettingsSidebarRow(page: page, isSelected: selection == page) { selection = page }
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        let matches = SettingsSearchIndex.matches(for: query)
        if matches.isEmpty {
            Text(String(localized: "No matching settings"))
                .foregroundStyle(.secondary)
                .padding(8)
        }
        ForEach(matches) { entry in
            Button {
                onPickResult(entry)
            } label: {
                HStack(spacing: 8) {
                    SettingsIconTile(symbol: entry.page.symbolName, tint: entry.page.tint, size: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title).lineLimit(1)
                        Text(entry.page.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

struct SettingsSidebarRow: View {
    let page: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SettingsIconTile(symbol: page.symbolName, tint: page.tint, size: 22)
                Text(page.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.1) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - General

struct SettingsGeneralPage: View {
    @ObservedObject var store: AppSettingsStore
    @ObservedObject var coordinator: SettingsCoordinator
    let onShowWelcomeGuide: () -> Void
    let presentAlert: (SettingsAlert) -> Void

    enum HideMode: Hashable { case never, automatically, shortcutOnly }

    @State private var isConfirmingRestore = false

    var body: some View {
        SettingsPage(page: .general) {
            SettingsCard {
                SettingsToggleRow(
                    symbol: "power", tint: .green,
                    title: String(localized: "Open at login"),
                    subtitle: launchSubtitle,
                    isOn: Binding(
                        get: { coordinator.launchAtLoginState == .on },
                        set: { _ in toggleLaunchAtLogin() }
                    )
                )
                .disabled(coordinator.launchAtLoginState == .unsupported)
                SettingsDivider()
                SettingsPickerRow(
                    symbol: "arrow.up.and.down", tint: .blue,
                    title: String(localized: "Taskbar size"),
                    subtitle: String(localized: "The height of the taskbar and its icons."),
                    selection: Binding(get: { store.dockSize }, set: store.setDockSize),
                    options: DockSize.allCases.map { ($0, $0.title) }
                )
            }

            SettingsCard(title: String(localized: "Showing and hiding")) {
                SettingsPickerRow(
                    symbol: "eye.slash", tint: .indigo,
                    title: String(localized: "Hide the taskbar"),
                    subtitle: hideSubtitle,
                    selection: Binding(get: { hideMode }, set: setHideMode),
                    options: [
                        (HideMode.never, String(localized: "Never")),
                        (HideMode.automatically, String(localized: "Automatically")),
                        (HideMode.shortcutOnly, String(localized: "Until the shortcut")),
                    ]
                )
                if hideMode == .automatically {
                    SettingsDivider()
                    SettingsRow(
                        title: String(localized: "Show after"),
                        subtitle: String(localized: "How long the pointer rests at the bottom edge before the taskbar comes back.")
                    ) {
                        HStack(spacing: 8) {
                            Slider(
                                value: Binding(get: { store.edgeAutoHideDelay }, set: store.setEdgeAutoHideDelay),
                                in: AppSettingsStore.finiteDelayMin...AppSettingsStore.finiteDelayMax
                            )
                            .frame(width: SettingsMetrics.sliderWidth)
                            .accessibilityLabel(String(localized: "Show after"))
                            Text(String(format: "%.1f s", store.edgeAutoHideDelay))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 46, alignment: .trailing)
                        }
                    }
                    .padding(.leading, SettingsMetrics.rowIconSize + 12)
                }
                SettingsDivider()
                SettingsRow(
                    symbol: "command", tint: .gray,
                    title: String(localized: "Show/hide shortcut"),
                    subtitle: String(localized: "Switches between always visible and hiding automatically. Works in any app.")
                ) {
                    HStack(spacing: 8) {
                        HotKeyRecorder(
                            currentGlyphs: store.edgeToggleShortcut?.glyphs
                                ?? GlobalHotKeyShortcut.edgeAutoHideMode.displayGlyphs,
                            onRecord: { applyShortcut($0) },
                            onRejectKey: {
                                presentAlert(SettingsAlert(
                                    title: String(localized: "Can’t Use This Shortcut"),
                                    message: String(localized: "This key can’t be used as the shortcut key.")
                                ))
                            }
                        )
                        .fixedSize()
                        Button(String(localized: "Reset")) { applyShortcut(nil) }
                            .disabled(store.edgeToggleShortcut == nil)
                    }
                }
            }

            SettingsCard(title: String(localized: "macOS Dock")) {
                SettingsButtonRow(
                    symbol: "menubar.dock.rectangle", tint: .gray,
                    title: String(localized: "macOS Dock"),
                    subtitle: String(localized: "NitiaDock works best with the Dock hidden. Press ⌥⌘D at any time to show or hide it."),
                    buttonTitle: String(localized: "Dock Settings…")
                ) {
                    _ = coordinator.openNativeDockSettings()
                }
                SettingsDivider()
                SettingsButtonRow(
                    symbol: "arrow.uturn.backward", tint: .orange,
                    title: String(localized: "Restore the Dock"),
                    subtitle: String(localized: "Shows the Dock again and puts back the standard minimize settings. Do this before you uninstall NitiaDock."),
                    buttonTitle: String(localized: "Restore…")
                ) {
                    isConfirmingRestore = true
                }
                .confirmationDialog(
                    String(localized: "Restore the Dock?"),
                    isPresented: $isConfirmingRestore
                ) {
                    Button(String(localized: "Restore")) { restoreDock() }
                    Button(String(localized: "Cancel"), role: .cancel) {}
                } message: {
                    Text(String(localized: "Auto-hide is turned off and minimizing goes back to the Genie effect. The screen flashes once while the Dock restarts."))
                }
                SettingsDivider()
                SettingsButtonRow(
                    symbol: "sparkles", tint: .yellow,
                    title: String(localized: "Setup guide"),
                    subtitle: String(localized: "Go through the first-launch recommendations again, such as hiding the Dock."),
                    buttonTitle: String(localized: "Show Guide"),
                    action: onShowWelcomeGuide
                )
            }
        }
        .task { _ = await coordinator.refreshLaunchAtLoginState() }
    }

    private var launchSubtitle: String {
        switch coordinator.launchAtLoginState {
        case .requiresApproval:
            return String(localized: "Waiting for your approval in System Settings > General > Login Items.")
        case .unsupported:
            return String(localized: "This Mac’s login items can’t be changed from here.")
        case .on, .off:
            return String(localized: "Start NitiaDock automatically when you log in.")
        }
    }

    private var hideMode: HideMode {
        switch store.edgeAutoHideDelay {
        case AppSettingsStore.neverHideDelay: return .never
        case AppSettingsStore.neverWakeDelay: return .shortcutOnly
        default: return .automatically
        }
    }

    private var hideSubtitle: String {
        switch hideMode {
        case .never: return String(localized: "The taskbar is always on screen.")
        case .automatically: return String(localized: "The taskbar slides away and comes back when the pointer reaches the bottom edge.")
        case .shortcutOnly: return String(localized: "The taskbar stays hidden until you press the shortcut below.")
        }
    }

    private func setHideMode(_ mode: HideMode) {
        switch mode {
        case .never:
            store.setEdgeAutoHideDelay(AppSettingsStore.neverHideDelay)
        case .shortcutOnly:
            store.setEdgeAutoHideDelay(AppSettingsStore.neverWakeDelay)
        case .automatically:
            let last = store.lastEnabledEdgeAutoHideDelay
            let usable = (AppSettingsStore.finiteDelayMin...AppSettingsStore.finiteDelayMax).contains(last)
            store.setEdgeAutoHideDelay(usable ? last : 0.5)
        }
    }

    private func restoreDock() {
        Task { @MainActor in
            if let error = await coordinator.restoreNativeDock() {
                presentAlert(SettingsAlert(title: String(localized: "Couldn’t Change Dock Settings"), message: error.localizedDescription))
            }
        }
    }

    private func toggleLaunchAtLogin() {
        guard let enable = LaunchAtLoginMenuModel.requestedEnabledValue(afterSelecting: coordinator.launchAtLoginState) else { return }
        if case .failure(let error) = coordinator.setLaunchAtLogin(enable) {
            presentAlert(SettingsAlert(title: String(localized: "Couldn’t Change Open at Login"), message: error.localizedDescription))
        }
    }

    private func applyShortcut(_ stored: StoredHotKeyShortcut?) {
        if case .failure(let error) = coordinator.applyEdgeToggleShortcut(stored) {
            presentAlert(SettingsAlert(
                hotKeyError: error,
                attemptedGlyphs: stored?.glyphs ?? GlobalHotKeyShortcut.edgeAutoHideMode.displayGlyphs
            ))
        }
    }
}

// MARK: - Alerts

struct SettingsAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    /// A failed shortcut change, as one sentence the user can act on.
    init(hotKeyError: HotKeyChangeError, attemptedGlyphs: String) {
        switch hotKeyError {
        case .rejected(.missingPrimaryModifier):
            self.init(
                title: String(localized: "Can’t Use This Shortcut"),
                message: String(localized: "Use at least one of Command, Control or Option.")
            )
        case .rejected(.unreliableModifiers):
            self.init(
                title: String(localized: "Can’t Use This Shortcut"),
                message: String(localized: "Option alone or Option-Shift is unreliable on macOS 15.")
            )
        case .rejected(.reservedBySystem):
            self.init(
                title: String(localized: "Can’t Use This Shortcut"),
                message: String(localized: "This combination belongs to macOS (⌥⌘D shows/hides the Dock; Control-Option is VoiceOver’s).")
            )
        case .rejected(.forbiddenKey):
            self.init(
                title: String(localized: "Can’t Use This Shortcut"),
                message: String(localized: "Escape and Delete can’t be the key.")
            )
        case .registrationFailed:
            self.init(
                title: String(localized: "Couldn’t Register the Shortcut"),
                message: String(
                    format: String(localized: "%@ is already taken by another app. The previous shortcut stays active."),
                    attemptedGlyphs
                )
            )
        }
    }
}
