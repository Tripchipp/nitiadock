import SwiftUI

/// Shared plumbing for the two look pages: a binding into one field of `ForkAppearance`, written
/// back through the store so the taskbar redraws while the control moves.
@MainActor
private struct AppearanceFields {
    let store: AppSettingsStore

    func binding<Value>(_ keyPath: WritableKeyPath<ForkAppearance, Value>) -> Binding<Value> {
        Binding(
            get: { store.appearance[keyPath: keyPath] },
            set: { set(keyPath, $0) }
        )
    }

    func set<Value>(_ keyPath: WritableKeyPath<ForkAppearance, Value>, _ value: Value) {
        var appearance = store.appearance
        appearance[keyPath: keyPath] = value
        store.setAppearance(appearance)
    }

    var systemIsDark: Bool { ForkAppearanceModel.shared.systemIsDark }
}

private func points(_ value: Double) -> String { "\(Int(value.rounded())) pt" }
private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

// MARK: - Appearance (the taskbar itself)

struct SettingsAppearancePage: View {
    @ObservedObject var store: AppSettingsStore
    private var fields: AppearanceFields { AppearanceFields(store: store) }

    var body: some View {
        SettingsPage(page: .appearance, subtitle: String(localized: "Changes show on the taskbar right away.")) {
            SettingsCard(title: String(localized: "Taskbar")) {
                SettingsPickerRow(
                    symbol: "circle.lefthalf.filled", tint: .blue,
                    title: String(localized: "Taskbar tint"),
                    subtitle: String(localized: "The colour of the glass behind the icons."),
                    selection: fields.binding(\.barTint),
                    options: [
                        (.upstream, String(localized: "Light")),
                        (.dark, String(localized: "Dark")),
                        (.system, String(localized: "Auto")),
                    ],
                    segmented: true
                )
                SettingsDivider()
                SettingsSliderRow(
                    symbol: "drop.halffull", tint: .teal,
                    title: String(localized: "Taskbar opacity"),
                    subtitle: String(localized: "At 0% the icons sit straight on the wallpaper."),
                    value: store.appearance.barOpacity,
                    untouched: untouchedBarOpacity,
                    range: ForkAppearance.barOpacityRange,
                    step: 0.05,
                    format: percent,
                    onChange: { fields.set(\.barOpacity, $0) }
                )
                SettingsDivider()
                SettingsSliderRow(
                    symbol: "arrow.down.to.line", tint: .indigo,
                    title: String(localized: "Distance from the bottom"),
                    subtitle: String(localized: "The gap under the taskbar. At 0 pt it sits on the screen edge."),
                    value: store.appearance.bottomMargin,
                    untouched: ForkAppearance.upstreamBottomMargin,
                    range: ForkAppearance.bottomMarginRange,
                    step: 1,
                    format: points,
                    onChange: { fields.set(\.bottomMargin, $0) }
                )
                SettingsDivider()
                SettingsSliderRow(
                    symbol: "arrow.left.and.right", tint: .gray,
                    title: String(localized: "Padding at the ends"),
                    subtitle: String(localized: "Empty space at both ends. Right-click it to open the taskbar’s menu."),
                    value: store.appearance.edgePadding,
                    untouched: ForkAppearance.upstreamEdgePadding,
                    range: ForkAppearance.edgePaddingRange,
                    step: 1,
                    format: points,
                    onChange: { fields.set(\.edgePadding, $0) }
                )
            }

            SettingsCard(title: String(localized: "Running-app dot")) {
                SettingsPickerRow(
                    symbol: "circle.fill", tint: .green,
                    title: String(localized: "Dot colour"),
                    subtitle: String(localized: "The dot under an app that is running."),
                    selection: fields.binding(\.dotColor),
                    options: [
                        (.upstream, String(localized: "Auto")),
                        (.white, String(localized: "White")),
                        (.black, String(localized: "Black")),
                        (.accent, String(localized: "Accent colour")),
                    ]
                )
                SettingsDivider()
                SettingsPickerRow(
                    symbol: "smallcircle.filled.circle", tint: .green,
                    title: String(localized: "Dot size"),
                    selection: fields.binding(\.dotSize),
                    options: [
                        (.upstream, String(localized: "Small")),
                        (.medium, String(localized: "Medium")),
                        (.large, String(localized: "Large")),
                    ],
                    segmented: true
                )
            }

            SettingsCard(footer: String(localized: "Menus, popups and the drawer always stay light.")) {
                SettingsButtonRow(
                    symbol: "arrow.counterclockwise", tint: .gray,
                    title: String(localized: "Reset appearance"),
                    subtitle: String(localized: "Puts everything on this page and on Window Cards back to the original look."),
                    buttonTitle: String(localized: "Reset"),
                    isEnabled: !store.appearance.isUpstream
                ) {
                    store.setAppearance(.upstream)
                }
            }
        }
    }

    private var untouchedBarOpacity: Double {
        store.appearance.barTint.isDark(systemIsDark: fields.systemIsDark)
            ? ForkAppearance.darkBarDefaultOpacity
            : DockLiquidGlassConfiguration.resolve().clearTintOpacity
    }
}

