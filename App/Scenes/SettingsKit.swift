import AppKit
import SwiftUI

// The building blocks of the settings window, modelled on System Settings: a page is a title over
// a column of rounded cards, a card is a stack of rows, and a row is a tinted icon tile, a title,
// one line of explanation underneath and the control on the right.

enum SettingsMetrics {
    static let sidebarWidth: CGFloat = 220
    static let pagePadding: CGFloat = 24
    /// Clears the transparent title bar, so a page title lines up with the sidebar's search field.
    static let pageTopPadding: CGFloat = 46
    static let cardSpacing: CGFloat = 18
    static let cardRadius: CGFloat = 12
    static let rowHorizontalPadding: CGFloat = 14
    static let rowVerticalPadding: CGFloat = 10
    static let rowIconSize: CGFloat = 28
    static let controlWidth: CGFloat = 200
    static let sliderWidth: CGFloat = 170
}

extension SettingsTint {
    var color: Color {
        switch self {
        case .gray: return Color(nsColor: .systemGray)
        case .blue: return Color(nsColor: .systemBlue)
        case .indigo: return Color(nsColor: .systemIndigo)
        case .teal: return Color(nsColor: .systemTeal)
        case .red: return Color(nsColor: .systemRed)
        case .orange: return Color(nsColor: .systemOrange)
        case .purple: return Color(nsColor: .systemPurple)
        case .green: return Color(nsColor: .systemGreen)
        case .pink: return Color(nsColor: .systemPink)
        case .yellow: return Color(nsColor: .systemYellow)
        }
    }
}

// MARK: - Search highlight

private struct SettingsHighlightKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The title of the row a search result pointed at. That row tints itself for a moment.
    var settingsHighlight: String? {
        get { self[SettingsHighlightKey.self] }
        set { self[SettingsHighlightKey.self] = newValue }
    }
}

// MARK: - Icon tile

struct SettingsIconTile: View {
    let symbol: String
    let tint: SettingsTint
    var size: CGFloat = SettingsMetrics.rowIconSize

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(tint.color)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Page and card

struct SettingsPage<Content: View>: View {
    let page: SettingsTab
    var subtitle: String?
    @ViewBuilder var content: () -> Content
    @Environment(\.settingsHighlight) private var highlight

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(page.title)
                            .font(.system(size: 22, weight: .bold))
                            .accessibilityAddTraits(.isHeader)
                        if let subtitle {
                            Text(subtitle)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.bottom, 2)
                    content()
                }
                .padding(.horizontal, SettingsMetrics.pagePadding)
                .padding(.bottom, SettingsMetrics.pagePadding)
                .padding(.top, SettingsMetrics.pageTopPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { scroll(proxy) }
            .onChange(of: highlight) { _ in scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let highlight else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(highlight, anchor: .center) }
        }
    }
}

struct SettingsCard<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.headline)
                    .padding(.leading, 2)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07))
            )
            .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// The hairline between two rows of a card, indented past the icon like System Settings.
struct SettingsDivider: View {
    var inset: CGFloat = SettingsMetrics.rowHorizontalPadding + SettingsMetrics.rowIconSize + 12

    var body: some View {
        Divider().padding(.leading, inset)
    }
}

// MARK: - Rows

struct SettingsRow<Control: View>: View {
    var symbol: String?
    var tint: SettingsTint = .gray
    let title: String
    var subtitle: String?
    /// Longer background for the curious, behind an ⓘ button next to the title.
    var info: String?
    @ViewBuilder var control: () -> Control
    @Environment(\.settingsHighlight) private var highlight

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let symbol {
                SettingsIconTile(symbol: symbol, tint: tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title)
                    if let info {
                        SettingsInfoButton(title: title, text: info)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalPadding)
        .padding(.vertical, SettingsMetrics.rowVerticalPadding)
        .frame(minHeight: 48)
        .background(
            Color.accentColor
                .opacity(highlight == title ? 0.16 : 0)
                .animation(.easeOut(duration: 0.3), value: highlight)
        )
        .id(title)
        .accessibilityElement(children: .contain)
    }
}

extension SettingsRow where Control == EmptyView {
    init(symbol: String? = nil, tint: SettingsTint = .gray, title: String, subtitle: String? = nil, info: String? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, subtitle: subtitle, info: info) { EmptyView() }
    }
}

struct SettingsToggleRow: View {
    var symbol: String?
    var tint: SettingsTint = .gray
    let title: String
    var subtitle: String?
    var info: String?
    let isOn: Binding<Bool>

    var body: some View {
        SettingsRow(symbol: symbol, tint: tint, title: title, subtitle: subtitle, info: info) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

/// A menu picker on the right of a row.
struct SettingsPickerRow<Value: Hashable>: View {
    var symbol: String?
    var tint: SettingsTint = .gray
    let title: String
    var subtitle: String?
    var info: String?
    let selection: Binding<Value>
    let options: [(value: Value, title: String)]
    var segmented = false
    var width: CGFloat = SettingsMetrics.controlWidth

    var body: some View {
        SettingsRow(symbol: symbol, tint: tint, title: title, subtitle: subtitle, info: info) {
            picker
                .labelsHidden()
                .fixedSize(horizontal: !segmented, vertical: false)
                .frame(width: segmented ? width : nil)
                .frame(minWidth: segmented ? width : 120, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var picker: some View {
        let base = Picker(title, selection: selection) {
            ForEach(options, id: \.value) { option in
                Text(option.title).tag(option.value)
            }
        }
        if segmented {
            base.pickerStyle(.segmented)
        } else {
            base.pickerStyle(.menu)
        }
    }
}

/// A slider over a value that may be untouched (`nil`), shown at its default; the reset arrow puts
/// it back to `nil`.
struct SettingsSliderRow: View {
    var symbol: String?
    var tint: SettingsTint = .gray
    let title: String
    var subtitle: String?
    var info: String?
    let value: Double?
    let untouched: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let onChange: (Double?) -> Void

    var body: some View {
        SettingsRow(symbol: symbol, tint: tint, title: title, subtitle: subtitle, info: info) {
            HStack(spacing: 8) {
                // Rounded by hand: `Slider(step:)` draws a tick mark for every step.
                Slider(
                    value: Binding(get: { value ?? untouched }, set: { onChange(($0 / step).rounded() * step) }),
                    in: range
                )
                .frame(width: SettingsMetrics.sliderWidth)
                .accessibilityLabel(title)
                .accessibilityValue(format(value ?? untouched))
                Text(format(value ?? untouched))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
                Button {
                    onChange(nil)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Reset to default"))
                .accessibilityLabel(String(localized: "Reset to default"))
                .disabled(value == nil)
                .opacity(value == nil ? 0.35 : 1)
            }
        }
    }
}

/// A row whose control is a single push button.
struct SettingsButtonRow: View {
    var symbol: String?
    var tint: SettingsTint = .gray
    let title: String
    var subtitle: String?
    var info: String?
    let buttonTitle: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        SettingsRow(symbol: symbol, tint: tint, title: title, subtitle: subtitle, info: info) {
            Button(buttonTitle, action: action)
                .disabled(!isEnabled)
        }
    }
}

struct SettingsInfoButton: View {
    let title: String
    let text: String
    @State private var isShown = false

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(String(localized: "More about this setting"))
        .accessibilityLabel(String(format: String(localized: "More about %@"), title))
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 320, alignment: .leading)
                .padding(16)
        }
    }
}

// MARK: - Sidebar material

/// The translucent sidebar background. Behind-window blending, as in System Settings.
struct SettingsSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
