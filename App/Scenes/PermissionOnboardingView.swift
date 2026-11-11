import AppKit
import SwiftUI

/// Root view of the window. The scroll bar normally does not appear: the window height is set by the
/// content's natural height, and scrolling is needed only when it is cut off by the screen height.
struct PermissionOnboardingWindowContent: View {
    @ObservedObject var coordinator: PermissionRecoveryCoordinator

    var body: some View {
        ScrollView(.vertical) {
            PermissionOnboardingView(coordinator: coordinator)
        }
        .frame(width: PermissionOnboardingView.contentWidth)
    }
}

struct PermissionOnboardingView: View {
    /// The view observes this single source.
    @ObservedObject var coordinator: PermissionRecoveryCoordinator

    /// The content width is fixed: the window height comes from `fittingSize`, and the width must not jitter
    /// with the length of the copy.
    static let contentWidth: CGFloat = 600

    private var presentation: PermissionPresentation {
        coordinator.presentation ?? .waiting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
            header
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            if presentation == .waiting || presentation == .stalled {
                usage
            }
            if let troubleshooting {
                troubleshootingBox(troubleshooting)
            }
            HStack(spacing: 8) {
                Spacer()
                actions
            }
        }
        .padding(SettingsMetrics.pagePadding)
        .frame(width: Self.contentWidth, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 16) {
            SettingsIconTile(symbol: symbolName, tint: headerTint, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What the permission is used for, in plain words. Asking for "control your computer" without
    /// saying why is what makes people close the window.
    private var usage: some View {
        SettingsCard(title: String(localized: "What the permission is used for")) {
            SettingsRow(
                symbol: "eye.fill", tint: .blue,
                title: String(localized: "See your windows"),
                subtitle: String(localized: "Which windows are open and what they are called, to draw the cards.")
            )
            SettingsDivider()
            SettingsRow(
                symbol: "hand.point.up.left.fill", tint: .purple,
                title: String(localized: "Switch between them"),
                subtitle: String(localized: "Bring a window forward or minimize it when you click its card.")
            )
            SettingsDivider()
            SettingsRow(
                symbol: "lock.fill", tint: .green,
                title: String(localized: "Nothing leaves your Mac"),
                subtitle: String(localized: "Nothing is recorded, and nothing is sent anywhere.")
            )
        }
    }

    private var headerTint: SettingsTint {
        switch presentation {
        case .recoveryWaiting, .recoveryStalled, .relaunchFailed: return .orange
        case .moveToApplications: return .teal
        default: return .blue
        }
    }

    private func troubleshootingBox(_ text: String) -> some View {
        SettingsCard(title: String(localized: "Switch already on but nothing happens?")) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(SettingsMetrics.rowHorizontalPadding)
        }
    }

    // MARK: - Copy

    private var symbolName: String {
        switch presentation {
        case .moveToApplications: return "folder.badge.plus"
        case .waiting, .stalled: return "lock.shield.fill"
        case .recoveryWaiting, .recoveryStalled: return "exclamationmark.shield.fill"
        case .restoringWindows, .relaunching: return "arrow.clockwise"
        case .relaunchFailed: return "xmark.octagon.fill"
        }
    }

    private var title: String {
        switch presentation {
        case .moveToApplications: return String(localized: "Move NitiaDock to Applications")
        case .waiting, .stalled: return String(localized: "Turn On Accessibility Permission")
        case .recoveryWaiting, .recoveryStalled: return String(localized: "Accessibility Permission Was Revoked")
        case .restoringWindows: return String(localized: "Restoring Windows…")
        case .relaunching: return String(localized: "Restarting NitiaDock…")
        case .relaunchFailed: return String(localized: "Restart Failed")
        }
    }

    private var subtitle: String {
        switch presentation {
        case .moveToApplications: return String(localized: "This copy is running from a temporary or read-only location.")
        case .waiting, .stalled: return String(localized: "NitiaDock needs it to show your windows and switch between them.")
        case .recoveryWaiting, .recoveryStalled: return String(localized: "NitiaDock will restart itself once you grant it again.")
        case .restoringWindows: return String(localized: "Putting the windows it moved back where they were.")
        case .relaunching: return String(localized: "This will only take a moment.")
        case .relaunchFailed: return String(localized: "NitiaDock is still running. You can try again.")
        }
    }

    private var message: String {
        switch presentation {
        case .moveToApplications:
            return String(localized: """
            macOS ties Accessibility permission to one specific copy of an app. This copy is running from a \
            temporary or read-only location, so turning the switch on will not take effect — and the permission \
            record stays behind in System Settings after the disk image is ejected. \
            Drag NitiaDock to your Applications folder and open it from there.
            """)
        case .waiting, .stalled:
            return String(format: String(localized: "Turn on NitiaDock in %@. This window closes by itself once you do, and the taskbar appears."), settingsPath)
        case .recoveryWaiting, .recoveryStalled:
            return String(format: String(localized: "NitiaDock just lost its Accessibility permission, so the taskbar has been put away. Turn NitiaDock back on in %@."), settingsPath)
        case .restoringWindows, .relaunching:
            return String(localized: "Nothing to do here — just a moment.")
        case let .relaunchFailed(message):
            return String(format: String(localized: "Couldn’t start a new instance of NitiaDock: %@\n\nYou can click Retry, or quit and open it manually from your Applications folder."), message)
        }
    }

    /// "Remove the old entry and add it again" is only a **conditional troubleshooting suggestion**: we
    /// cannot read the system's authorization database, so we can prove neither whether the user turned the
    /// switch on nor that the old record no longer matches. The copy must stay tentative and must not assume
    /// a signing method: authorization for a build signed with a fixed certificate stays valid across
    /// versions.
    private var troubleshooting: String? {
        let steps = String(localized: """
        If the switch is already on and nothing happens, a permission record left by an older version may no \
        longer match this copy of NitiaDock. You can reset it:

        1. Quit NitiaDock first — while it is running, the minus button in the list is greyed out and the \
        entry cannot be removed.
        2. In Privacy & Security > Accessibility, select NitiaDock in the list and remove it with the minus \
        button. There may be more than one entry; remove them all.
        3. Open NitiaDock again from your Applications folder, then add it and turn the switch on when prompted.
        """)
        switch presentation {
        case .stalled:
            return steps
        case .recoveryStalled:
            return steps + String(localized: """


            If simply turning the switch back on works, NitiaDock restarts itself and there is nothing else \
            to do; going through the cleanup above means reopening it manually afterwards.
            Also, windows the taskbar had moved out of its way may sit one taskbar height short — maximizing \
            them once puts them back.
            """)
        default:
            return nil
        }
    }

    private var settingsPath: String {
        if #available(macOS 13, *) {
            return String(localized: "System Settings > Privacy & Security > Accessibility")
        }
        return String(localized: "System Preferences > Security & Privacy > Privacy > Accessibility")
    }

    // MARK: - Buttons

    @ViewBuilder
    private var actions: some View {
        switch presentation {
        case .moveToApplications:
            quitButton
            Button("Open Applications Folder") { coordinator.openApplications() }
                .keyboardShortcut(.defaultAction)

        case .waiting, .recoveryWaiting:
            quitButton
            Button("Open System Settings") { coordinator.openSettings() }
                .keyboardShortcut(.defaultAction)

        case .stalled, .recoveryStalled:
            quitButton
            Button("Check Again") { coordinator.recheck() }
            Button("Open System Settings") { coordinator.openSettings() }
                .keyboardShortcut(.defaultAction)

        case .restoringWindows, .relaunching:
            ProgressView()
                .controlSize(.small)

        case .relaunchFailed:
            quitButton
            Button("Retry") { coordinator.retryRelaunch() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var quitButton: some View {
        Button("Quit") { coordinator.quit() }
            .keyboardShortcut(.cancelAction)
    }
}
