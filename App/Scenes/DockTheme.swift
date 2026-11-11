import AppKit
import SwiftUI

// MARK: - SwiftUI / AppKit bridge for DockThemeTokens
//
// The pure value table lives in `Core/Support/DockThemeTokens.swift` (no SwiftUI import, so unit tests can
// freeze it exactly). This file only translates values into Color / Material / modifiers and makes no value
// decisions.
//
// Usage: a view that needs colors adds
//     private let theme = DockThemeTokens.standard
// and then reads `theme.xxx.color`.
//
// **There is only one set of values** (the product is light-only, dark mode was removed 2026-08-16), so there
// are no value decisions here and views no longer read `colorScheme`. This assumes `AppDelegate`
// unconditionally pins `NSApp.appearance` to `.aqua`: frosted material and glass follow the window
// appearance, not the SwiftUI environment.

extension DockThemeTokens {
    /// Effective material: `DOCK_PANEL_MATERIAL` overrides the token value (unknown names fall back, no
    /// crash).
    var effectivePanelMaterial: DockPanelMaterial {
        DockPanelMaterial.resolved(from: DockEffectSwitches.environment, fallback: panelMaterial)
    }

    /// Effective backdrop saturation. Off -> `1.0` (the bridge's `dockBackdropSaturation` then skips the
    /// modifier). The table's candidate value is used only when on; a number in the env var overrides it
    /// directly.
    var effectiveBackdropSaturation: Double {
        DockEffectSwitches.saturation(from: DockEffectSwitches.environment, candidate: panelBackdropSaturation)
    }

    /// Effective shelf tile palette: `DOCK_SHELF_TILE=blue|graphite|light` overrides the token value (unknown
    /// names fall back to `.blue`, no crash). Three mutually exclusive options, switchable without a rebuild.
    var effectiveShelfTile: DockShelfTileStyle {
        guard let raw = DebugSwitch.shelfTile.value(in: DockEffectSwitches.environment) else { return shelfTile }
        return DockShelfTileStyle.resolve(raw)
    }

    /// Whether the thickness layer is drawn: **the switch first**, then the pure condition
    /// (`drawsPanelThickness`, color and line width both non-zero). Dark is doubly safe: its candidate value
    /// is 0, so even switched on it draws nothing.
    var drawsEffectiveThickness: Bool {
        DockEffectSwitches.thicknessEnabled(from: DockEffectSwitches.environment) && drawsPanelThickness
    }

    /// Effective title-card pill fill: `DOCK_CHIP_PILL_FILL` overrides the table value. Unlike the ones
    /// above, the default here **is the signed-off look**; the env var is only a tuning hook that avoids a
    /// rebuild (like `DOCK_DRAG_FLIGHT_MS`), not an opt-in for an unapproved effect.
    var effectiveChipPillFill: DockTintPair {
        DockEffectSwitches.chipPillFill(from: DockEffectSwitches.environment, candidate: chipPillFill)
    }

    /// Effective title color for "not on the current desktop": `DOCK_LABEL_INACTIVE` overrides the table
    /// value. Must be tuned together with `effectiveChipPillFill`; see the comment on `chipPillFill`.
    var effectiveLabelInactive: DockTint {
        DockEffectSwitches.labelInactive(from: DockEffectSwitches.environment, candidate: labelInactive)
    }
}

enum DockEffectSwitches {
    /// Read once and then fixed: while tuning, change the env var and restart once. This also avoids
    /// inconsistency within a session.
    static let environment = ProcessInfo.processInfo.environment

    /// `DOCK_PANEL_SATURATION=1.25`. Unset / non-numeric / out of range -> `1.0` (= no filter). Special case:
    /// treating `1` as "on, use the table's candidate" makes no sense. The number is the multiplier itself,
    /// so `1` means no boost. To use the table's candidate, write `candidate`.
    static func saturation(from environment: [String: String], candidate: Double) -> Double {
        guard let raw = DebugSwitch.panelSaturation.value(in: environment)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !raw.isEmpty else { return 1.0 }
        if raw == "candidate" { return candidate }
        guard let value = Double(raw), value > 0, value <= 5 else { return 1.0 }
        return value
    }

    /// On only when `DOCK_PANEL_THICKNESS=1`. Everything else (unset, `0`, garbage) is off.
    static func thicknessEnabled(from environment: [String: String]) -> Bool {
        DebugSwitch.panelThickness.value(in: environment)?.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    /// `DOCK_CHIP_PILL_FILL=<normal>[,<hover>]`, both opacities in 0…1. Given one number, hover is derived
    /// with the table's existing **×1.4** ratio. Unset / non-numeric / out of range -> falls back to the
    /// table value. The base color is always white: the direction must oppose the black text
    /// (`DockThemeTokens.chipPillFill`), so there is no way to switch it to "add black".
    static func chipPillFill(from environment: [String: String], candidate: DockTintPair) -> DockTintPair {
        guard let raw = DebugSwitch.chipPillFill.value(in: environment)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return candidate }
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard (1...2).contains(parts.count), let normal = opacity(parts[0]) else { return candidate }
        let emphasized: Double
        if parts.count == 2 {
            guard let parsed = opacity(parts[1]) else { return candidate }
            emphasized = parsed
        } else {
            emphasized = min(normal * 1.4, 1)
        }
        return DockTintPair(normal: .white(normal), emphasized: .white(emphasized))
    }