// MARK: - Window cards

struct SettingsWindowCardsPage: View {
    @ObservedObject var store: AppSettingsStore
    private var fields: AppearanceFields { AppearanceFields(store: store) }

    var body: some View {
        SettingsPage(page: .windowCards, subtitle: String(localized: "Every open window gets a card with its title. These options change how the cards look.")) {
            SettingsCard(title: String(localized: "Look")) {
                SettingsPickerRow(
                    symbol: "circle.lefthalf.filled", tint: .indigo,
                    title: String(localized: "Card tint"),
                    selection: fields.binding(\.cardTint),
                    options: [
                        (.upstream, String(localized: "Light")),
                        (.dark, String(localized: "Dark")),
                        (.system, String(localized: "Auto")),
                    ],
                    segmented: true
                )
                SettingsDivider()
                SettingsSliderRow(
                    symbol: "drop.halffull", tint: .teal,
                    title: String(localized: "Card opacity"),
                    value: store.appearance.cardOpacity,
                    untouched: untouchedCardOpacity,
                    range: ForkAppearance.cardOpacityRange,
                    step: 0.02,
                    format: percent,
                    onChange: { fields.set(\.cardOpacity, $0) }
                )
                SettingsDivider()
                SettingsSliderRow(
                    symbol: "app", tint: .blue,
                    title: String(localized: "Corner radius"),
                    value: store.appearance.cardCornerRadius,
                    untouched: ForkAppearance.upstreamCardCornerRadius,
                    range: ForkAppearance.cardCornerRadiusRange,
                    step: 1,
                    format: points,
                    onChange: { fields.set(\.cardCornerRadius, $0) }
                )
                SettingsDivider()
                SettingsRow(
                    symbol: "textformat.size", tint: .gray,
                    title: String(localized: "Title size"),
                    subtitle: String(localized: "Larger or smaller than the standard size.")
                ) {
                    Stepper(value: fields.binding(\.titleFontOffset), in: ForkAppearance.titleFontOffsetRange) {
                        Text(fontOffsetLabel)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    .fixedSize()
                    .accessibilityLabel(String(localized: "Title size"))
                    .accessibilityValue(fontOffsetLabel)
                }
            }

            SettingsCard(title: String(localized: "Width")) {
                SettingsSliderRow(
                    symbol: "arrow.left.and.right.square", tint: .orange,
                    title: String(localized: "Maximum card width"),
                    subtitle: String(localized: "Short titles still get a narrower card."),
                    value: store.appearance.maxCardWidth,
                    untouched: ForkAppearance.upstreamMaxCardWidth,
                    range: ForkAppearance.maxCardWidthRange,
                    step: 2,
                    format: points,
                    onChange: { fields.set(\.maxCardWidth, $0) }
                )
                SettingsDivider()
                SettingsPickerRow(
                    symbol: "text.alignleft", tint: .orange,
                    title: String(localized: "Long titles"),
                    subtitle: String(localized: "What happens when a title does not fit."),
                    selection: fields.binding(\.titleMode),
                    options: [
                        (.upstream, String(localized: "Cut off the end")),
                        (.middle, String(localized: "Cut out the middle")),
                        (.fit, String(localized: "Widen the card")),
                    ]
                )
                SettingsDivider()
                SettingsToggleRow(
                    symbol: "rectangle.split.3x1", tint: .orange,
                    title: String(localized: "Equal-width cards"),
                    subtitle: String(localized: "Every card takes the maximum width, like the Windows taskbar."),
                    isOn: fields.binding(\.equalWidthCards)
                )
            }

            SettingsCard(title: String(localized: "Spacing")) {
                SettingsSliderRow(
                    symbol: "arrow.left.and.right", tint: .gray,
                    title: String(localized: "Space between items"),
                    value: store.appearance.itemSpacing,
                    untouched: ForkAppearance.upstreamItemSpacing,
                    range: ForkAppearance.itemSpacingRange,
                    step: 1,
                    format: points,
                    onChange: { fields.set(\.itemSpacing, $0) }
                )
                SettingsDivider()
                SettingsSliderRow(
                    symbol: "rectangle.on.rectangle", tint: .gray,
                    title: String(localized: "Space between an app’s windows"),
                    subtitle: String(localized: "Follows the space between items until you change it. −8 pt makes the cards touch."),
                    value: store.appearance.sameAppSpacing,
                    untouched: store.appearance.resolvedItemSpacing(),
                    range: ForkAppearance.sameAppSpacingRange,
                    step: 1,
                    format: points,
                    onChange: { fields.set(\.sameAppSpacing, $0) }
                )
            }
        }
    }

    private var untouchedCardOpacity: Double {
        store.appearance.cardTint.isDark(systemIsDark: fields.systemIsDark)
            ? ForkAppearance.darkCardDefaultOpacity
            : DockThemeTokens.standard.effectiveChipPillFill.normal.opacity
    }

    private var fontOffsetLabel: String {
        let offset = store.appearance.titleFontOffset
        return offset == 0 ? "0 pt" : String(format: "%+d pt", offset)
    }
}
