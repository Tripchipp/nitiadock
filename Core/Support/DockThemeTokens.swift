import Foundation

// MARK: - Light / dark visual value tables (pure data layer)
//
// Why it exists: the whole look was hand-tuned against **dark mode**, with zero appearance branches in the
// repo: every foreground color hardcoded white, every shadow hardcoded black. In light mode
// `NSVisualEffectView` lightens by itself (the material follows the system), but the white text, white
// strokes and white dots on top all fail, and the black shadows become a ring of gray smudge. For a real user
// report see item 3 of GitHub issue #3: "there is an obvious square box around it, with a shadow next to it
// that also extends and overflows; the overall look and feel is poor". That user was in light mode, and every
// complaint maps to one of the tokens below failing in light mode.
//
// **This file does not import SwiftUI**: it stores only base colors + opacity + shadow geometry, all value
// types that compare exactly, so `DockThemeTests` can freeze the dark column item by item. The bridges to
// `Color` / `NSVisualEffectView.Material` are in
// `App/Scenes/DockTheme.swift`.
//
// ⚠️ **The dark column is frozen**: item by item it equals the literals scattered across the views before the
// 2026-07-30 rework, and `DockThemeTests` mechanically guarantees any drift goes red. To tune the look,
// change only `light`; changing `dark` means changing the interface in daily use.
//
// ⚠️ Two traps that "look like colors but are not"; they do not belong in this table and must never change
// with appearance:
//   · `.black` / `.clear` in the scroll edge fade of `DockStripView` are the **alpha channel of a mask**, not
//     colors.
//   · `NSColor(white: 1.0, alpha: 0.0)` in `PanelCoordinator` is **fully transparent**, not a "white base".

/// Base color. The whole look uses only pure white / pure black with opacity over frosted glass, no third
/// base color (the only chromatic color is the badge red, which works in both modes and is not in this
/// table).
enum DockTintBase: Equatable {
    case white
    case black
}

/// A tint value of "base color + opacity".
struct DockTint: Equatable {
    let base: DockTintBase
    let opacity: Double

    static func white(_ opacity: Double) -> DockTint { .init(base: .white, opacity: opacity) }
    static func black(_ opacity: Double) -> DockTint { .init(base: .black, opacity: opacity) }
}

/// The normal / emphasized values of one visual element (emphasized = hover, or drop hit).
struct DockTintPair: Equatable {
    let normal: DockTint
    let emphasized: DockTint
}

/// Shadow: color + blur radius + downward offset (x is always 0; no shadow in the whole look has a horizontal
/// offset).
struct DockShadow: Equatable {
    let tint: DockTint
    let radius: CGFloat
    let y: CGFloat

    /// Total downward extent of the shadow. **Must be ≤ `PanelCoordinator.shadowPadding` (20pt)**, or it is
    /// hard-cut into a straight edge at the panel's transparent margin, which is exactly the user's "the
    /// shadow also extends and overflows". The dark taskbar's current 15 + 8 = 23 exceeds it by 3pt; dark is
    /// frozen and untouched this round (tracked as a separate todo). The light column is entirely within
    /// budget.
    var verticalExtent: CGFloat { radius + abs(y) }
}

/// Frosted glass material. Uses its own enum instead of `NSVisualEffectView.Material` to keep this file
/// independent of AppKit (mapped in `DockTheme.swift`). If the backing looks too white in light mode, this is
/// where to swap the material.
enum DockPanelMaterial: Equatable {
    case popover
    case hudWindow
    case menu
    case underWindowBackground
    case sidebar
    case titlebar
    case selection
    case headerView
    case fullScreenUI
    case toolTip
    case sheet
    case windowBackground
    case contentBackground
    case underPageBackground