    /// `DOCK_LABEL_INACTIVE=<opacity>` (0…1). Unset / non-numeric / out of range -> falls back to the table
    /// value. The base color is always black, as above.
    static func labelInactive(from environment: [String: String], candidate: DockTint) -> DockTint {
        guard let raw = DebugSwitch.labelInactive.value(in: environment)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let value = opacity(raw) else { return candidate }
        return .black(value)
    }

    /// Parses an opacity in 0…1. Empty / non-numeric / out of range all give `nil`; the caller falls back.
    private static func opacity(_ raw: String) -> Double? {
        guard !raw.isEmpty, let value = Double(raw), value >= 0, value <= 1 else { return nil }
        return value
    }

    /// Tuning diagnostics: prints a line only when a switch is actually set, and prints the **parsed** value,
    /// so a mistyped name or number (which fell back) shows at once, instead of comparing shots where nothing
    /// took effect.
    static func logActiveOverrides(material: DockPanelMaterial, saturation: Double, thickness: Bool) {
        if let raw = DebugSwitch.panelMaterial.value(in: environment) {
            print("[panel] DOCK_PANEL_MATERIAL=\"\(raw)\" -> effective \(material)")
        }
        if let raw = DebugSwitch.panelSaturation.value(in: environment) {
            print("[panel] DOCK_PANEL_SATURATION=\"\(raw)\" -> effective \(saturation)")
        }
        if let raw = DebugSwitch.panelThickness.value(in: environment) {
            print("[panel] DOCK_PANEL_THICKNESS=\"\(raw)\" -> thickness layer \(thickness ? "on" : "off")")
        }
        // These two are not part of the panel, but are read together with the ones above when tuning
        // contrast, so they print here.
        if let raw = DebugSwitch.chipPillFill.value(in: environment) {
            let pair = DockThemeTokens.standard.effectiveChipPillFill
            print("[panel] DOCK_CHIP_PILL_FILL=\"\(raw)\" -> effective normal \(pair.normal.opacity) / hover \(pair.emphasized.opacity)")
        }
        if let raw = DebugSwitch.labelInactive.value(in: environment) {
            print("[panel] DOCK_LABEL_INACTIVE=\"\(raw)\" -> effective \(DockThemeTokens.standard.effectiveLabelInactive.opacity)")
        }
    }
}

extension DockRGB {
    var color: Color { Color(red: red, green: green, blue: blue) }
}

extension DockShelfTileStyle {
    /// The tile's top-to-bottom gradient. `lifted` = an external file is hovering over it, so the whole tile
    /// shifts toward white.
    func gradient(lifted: Bool) -> LinearGradient {
        let c = colors
        let amount = lifted ? Self.dropTargetLift : 0
        return LinearGradient(colors: [c.top.lightened(by: amount).color,
                                       c.bottom.lightened(by: amount).color],
                              startPoint: .top,
                              endPoint: .bottom)
    }

    var glyphColor: Color { colors.glyph.color }
}

extension DockTint {
    var color: Color {
        switch base {
        case .white: return Color.white.opacity(opacity)
        case .black: return Color.black.opacity(opacity)
        }
    }

    /// Fully transparent version of the same base color. **Do not use `Color.clear` instead**: animation
    /// interpolates between two colors, and fading from `.clear` to a white stroke shows a gray edge midway.
    /// The pre-refactor code was already `opacity(isActive ? 0.9 : 0)`.
    var transparent: Color { DockTint(base: base, opacity: 0).color }

    /// Toggles the same tint by state (off = same base color, fully transparent).
    func color(active: Bool) -> Color { active ? color : transparent }
}

extension DockTintPair {
    /// - Parameter emphasized: hovering, or a drop hit.
    func color(emphasized: Bool) -> Color {
        (emphasized ? self.emphasized : normal).color
    }

    func color(emphasisProgress rawProgress: Double) -> Color {
        let progress = min(max(rawProgress, 0), 1)
        let opacity = normal.opacity + (emphasized.opacity - normal.opacity) * progress
        return DockTint(base: normal.base, opacity: opacity).color
    }
}

