import AppKit
import SwiftUI

/// Objects the settings pages need that are not handed to the settings window directly. Set once
/// in `AppDelegate.startForkBindings()`. Weak: the app delegate owns the stores.
@MainActor
enum ForkSettingsContext {
    static weak var messagingStore: MessagingAppStore?
    /// Opens the settings window (same path as the status menu's "Settings…").
    static var openSettings: (() -> Void)?
    /// Called after the app changed its own activation policy (Settings open/closed), so the running
    /// application store re-reads it at once instead of at its next workspace sweep.
    static var activationPolicyDidChange: (() -> Void)?
    /// The connected displays, for Settings > Displays. Injected because `DisplayIdentity` lives in
    /// `Platform/`, which the test target does not compile.
    static var connectedScreens: () -> [(uuid: String, title: String)] = { [] }
}

/// Settings > Badges. Edits `MessagingAppStore.extraBadgeBundleIDs`.
struct SettingsBadgesPage: View {
    var body: some View {
        if let store = ForkSettingsContext.messagingStore {
            SettingsBadgesPageContent(store: store)
        } else {
            SettingsPage(page: .badges) {
                Text(String(localized: "Badge settings are unavailable in this window."))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SettingsBadgesPageContent: View {
    @ObservedObject var store: MessagingAppStore
    @State private var typedBundleID = ""
    @State private var isAddingByID = false

    private struct RunningApp: Identifiable {
        let id: String
        let name: String
    }

    var body: some View {
        SettingsPage(
            page: .badges,
            subtitle: String(localized: "Chat apps such as Messages, Slack, Teams, WhatsApp and Telegram always show their unread count. Add other apps here, for example your mail app.")
        ) {
            SettingsCard(
                title: String(localized: "Also show badges for"),
                footer: String(localized: "The badge is the one the app puts on its Dock icon, so the app has to be running and allowed to show badges in System Settings > Notifications.")
            ) {
                if store.extraBadgeBundleIDs.isEmpty {
                    SettingsRow(title: String(localized: "No extra apps"), subtitle: String(localized: "Only chat apps show badges."))
                }
                ForEach(Array(store.extraBadgeBundleIDs.enumerated()), id: \.element) { index, bundleID in
                    if index > 0 { SettingsDivider(inset: SettingsMetrics.rowHorizontalPadding + 40) }
                    appRow(bundleID)
                }
                SettingsDivider(inset: 0)
                HStack(spacing: 10) {
                    Menu(String(localized: "Add Running App")) {
                        let candidates = runningCandidates()
                        if candidates.isEmpty {
                            Text(String(localized: "No other running apps"))
                        }
                        ForEach(candidates) { app in
                            Button(app.name) { store.addExtraBadgeApp(app.id) }
                        }
                    }
                    .fixedSize()
                    Button(String(localized: "Add by Bundle ID…")) { isAddingByID = true }
                        .popover(isPresented: $isAddingByID, arrowEdge: .bottom) { bundleIDPopover }
                    Spacer()
                    Button(String(localized: "Restore Defaults")) { store.resetExtraBadgeApps() }
                        .disabled(store.extraBadgeAppsAreDefault)
                }
                .padding(.horizontal, SettingsMetrics.rowHorizontalPadding)
                .padding(.vertical, 10)
            }
        }
    }

    private var bundleIDPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Bundle ID")).font(.headline)
            Text(String(localized: "The app’s identifier, such as com.apple.mail. Useful for apps that are not running right now."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("com.example.app", text: $typedBundleID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTyped)
                Button(String(localized: "Add"), action: addTyped)
                    .keyboardShortcut(.defaultAction)
                    .disabled(typedBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func appRow(_ bundleID: String) -> some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let name = url.map { FileManager.default.displayName(atPath: $0.path) } ?? String(localized: "Not installed")
        return HStack(spacing: 12) {
            Group {
                if let url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                } else {
                    Image(systemName: "questionmark.app.dashed")
                        .resizable()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(bundleID).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                store.removeExtraBadgeApp(bundleID)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Remove"))
            .accessibilityLabel(String(format: String(localized: "Remove %@"), name))
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalPadding)
        .padding(.vertical, 8)
    }

    private func addTyped() {
        store.addExtraBadgeApp(typedBundleID)
        typedBundleID = ""
        isAddingByID = false
    }

    /// Running regular apps that would gain something from being added: apps that already have
    /// badges, and NitiaDock itself, are left out. Read when the menu opens.
    private func runningCandidates() -> [RunningApp] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningApp? in
                guard let id = app.bundleIdentifier, id != own, !store.isMessagingApp(id),
                      seen.insert(id).inserted else { return nil }
                return RunningApp(id: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