    /// For tuning: `DOCK_PANEL_MATERIAL=<name>` swaps the material **without a rebuild**, about 8 seconds per
    /// iteration, convenient for shooting a whole candidate comparison sheet in one go. The names are the
    /// cases above (case-insensitive). An unrecognized name **falls back to the default passed in** and never
    /// crashes: a typo while tuning should not keep the app from launching.
    static func resolved(from environment: [String: String], fallback: DockPanelMaterial) -> DockPanelMaterial {
        guard let raw = DebugSwitch.panelMaterial.value(in: environment)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !raw.isEmpty else { return fallback }
        return all.first { "\($0)".lowercased() == raw } ?? fallback
    }

    /// All candidates, for parsing and for iterating the comparison sheet. All system materials are macOS
    /// 10.14+ and our minimum is 12, so no availability branches.
    static let all: [DockPanelMaterial] = [
        .popover, .hudWindow, .menu, .underWindowBackground, .sidebar,
        .titlebar, .selection, .headerView, .fullScreenUI, .toolTip,
        .sheet, .windowBackground, .contentBackground, .underPageBackground,
    ]
}

// Icons are **no longer dimmed by state** (removed 2026-08-02, light and dark together). Only two state
// signals remain: the running dot below the icon (running or not) and `labelActive` / `labelInactive` on
// titled cards (on the desktop or not).

/// Appearance-independent shape constants. `cornerRadius: 16` used to live in the private `Style` of
/// `DockStripView`, so `DrawerView` / `FolderGridPopupView` / `ShelfGridPopupView` each hardcoded their own
/// 16.
enum DockShape {
    /// Corner radius of all floating panels (taskbar / drawer / capsule / the two popovers).
    static let panelCornerRadius: CGFloat = 16
}

/// Solid color scheme of the shelf icon.
///
/// **Cannot use `DockTint`**: that has only black / white base colors, while this needs a colored tile that
/// "looks like a native app icon". The three candidates live here rather than in the theme table: they are
/// mutually exclusive options for one position, not three independent values.
enum DockShelfTileStyle: String, CaseIterable {
    /// Dark storage pouch + white paper showing above the top edge, self-drawn vector (`ShelfTrayArt`). The
    /// look specified on 2026-08-16.
    case tray
    /// Graphite gradient + white tray symbol. The fallback if the tray drawing does not look right ("use
    /// graphite gray first").
    case graphite
    /// System blue gradient + white symbol. Looks like a first-party utility icon, same color family as the
    /// folder zone to the right.
    case blue
    /// Near-white gradient + dark gray symbol. The least eye-catching; on light wallpapers it holds up
    /// through the symbol and the shadow.
    case light

    static func resolve(_ raw: String?) -> DockShelfTileStyle {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              let style = DockShelfTileStyle(rawValue: raw) else { return .tray }
        return style
    }

    /// Whether it is the self-drawn illustration (`tray`). The other three are "solid tile + SF symbol".
    var isIllustration: Bool { self == .tray }

    /// (top, bottom) gradient endpoints and the symbol color, all opaque RGB. `tray` does not take this path
    /// and returns its own approximate colors only so that invariants such as "enough contrast between symbol
    /// and base" hold uniformly for all four.
    var colors: (top: DockRGB, bottom: DockRGB, glyph: DockRGB) {
        switch self {
        case .tray:
            return (DockRGB(0.30, 0.30, 0.30), DockRGB(0.19, 0.19, 0.19), DockRGB(0.97, 0.97, 0.97))
        case .graphite:
            return (DockRGB(0.45, 0.47, 0.51), DockRGB(0.27, 0.29, 0.33), DockRGB(1, 1, 1))
        case .blue:
            return (DockRGB(0.36, 0.66, 0.98), DockRGB(0.13, 0.45, 0.90), DockRGB(1, 1, 1))
        case .light:
            return (DockRGB(0.99, 0.99, 1.00), DockRGB(0.88, 0.89, 0.92), DockRGB(0.26, 0.28, 0.32))
        }
    }

    /// Brightens the whole tile on a drop hit (it used to be "denser backing"; on a solid tile it has to be
    /// the opposite).
    static let dropTargetLift: Double = 0.12
}