extension DockPanelMaterial {
    var nsMaterial: NSVisualEffectView.Material {
        switch self {
        case .popover: return .popover
        case .hudWindow: return .hudWindow
        case .menu: return .menu
        case .underWindowBackground: return .underWindowBackground
        case .sidebar: return .sidebar
        case .titlebar: return .titlebar
        case .selection: return .selection
        case .headerView: return .headerView
        case .fullScreenUI: return .fullScreenUI
        case .toolTip: return .toolTip
        case .sheet: return .sheet
        case .windowBackground: return .windowBackground
        case .contentBackground: return .contentBackground
        case .underPageBackground: return .underPageBackground
        }
    }
}

// MARK: - Switches for unapproved effects
//
// **Default = the approved look; unapproved effects are always opt-in.**
//
// This was corrected on 2026-07-30: the glass experiment was off by default and enabled by
// `DOCK_LIQUID_GLASS=1`, but the saturation boost and thickness layer added the same day were on by default:
// two standards for equally unapproved effects. As a result the visible look drifted from the approved
// version unannounced.
//
// So all three below are opt-in. When tuning, switch one per restart, which also fixes "three stacked
// variables, no attribution". There is still a single table of candidate values (`DockThemeTokens.light`); a
// switch only decides whether it is used.

extension DockThemeTokens {
    /// Panel stroke: bright top edge, dark bottom edge, simulating light from above (the lighting direction
    /// of Apple's native glass). In dark both ends are equal, so the gradient degenerates to a uniform color,
    /// pixel-identical to the pre-refactor `.strokeBorder(.white.opacity(0.15))`.
    var panelRimStyle: LinearGradient {
        LinearGradient(colors: [panelRimTop.color, panelRimBottom.color],
                       startPoint: .top,
                       endPoint: .bottom)
    }

    /// On a drop hit, switches to a solid full border; otherwise uses the vertical gradient.
    func panelRimStyle(highlighted: Bool) -> AnyShapeStyle {
        highlighted ? AnyShapeStyle(panelRimHighlighted.color) : AnyShapeStyle(panelRimStyle)
    }

    func panelRimLineWidth(highlighted: Bool) -> CGFloat {
        highlighted ? panelRimHighlightedLineWidth : panelRimLineWidth
    }

