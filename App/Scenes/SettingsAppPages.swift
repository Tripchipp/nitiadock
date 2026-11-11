import AppKit
import ApplicationServices
import SwiftUI

// MARK: - Privacy & permissions

struct SettingsPrivacyPage: View {
    @ObservedObject var store: AppSettingsStore
    @ObservedObject var coordinator: SettingsCoordinator
    @State private var isTrusted = AXIsProcessTrusted()

    var body: some View {
        SettingsPage(page: .privacy) {
            SettingsCard(title: String(localized: "Permissions")) {
                SettingsRow(
                    symbol: "accessibility", tint: .blue,
                    title: String(localized: "Accessibility"),
                    subtitle: String(localized: "Lets NitiaDock list your windows and bring them forward. The taskbar cannot work without it.")
                ) {
                    if isTrusted {
                        Label(String(localized: "Allowed"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color(nsColor: .systemGreen))
                    } else {
                        Button(String(localized: "Open System Settings")) {
                            if let url = AccessibilitySettingsLink.url { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                SettingsDivider()
                SettingsRow(
                    symbol: "folder.fill", tint: .teal,
                    title: String(localized: "Finder automation"),
                    subtitle: String(localized: "macOS asks once, the first time you preview a Finder folder or empty the Trash from the taskbar.")
                )
            }

            SettingsCard(title: String(localized: "Updates")) {
                if !ForkDefaults.updatesEnabled {
                    SettingsRow(
                        symbol: "arrow.down.circle.fill", tint: .green,
                        title: String(localized: "Updates"),
                        subtitle: String(localized: "This build never checks for updates. New versions are on GitHub.")
                    )
                } else {
                    SettingsToggleRow(
                        symbol: "arrow.down.circle.fill", tint: .green,
                        title: String(localized: "Check for updates automatically"),
                        subtitle: String(localized: "Once a day NitiaDock asks GitHub whether there is a newer version. Nothing about you or your Mac is sent."),
                        isOn: Binding(
                            get: { coordinator.automaticallyChecksForUpdates },
                            set: { coordinator.automaticallyChecksForUpdates = $0 }
                        )
                    )
                }
            }

            SettingsCard(title: String(localized: "What NitiaDock does with your data")) {
                ForEach(Array(privacyFacts.enumerated()), id: \.offset) { index, fact in
                    if index > 0 { SettingsDivider() }
                    SettingsRow(symbol: fact.symbol, tint: fact.tint, title: fact.title, subtitle: fact.detail)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isTrusted = AXIsProcessTrusted()
        }
    }

    private var privacyFacts: [(symbol: String, tint: SettingsTint, title: String, detail: String)] {
        [
            ("lock.fill", .gray,
             String(localized: "Window titles stay on your Mac"),
             String(localized: "NitiaDock reads window titles and app names to draw the cards. They are never stored or sent anywhere.")),
            ("chart.bar.xaxis", .gray,
             String(localized: "No analytics and no account"),
             String(localized: "There is no tracking, no telemetry and nothing to sign up for.")),
            ("network", .gray,
             String(localized: "Network"),
             !ForkDefaults.updatesEnabled
                ? String(localized: "NitiaDock makes no network connections at all.")
                : String(localized: "The update check is the only connection NitiaDock makes, and only if you turn it on.")),
        ]
    }
}

// MARK: - About

struct SettingsAboutPage: View {
    @ObservedObject var coordinator: SettingsCoordinator

    var body: some View {
        SettingsPage(page: .about) {
            HStack(alignment: .center, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ForkBranding.appName)
                        .font(.title2.weight(.semibold))
                    if let version = coordinator.versionTitle {
                        Text(version)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Text(String(localized: "A taskbar for your Mac: one card for every window."))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 4)

            SettingsCard {
                if ForkDefaults.updatesEnabled {
                    SettingsButtonRow(
                        symbol: "arrow.down.circle.fill", tint: .green,
                        title: String(localized: "Check for updates"),
                        buttonTitle: String(localized: "Check Now"),
                        isEnabled: coordinator.canCheckForUpdates
                    ) {
                        coordinator.checkForUpdates()
                    }
                    SettingsDivider()
                }
                SettingsButtonRow(
                    symbol: "sparkles", tint: .yellow,
                    title: String(localized: "What’s new"),
                    subtitle: String(localized: "The changes in each version."),
                    buttonTitle: String(localized: "Open")
                ) { open(ForkBranding.changelogURL) }
                SettingsDivider()
                SettingsButtonRow(
                    symbol: "bubble.left.and.bubble.right.fill", tint: .blue,
                    title: String(localized: "Send feedback"),
                    subtitle: String(localized: "Report a bug or suggest an idea on GitHub. Your version is filled in for you."),
                    buttonTitle: String(localized: "Send Feedback…")
                ) { open(ForkBranding.feedbackURL(version: coordinator.versionTitle)) }
                SettingsDivider()
                SettingsButtonRow(
                    symbol: "chevron.left.forwardslash.chevron.right", tint: .gray,
                    title: String(localized: "Source code"),
                    subtitle: String(localized: "NitiaDock is open source."),
                    buttonTitle: String(localized: "GitHub")
                ) { open(ForkBranding.repositoryURL) }
            }

            SettingsCard(title: String(localized: "Credits")) {
                SettingsRow(
                    symbol: "heart.fill", tint: .pink,
                    title: String(localized: "Based on Tungsten Edge"),
                    subtitle: String(localized: "The window tracking and the taskbar come from Tungsten Edge by Moonbai Studio. NitiaDock is not affiliated with or supported by Moonbai Studio.")
                ) {
                    Button(String(localized: "Visit")) { open(ForkBranding.upstreamURL) }
                }
                SettingsDivider()
                SettingsRow(
                    symbol: "doc.text.fill", tint: .gray,
                    title: String(localized: "License"),
                    subtitle: String(localized: "Free software under the GNU General Public License, version 3 or later.")
                ) {
                    Button(String(localized: "Read")) { open(ForkBranding.licenseURL) }
                }
            }

            HStack {
                Spacer()
                Button(String(localized: "Quit NitiaDock")) { NSApp.terminate(nil) }
            }
        }
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
