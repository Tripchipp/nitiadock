import AppKit
import SwiftUI

/// The window's root. Like the permission window: no scroller in normal use, the window's height
/// is the content's natural height, and it only scrolls when the screen is too short.
struct WelcomeGuideWindowContent: View {
    let onApply: (WelcomeGuideSelection) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ScrollView(.vertical) {
            WelcomeGuideView(onApply: onApply, onDismiss: onDismiss)
        }
        .frame(width: WelcomeGuideView.contentWidth)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The first-run guide: what NitiaDock is, and the three Dock settings that make room for it.
/// Built from the same cards and rows as the settings window, so the two feel like one app.
///
/// The three options can be ticked separately: this writes the user's own system preferences, and
/// someone may want the Dock hidden without a different minimize animation.
///
/// The window is measured once when it opens (`AppDelegate.showWelcomeWindow`), so nothing here may
/// change height with the toggles.
struct WelcomeGuideView: View {
    let onApply: (WelcomeGuideSelection) -> Void
    let onDismiss: () -> Void

    @State private var selection = WelcomeGuideSelection.recommended

    static let contentWidth: CGFloat = 600

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
            header

            SettingsCard(title: String(localized: "How it works")) {
                SettingsRow(
                    symbol: "rectangle.grid.1x2.fill", tint: .blue,
                    title: String(localized: "One card per window"),
                    subtitle: String(localized: "Click a card to bring its window forward. Click again to minimize it.")
                )
                SettingsDivider()
                SettingsRow(
                    symbol: "cursorarrow.click.2", tint: .purple,
                    title: String(localized: "Right-click for more"),
                    subtitle: String(localized: "Right-click a card to keep its app on the taskbar, or the empty space at either end for the taskbar menu.")
                )
                SettingsDivider()
                SettingsRow(
                    symbol: "slider.horizontal.3", tint: .orange,
                    title: String(localized: "Make it yours"),
                    subtitle: String(localized: "Size, colours, auto-hide and more are in Settings, under the NitiaDock icon in the menu bar.")
                )
            }

            SettingsCard(
                title: String(localized: "Recommended Dock settings"),
                footer: String(localized: "Press ⌥⌘D at any time to show the Dock again. Settings > General > Restore the Dock undoes all three.")
            ) {
                SettingsToggleRow(
                    symbol: "menubar.dock.rectangle", tint: .gray,
                    title: String(localized: "Hide the Dock"),
                    subtitle: String(localized: "NitiaDock takes over its job. The Dock stays away from the bottom edge."),
                    isOn: $selection.hidesDock
                )
                SettingsDivider()
                SettingsToggleRow(
                    symbol: "arrow.down.right.and.arrow.up.left", tint: .teal,
                    title: String(localized: "Use the scale effect when minimizing"),
                    subtitle: String(localized: "A quick shrink instead of the Genie effect."),
                    isOn: $selection.usesScaleMinimizeEffect
                )
                SettingsDivider()
                SettingsToggleRow(
                    symbol: "rectangle.portrait.and.arrow.right", tint: .indigo,
                    title: String(localized: "Minimize windows into their app icon"),
                    subtitle: String(localized: "Minimized windows stay on their card instead of piling up at the end."),
                    isOn: $selection.minimizesIntoAppIcon
                )
            }

            HStack(spacing: 8) {
                Text(String(localized: "The screen flashes once when you apply this."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "Not Now")) { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Apply")) { onApply(selection) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.isEmpty)
            }
        }
        .padding(SettingsMetrics.pagePadding)
        .frame(width: Self.contentWidth, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "Welcome to NitiaDock"))
                    .font(.system(size: 22, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Text(String(localized: "Your windows, one click away."))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