/// Opaque RGB. Deliberately minimal: only the shelf tile needs it, do not use it to replace `DockTint`.
struct DockRGB: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Interpolates toward white, for the drop-hit brightening.
    func lightened(by amount: Double) -> DockRGB {
        let t = min(max(amount, 0), 1)
        return DockRGB(red + (1 - red) * t, green + (1 - green) * t, blue + (1 - blue) * t)
    }

    /// Perceived luminance (Rec. 709). For unit tests only, to assert the symbol and the tile do not collide.
    var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
}

// MARK: - Tokens

struct DockThemeTokens: Equatable {

    // MARK: Panels (shared by taskbar / drawer / drawer capsule / folder popover / shelf popover)

    /// **Top edge** of the panel stroke. Apple's native glass is "bright top edge, almost nothing at the
    /// bottom", simulating light from above; before the rework it was a uniform ring of white 0.15, which in
    /// light mode became the gray frame the user called an "obvious square box". Dark has the same value at
    /// both ends (0.15 / 0.15) -> the gradient degenerates to a uniform color, pixel-identical to before the
    /// rework.
    let panelRimTop: DockTint
    /// **Bottom edge / sides** of the panel stroke.
    let panelRimBottom: DockTint
    /// Whole-frame highlight on a drop hit (drawer icon dragged over the taskbar, external directory hovering
    /// the folder zone).
    let panelRimHighlighted: DockTint
    let panelRimLineWidth: CGFloat
    let panelRimHighlightedLineWidth: CGFloat

    // MARK: Glass thickness (inner highlight + inner shadow)
    //
    // The "thickness" of real glass comes from two edge signals: a bright line along the top inner edge
    // (light entering the medium from above) + a dark falloff along the bottom inner edge (the self-shadow at
    // the bottom of the medium). Both layers are drawn **above** the material and **below** the content; they
    // are our own pixels, so the "cannot get the pixels behind the window" limit does not apply: refraction
    // and backdrop saturation are out of reach, thickness is not.
    //
    // **Dark is always opacity 0 + width 0**, equivalent to not drawing, so dark stays frozen pixel for
    // pixel.

    let panelInnerHighlight: DockTint
    let panelInnerHighlightWidth: CGFloat
    let panelInnerHighlightBlur: CGFloat
    let panelInnerShadow: DockTint
    let panelInnerShadowWidth: CGFloat
    let panelInnerShadowBlur: CGFloat

    /// Backdrop saturation multiplier. **1.0 = no filter** (the whole modifier is then not attached, same
    /// reason as the thickness layers).
    ///
    /// Measured 2026-07-30: SwiftUI's `.saturation()` acts on the **composited result** of the frosted glass
    /// (material + already blurred backdrop), so it really does enrich the backdrop colors, and **the blur is
    /// kept**: on a color target the saturation inside the bar measured 0.221 -> 0.534, with the control
    /// outside the bar unchanged at 0.398.
    ///
    /// By contrast `.opacity()` is a **dead end**, do not try it again: it erases part of the material itself
    /// and exposes the **unblurred** raw desktop (measured: the transition band inside the bar collapses from
    /// 115px to 0.9px, as sharp as outside the bar). It looks cheap, not "more transparent glass" but "glass
    /// with a hole in it". Transparency can only come from swapping the material.
    let panelBackdropSaturation: Double
    /// Drop shadow of the taskbar + drawer capsule.
    let stripShadow: DockShadow
    /// Drop shadow of the drawer + the two popovers (slightly tighter than the taskbar's, since they float
    /// higher).
    let popupShadow: DockShadow
    let panelMaterial: DockPanelMaterial

    // MARK: Title capsule of multi-window chips