    /// Glass thickness layer: a bright line on the top inner edge (light entering the medium) plus a dark
    /// falloff on the bottom inner edge (self-shadow at the bottom of the medium). Drawn **above** the
    /// material and **below** the content, these are our own pixels, so the "cannot get the pixels behind the
    /// window" limit does not apply (that is what blocks refraction and backdrop saturation).
    ///
    /// Callers must check `drawsEffectiveThickness` first (switch + pure condition): in dark or when off, the
    /// layer never enters the view tree.
    @ViewBuilder
    func panelThicknessLayer(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape
                .strokeBorder(
                    LinearGradient(colors: [panelInnerHighlight.color, panelInnerHighlight.transparent],
                                   startPoint: .top, endPoint: .center),
                    lineWidth: panelInnerHighlightWidth
                )
                .blur(radius: panelInnerHighlightBlur)
            shape
                .strokeBorder(
                    LinearGradient(colors: [panelInnerShadow.transparent, panelInnerShadow.color],
                                   startPoint: .center, endPoint: .bottom),
                    lineWidth: panelInnerShadowWidth
                )
                .blur(radius: panelInnerShadowBlur)
        }
        // Blur spills outside the shape and must be clipped back, or the thickness layer smears outside the
        // panel.
        .clipShape(shape)
        // Purely decorative, must never steal chip clicks (the panel is a nonactivatingPanel, chips rely on
        // onTapGesture).
        .allowsHitTesting(false)
    }

    /// Title capsule stroke: also bright on top, dark at the bottom.
    /// - Parameter emphasized: hovering.
    func chipPillRimStyle(emphasized: Bool) -> LinearGradient {
        LinearGradient(colors: [chipPillRimTop.color(emphasized: emphasized), chipPillRimBottom.color],
                       startPoint: .top,
                       endPoint: .bottom)
    }

    func chipPillRimStyle(emphasisProgress: Double) -> LinearGradient {
        LinearGradient(
            colors: [chipPillRimTop.color(emphasisProgress: emphasisProgress), chipPillRimBottom.color],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

extension View {
    /// Hover feedback for the quiet style: the whole card **scales up slightly**. Criterion:
    /// `HoverStyle.showsQuietHoverFeedback`.
    ///
    /// `scaleEffect` is a pure render transform: it **does not change layout size** (this style's baseline is
    /// "moving the mouse across the taskbar causes no relayout") and does not affect the drop-hit rect
    /// reported by the GeometryReader in `.background`. `PinnedFolderChip` has long scaled its whole body
    /// this way; same established conclusion.
    ///
    /// The anchor is `.bottom`: the bar is only 54pt tall and cards fill its height, so scaling from the
    /// center would overflow below the bar. Pushing up from the bottom edge stays inside the bar and matches
    /// the native Dock's scaling direction.
    ///
    /// Animates with `.animation(_:value:)` (scoped to a value), so it only moves when `isActive` changes.
    /// `LauncherChip`'s launch bounce has its own inner `.animation(_:value: bounceUp)`; the inner one wins
    /// and is not swallowed by this layer. The project rule "the quiet style creates no transaction" exists
    /// to keep the bounce from being hijacked.
    ///
    /// **The curve was picked from three options on 2026-08-17 (`easeOut 0.12` = keep as is)**; it is not an
    /// arbitrary default. The basis has two layers, do not conflate them. **Measured**: synthesizing one
    /// hover, the main thread had zero hitches in those 120ms, with zero recomputation across the bar and
    /// zero relayout. **Inferred**: the reported "not smooth enough" is a curve trade-off, not resource
    /// contention, and a curve is a matter of look that cannot be measured, so three options were built for a
    /// visual comparison. The current one won and the scaffolding was removed. `cardWidth` is **this card's
    /// own width** (already scaled for the size tier), used to cap the outward growth per side: proportional
    /// scaling would grow a 168pt title card outward by 8.4pt, swallowing the 10pt gap between cards (found
    /// 2026-08-17). **Deliberately no default**: omitting it must be a compile error, the same rule as
    /// `scale` / `hoverStyle`.
    func chipQuietHoverScale(_ isActive: Bool, cardWidth: CGFloat, scale: CGFloat) -> some View {
        let target = ChipPillMetrics.quietHoverScale(forCardWidth: cardWidth, scale: scale)
        return self
            .scaleEffect(isActive ? target : 1, anchor: .bottom)
            .animation(.easeOut(duration: 0.12), value: isActive)
    }

    /// Adds a backdrop saturation boost to the frosted panel. **At 1.0 the modifier is not attached at all**:
    /// `.saturation(1.0)` is an identity, but may still trigger offscreen rendering, and one more layer could
    /// break dark's pixel-exact freeze (same reason as the thickness layer).
    @ViewBuilder
    func dockBackdropSaturation(_ amount: Double) -> some View {
        if amount == 1.0 { self } else { self.saturation(amount) }
    }

    /// Applies a `DockShadow` (x always 0). **Never drawn when capturing a drag copy** (reasons and data in
    /// `EnvironmentValues.isDragCarrierSnapshot`).
    ///
    /// There is **no icon shadow path here anymore**: icons / shelf / folder covers carry no outer shadow
    /// (decided 2026-08-19, matching the native Dock). The remaining users are panels, popups, bubbles and
    /// text halos.
    func dockShadow(_ shadow: DockShadow) -> some View {
        modifier(DockShadowModifier(shadow: shadow))
    }

    /// Conditional halo: when `active` is false, radius and opacity both go to zero (equivalent to not
    /// drawing). The halo is outside the "do not bake shadows" scope: it is part of the card (it should
    /// follow during a drag), not a shadow handed over on landing.
    func dockGlow(_ tint: DockTint, radius: CGFloat, active: Bool) -> some View {
        self.shadow(color: tint.color(active: active), radius: active ? radius : 0)
    }
}

struct DragCarrierSnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether this view tree is being captured as the bitmap for a drag copy.
    ///
    /// The captured bitmap differs from the on-screen card in **two deliberate ways**, both controlled by
    /// this:
    /// - **No running dot**: when the native Dock lifts an icon with a dot, the dot disappears and returns on
    ///   landing (decided 2026-08-19).
    /// - **No `dockShadow` is baked**: the icon outer shadow was removed entirely on 2026-08-19 (neither the
    ///   bar nor the carrier casts one), so this now only affects the **folder name's stroke halo**
    ///   (`theme.labelHalo`). It is still left unbaked because `cacheDisplay` captures only about a quarter
    ///   of a SwiftUI `.shadow`'s strength: measured on the same white board, a 0.6 shadow was captured at
    ///   alpha 23 (`ImageRenderer` gives 99 for the same one). Baking it would give a halo much fainter than
    ///   the card's and a step at the landing handoff, worse than not drawing it. That caused the previous
    ///   +2.85 step.
    var isDragCarrierSnapshot: Bool {
        get { self[DragCarrierSnapshotKey.self] }
        set { self[DragCarrierSnapshotKey.self] = newValue }
    }
}

/// Implementation of `dockShadow`. It is a `ViewModifier` only so it can read the environment, which a `View`
/// extension method cannot.
private struct DockShadowModifier: ViewModifier {
    let shadow: DockShadow
    @Environment(\.isDragCarrierSnapshot) private var isSnapshot

    func body(content: Content) -> some View {
        if isSnapshot {
            content
        } else {
            content.shadow(color: shadow.tint.color, radius: shadow.radius, x: 0, y: shadow.y)
        }
    }
}