    /// Card fill.
    ///
    /// **Its direction must be opposite to the text.** The backing is translucent and its luminance follows
    /// the **wallpaper**, while the text color is a fixed black; going the same direction flattens the
    /// contrast. Before 2026-08-16 this was "add black 0.05", tuned back then to "make the card look like a
    /// card", not for legibility, and it happened to go the same direction. **Do not follow that intuition
    /// back to adding black.**
    ///
    /// ⚠️ **Brightening this cannot save the gray text of `labelInactive`; the two values must be tuned as a
    /// pair.** Translucent black text is drawn on the pill, so text luminance = pill luminance ×(1−α), and
    /// the text brightens along with the pill: for gray text at α=0.45, backing 110 -> contrast 2.13, pill
    /// raised to 145 gives only 2.57 and to 180 only 2.82; on the same backing, deepening the gray text
    /// itself from 0.45 to 0.62 reaches 2.8+ in one step. Brightening the pill mainly benefits `labelActive`
    /// (black 0.85 is nearly opaque, so it gains whatever the backing gains).
    ///
    /// The current 0.24 was set in the 2026-08-28 "unreadable on dark wallpapers" round and signed off on
    /// device that day (previously 0.13, picked on 2026-08-16 from 0.10 / 0.12 / 0.13 and compared on light
    /// wallpapers only). The hover value keeps the existing ×1.4 relation. Tuning knob:
    /// `DOCK_CHIP_PILL_FILL`.
    ///
    /// The card's "looks like a card" is carried by the `chipPillRimTop` stroke, not the fill, so the stroke
    /// must be brighter than the fill.
    let chipPillFill: DockTintPair
    let chipPillRimTop: DockTintPair
    let chipPillRimBottom: DockTint

    // MARK: Text

    /// Window title (when the window is visible on the desktop).
    let labelActive: DockTint
    /// Window title (when minimized / hidden).
    ///
    /// The most fragile contrast on the whole bar: translucent black text on a backing whose luminance
    /// follows the wallpaper. On dark wallpapers 0.45 simply dissolves (reported 2026-08-28), and
    /// **brightening the pill cannot save it**, for the reason in the `chipPillFill` comment. Current value
    /// 0.62, signed off on device 2026-08-28. Any deeper starts eating the light/dark distinction for "on the
    /// current desktop or not"; do not go past `labelActive` 0.85. Tuning knob: `DOCK_LABEL_INACTIVE`.
    let labelInactive: DockTint
    /// Name that appears on hover (window chip / drawer icon / folder name / shelf).
    let labelHover: DockTint
    /// App-name subtitle below the title capsule.
    let labelSubtitle: DockTint
    /// Stroke halo for **bare text** (text without a pill behind it): app name appearing on hover, icon card
    /// hover title, drawer icon hover name, shelf hover label, pinned folder name.
    ///
    /// The color is the **opposite** of the text: in the dark column a black halo carries white text, in the
    /// light column a white halo carries black text, the same way macOS treats desktop icon labels. `y = 0`:
    /// the goal is a ring around the glyphs, not a drop shadow. Window titles **inside** the pill do not use
    /// it; the pill fill handles that, and stacking both makes small text blurry.
    let labelHalo: DockShadow

    // MARK: Indicators

    /// The small running dot below the icon. In light mode a white dot is invisible on light glass.
    let runningDot: DockTint
    /// Vertical separator between taskbar zones.
    let zoneDivider: DockTint

    // MARK: Shelf

    /// Color scheme of the shelf tile. **Must be opaque**: it is the only chip on the bar that is not an app
    /// icon, and if translucent it disappears as soon as what is under the glass gets dark (reported
    /// 2026-08-16). See `ShelfChip.shelfIcon`. Switch live with `DOCK_SHELF_TILE=blue|graphite|light`, no
    /// rebuild needed.
    let shelfTile: DockShelfTileStyle
    /// Halo expanding beyond the backing on a drop hit.
    let shelfDropGlow: DockTint

    // MARK: Drawer capsule

    /// 3x3 grid placeholder symbol shown when the drawer is empty.
    let capsuleGlyph: DockTint
    /// "Faint glow" when a dragged card hovers the capsule (the replacement feedback after the overly harsh
    /// white ring was removed, 2026-06-21).
    let capsuleStashGlow: DockTint

    // MARK: Pinned folder chip

    /// Hit ring when an external file is dragged onto a folder chip (= move into that folder).
    let folderDropRing: DockTint
    /// Thin stroke on real thumbnail covers (icon covers get no stroke).
    let folderThumbHairline: DockTint

    // MARK: Folder / shelf popovers

    let popupCellLabel: DockTint
    let popupCellHover: DockTint
    /// Primary messages such as "Cannot read the folder's contents".
    let popupPrimaryText: DockTint
    /// Secondary hints such as "The folder is empty" or "Drag files to the shelf to stage them".
    let popupSecondaryText: DockTint
    let backChipFill: DockTint
    let backChipRim: DockTint
    let backChipGlyph: DockTint

    // MARK: Window title tooltip

    /// Bubble backing. **Not a `DockTint`**: the white/black base colors cannot produce "near white but not
    /// pure white".
    ///
    /// The values were solved, not tuned. Readings of the same native bubble on two backgrounds: **173** on
    /// pure black, **216** on a green wallpaper (about 145). Let `reading = a·L + (1-a)·background`:
    /// `173 = a·L`, `216 = 173 + (1-a)·145` → **a = 0.70, L = 246**.
    ///
    /// So native is **a near-white plate that lets 30% through**. There was one detour: with only the
    /// black-background reading in hand, 173 was taken as its own color, giving "opaque neutral gray",
    /// exactly the wrong direction. **One background cannot solve two unknowns**; any future measurement of
    /// such a translucent surface must use two backgrounds.
    let tooltipPlate: DockRGB
    /// See `tooltipPlate`: 0.70 = 30% of the background shows through.
    let tooltipPlateOpacity: Double
    /// Bubble stroke. **Must be brighter than the fill**: it is the specular edge of the glass and the source
    /// of crispness; inverted to a dark edge it is as good as no edge, and the bubble dissolves into the
    /// background (native profile measured 2026-08-17).
    let tooltipRim: DockTint
    let tooltipText: DockTint
    let tooltipShadow: DockShadow

    /// Whether this set of values draws the thickness layers at all. **Dark must be `false`**: not "draw a
    /// fully transparent layer" but the whole layer never enters the view tree. `.blur(radius: 0)` can still
    /// trigger offscreen rendering in SwiftUI, and one more layer could make dark's pixel-by-pixel comparison
    /// differ, and then the freeze is no longer strict.
    var drawsPanelThickness: Bool {
        Self.drawsThickness(highlight: panelInnerHighlight, highlightWidth: panelInnerHighlightWidth,
                            shadow: panelInnerShadow, shadowWidth: panelInnerShadowWidth)
    }

    /// Pure-function form of the check above (unit tests hit this directly instead of building a whole
    /// 44-field table to try 4 values). A transparent color **or** a zero line width both mean invisible; it
    /// counts as "draw" only when neither is the case.
    static func drawsThickness(highlight: DockTint, highlightWidth: CGFloat,
                               shadow: DockTint, shadowWidth: CGFloat) -> Bool {
        (highlight.opacity > 0 && highlightWidth > 0) || (shadow.opacity > 0 && shadowWidth > 0)
    }
}

// MARK: - The single set of theme values

extension DockThemeTokens {
    /// **The single set of theme values.** The product is fixed to light (dark mode was removed by decision
    /// on 2026-08-16), so there are no "light / dark" columns here any more, and the name carries no relative
    /// notion: this is all there is.
    ///
    /// The premise is that `AppDelegate` unconditionally pins `NSApp.appearance` to `.aqua`:
    /// `NSVisualEffectView` and Liquid Glass follow the **window's effectiveAppearance** and ignore the
    /// SwiftUI environment. If the system is dark and this is not forced, the material renders dark while
    /// this table holds light values, and the result is "the text flipped, the backing did not" (measured on
    /// the same screen and wallpaper: backing luminance 37.7 vs 143.2).
    static let standard = DockThemeTokens(
        panelRimTop: .white(0.6),
        panelRimBottom: .black(0.1),
        // Drop highlight: a brighter ring layered **on top of** the usual rim (`DockPanelRimPlan`). Changed
        // 2026-08-20 from black 0.35 to white 0.45: the black version was left over from before glass became
        // the default, and on top of the glass's white specular rim it turned into "a black frame". White
        // 0.45 is the value the deleted dark table used.
        panelRimHighlighted: .white(0.45),
        panelRimLineWidth: 0.5,
        panelRimHighlightedLineWidth: 1,
        // ⚠️ The two groups below are **candidate values, inactive by default**: not signed off yet, so by
        // the rule "anything not signed off is opt-in" they are enabled by environment variables
        // (`DOCK_PANEL_THICKNESS=1` / `DOCK_PANEL_SATURATION=candidate`, see `DockEffectSwitches`). The
        // values stay in the table so that tuning has a single table to edit.
        //
        // Thickness candidate: a bright line along the top inner edge + a dark falloff along the bottom inner
        // edge.
        panelInnerHighlight: .white(0.5),
        panelInnerHighlightWidth: 1.5,
        panelInnerHighlightBlur: 2,
        panelInnerShadow: .black(0.06),
        panelInnerShadowWidth: 2,
        panelInnerShadowBlur: 3,
        // Backdrop saturation candidate. 3.0 is an extreme value for experiments; this magnitude is enough
        // for daily use.
        panelBackdropSaturation: 1.25,
        stripShadow: DockShadow(tint: .black(0.14), radius: 8, y: 3),
        popupShadow: DockShadow(tint: .black(0.14), radius: 8, y: 3),
        // The transparency candidate is still to be picked from the comparison sheet; until then keep
        // .popover.
        panelMaterial: .popover,

        // 0.10 / 0.12 / 0.13 were compared on device on 2026-08-16, 0.13 chosen. Hover state ×1.4.
        chipPillFill: DockTintPair(normal: .white(0.24), emphasized: .white(0.336)),
        chipPillRimTop: DockTintPair(normal: .white(0.55), emphasized: .white(0.7)),
        chipPillRimBottom: .black(0.1),

        labelActive: .black(0.85),
        labelInactive: .black(0.62),
        labelHover: .black(0.75),
        labelSubtitle: .black(0.55),
        labelHalo: DockShadow(tint: .white(0.70), radius: 1.5, y: 0),

        runningDot: .black(0.5),
        zoneDivider: .black(0.12),

        shelfTile: .tray,
        shelfDropGlow: .black(0.1),

        capsuleGlyph: .black(0.55),
        capsuleStashGlow: .black(0.1),

        folderDropRing: .black(0.45),
        folderThumbHairline: .black(0.15),

        popupCellLabel: .black(0.85),
        popupCellHover: .black(0.06),
        popupPrimaryText: .black(0.7),
        popupSecondaryText: .black(0.45),
        backChipFill: .black(0.06),
        backChipRim: .black(0.12),
        backChipGlyph: .black(0.75),

        // Set 2026-08-17 against the edge profile of a native screenshot (black background, @2x): native is
        // "0 -> 191 -> **209** -> 173 173 173...": a 1px highlight ring **brighter than the fill**, and only
        // then the fill 173. Ours was "59 -> 157 -> 189 -> 202": no edge and a fill that was too white, so
        // the bubble "dissolved" into the background; that was the reported "not crisp / soft".
        //
        // The bright edge is the specular edge of the glass, same principle as the panel stroke (see
        // `panelRimTop`); the direction must not be inverted. 246/255 = 0.965, 30% see-through, obtained by
        // solving the equations, see the `tooltipPlate` comment.
        tooltipPlate: DockRGB(0.965, 0.965, 0.968),
        tooltipPlateOpacity: 0.70,
        // Starting value, pending calibration by measurement (see the three target points in the field
        // comment).
        tooltipRim: .white(0.45),
        tooltipText: .black(0.85),
        tooltipShadow: DockShadow(tint: .black(0.14), radius: 5, y: 2)
    )
}
