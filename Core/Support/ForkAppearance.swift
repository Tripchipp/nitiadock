import CoreGraphics
import Foundation

/// fork: NitiaDock's theme-override layer. Pure values, no SwiftUI/AppKit, so it can be unit-tested
/// like `DockThemeTokens`.
///
/// **The contract: an untouched option changes nothing.** Every field has an "upstream" state
/// (`.upstream` for enums, `nil` for numbers, `0` for offsets), and every `resolved…` function
/// returns the caller's upstream value unchanged in that state. `ForkAppearance.upstream` is the
/// value a fresh install has, and "Reset" in Settings writes it back.
///
/// Adding an option later is four steps: a field here with an upstream state, a `resolved…`
/// function next to it, one key in `ForkAppearanceStorage`, one row in `ForkAppearancePane`.
struct ForkAppearance: Equatable {
    // MARK: Running-app dot

    enum DotColor: String, CaseIterable {
        /// `DockThemeTokens.runningDot` (black at 50%).
        case upstream
        case white
        case black
        /// The system accent colour. Resolved in the SwiftUI layer; this file has no colour type for it.
        case accent
    }

    enum DotSize: String, CaseIterable {
        /// 4pt, upstream's hard-coded diameter.
        case upstream
        case medium
        case large

        /// Unscaled diameter in points. Upstream does not scale the dot with the taskbar size tier,
        /// so neither do the larger sizes.
        var diameter: CGFloat {
            switch self {
            case .upstream: return 4
            case .medium: return 5
            case .large: return 6
            }
        }
    }

    // MARK: Window cards (the pill behind icon + title)

    enum CardTint: String, CaseIterable {
        /// White pill, black title: `DockThemeTokens.chipPillFill` / `labelActive`.
        case upstream
        /// Black pill, white title.
        case dark
        /// `dark` while macOS is in Dark Mode, `upstream` otherwise. The bar's own glass stays light
        /// either way (upstream pins the app to the light appearance).
        case system

        func isDark(systemIsDark: Bool) -> Bool {
            switch self {
            case .upstream: return false
            case .dark: return true
            case .system: return systemIsDark
            }
        }
    }

    // MARK: Card width and title truncation

    enum TitleMode: String, CaseIterable {
        /// Cut at the width cap with a trailing ellipsis.
        case upstream
        /// Cut at the width cap with the ellipsis in the middle, keeping both ends of the title.
        case middle
        /// No cap: the card is as wide as its title. With `equalWidthCards` on there is a cap again
        /// (every card has the same width), and this behaves like `upstream`.
        case fit
    }

    var dotColor: DotColor = .upstream
    var dotSize: DotSize = .upstream
    var cardTint: CardTint = .upstream
    /// Resting opacity of the card fill, `nil` = upstream's 0.24 (or `darkCardDefaultOpacity` for a
    /// dark card, where 0.24 would leave white text unreadable).
    var cardOpacity: Double? = nil
    /// Unscaled corner radius of the card, `nil` = upstream's 10. Multiplied by the size tier's scale.
    var cardCornerRadius: Double? = nil
    /// Points added to the title font size. 0 = upstream.
    var titleFontOffset: Int = 0
    /// Unscaled maximum width of a whole window card (the pill: padding + icon + title), `nil` =
    /// upstream's 188 (a 140pt title cap plus 48pt of icon and padding). Multiplied by the tier scale.
    var maxCardWidth: Double? = nil
    var titleMode: TitleMode = .upstream
    /// Windows-taskbar style: every window card takes the maximum card width, whatever its title.
    var equalWidthCards = false

    // MARK: The bar's own plate

    enum BarTint: String, CaseIterable {
        /// Upstream's light glass: a mid-grey tint over clear Liquid Glass.
        case upstream
        /// Dark glass: a near-black tint. The few things drawn straight on the plate (running dot,
        /// zone divider, card titles) flip to white with it.
        case dark
        /// `dark` while macOS is in Dark Mode, `upstream` otherwise.
        case system

        func isDark(systemIsDark: Bool) -> Bool {
            switch self {
            case .upstream: return false
            case .dark: return true
            case .system: return systemIsDark
            }
        }
    }

    /// Only the bar. Popups, the drawer and tooltips keep upstream's light plate: their text colours
    /// are upstream's single light token table.
    var barTint: BarTint = .upstream
    /// Strength of the plate's tint, 0 = clear glass, 1 = solid. `nil` = upstream's 0.4
    /// (`DockLiquidGlassConfiguration.clearTintOpacity`), or `darkBarDefaultOpacity` for a dark bar.
    var barOpacity: Double? = nil

    // MARK: Spacing

    /// Unscaled gap between neighbouring entries on the bar, `nil` = upstream's 2
    /// (`ChipPillMetrics.chipSpacing`). Multiplied by the size tier's scale, like upstream's.
    var itemSpacing: Double? = nil
    /// Unscaled gap before a window card that follows a card of the same app, `nil` = follow
    /// `itemSpacing` (so an untouched setting changes nothing). Scaled like `itemSpacing`; may be negative.
    var sameAppSpacing: Double? = nil
    /// Unscaled padding between the first / last entry and the ends of the bar's plate, `nil` =
    /// upstream's 20 (`DockStripView`'s `chipContentInset`). Multiplied by the tier's scale.
    var edgePadding: Double? = nil

    // MARK: Bar position

    /// Points between the screen's bottom edge and the bar, `nil` = upstream's 8
    /// (`PanelLayoutMetrics.bottomGap`). Not scaled by the size tier, like upstream's. Geometry lives
    /// in `ForkBottomMargin`.
    var bottomMargin: Double? = nil

    static let upstream = ForkAppearance()
    var isUpstream: Bool { self == .upstream }

    // MARK: Ranges (shared by the sliders, the sanitiser and the tests)

    static let cardOpacityRange: ClosedRange<Double> = 0...0.9
    /// 17 = half of the 34pt card height, i.e. a full capsule.
    static let cardCornerRadiusRange: ClosedRange<Double> = 0...17
    static let titleFontOffsetRange: ClosedRange<Int> = -2...2
    static let upstreamCardCornerRadius: Double = 10
    static let maxCardWidthRange: ClosedRange<Double> = 80...320
    static let bottomMarginRange: ClosedRange<Double> = 0...60
    static let itemSpacingRange: ClosedRange<Double> = 0...24
    /// Below 0 the cards of one app move together: a titled card has 4pt of its own inset on each side,
    /// so -8 is where two card pills touch. Not allowed for `itemSpacing`, which also drives the hover
    /// and right-click rules between different apps and around dividers.
    static let sameAppSpacingRange: ClosedRange<Double> = -8...24
    static let barOpacityRange: ClosedRange<Double> = 0...1
    /// Upstream's tint is `NSColor(deviceWhite: 127/255)`.
    static let upstreamBarTintWhite: Double = 127.0 / 255.0
    static let darkBarTintWhite: Double = 0.06
    /// A dark bar needs more tint than upstream's 0.4 before it reads as dark over a bright wallpaper.
    static let darkBarDefaultOpacity: Double = 0.55
    /// Lower bound 6: below that the plate's rounded corners start cutting into the first card.
    static let edgePaddingRange: ClosedRange<Double> = 6...60
    static let upstreamItemSpacing: Double = 2
    static let upstreamEdgePadding: Double = 20
    static let upstreamBottomMargin: Double = 8
    /// Upstream's `WindowTitleTextMetrics.maximumWidth`.
    static let upstreamTitleCap: Double = 140
    /// What a card adds around its title: 2 x 10 padding + 22 icon slot + 6 spacing
    /// (`ChipPillMetrics`). `ForkCardWidthTests` pins this against those constants.
    static let cardChrome: Double = 48
    static let upstreamMaxCardWidth: Double = upstreamTitleCap + cardChrome
    static let darkCardDefaultOpacity: Double = 0.55
    /// Upstream's hover fill is the resting fill times this (0.24 -> 0.336).
    static let hoverOpacityFactor: Double = 1.4

    /// Clamps stored numbers into their ranges; out-of-range or non-finite values fall back to upstream.
    var sanitized: ForkAppearance {
        var copy = self
        if let value = cardOpacity, !(value.isFinite && Self.cardOpacityRange.contains(value)) {
            copy.cardOpacity = nil
        }
        if let value = cardCornerRadius, !(value.isFinite && Self.cardCornerRadiusRange.contains(value)) {
            copy.cardCornerRadius = nil
        }
        if !Self.titleFontOffsetRange.contains(titleFontOffset) { copy.titleFontOffset = 0 }
        if let value = maxCardWidth, !(value.isFinite && Self.maxCardWidthRange.contains(value)) {
            copy.maxCardWidth = nil
        }
        if let value = bottomMargin, !(value.isFinite && Self.bottomMarginRange.contains(value)) {
            copy.bottomMargin = nil
        }
        if let value = itemSpacing, !(value.isFinite && Self.itemSpacingRange.contains(value)) {
            copy.itemSpacing = nil
        }
        if let value = sameAppSpacing, !(value.isFinite && Self.sameAppSpacingRange.contains(value)) {
            copy.sameAppSpacing = nil
        }
        if let value = barOpacity, !(value.isFinite && Self.barOpacityRange.contains(value)) {
            copy.barOpacity = nil
        }
        if let value = edgePadding, !(value.isFinite && Self.edgePaddingRange.contains(value)) {
            copy.edgePadding = nil
        }
        return copy
    }

    // MARK: Resolution

    func resolvedDotDiameter() -> CGFloat { dotSize.diameter }

    // MARK: Bar plate resolution

    struct BarPlateTint: Equatable {
        /// Grey level of the tint colour, 0 = black, 1 = white.
        let white: Double
        let opacity: Double
        let isDark: Bool
    }

    /// The plate's tint. Untouched, it is exactly upstream's: grey 127/255 at `upstreamOpacity`.
    func resolvedBarPlate(upstreamOpacity: Double, systemIsDark: Bool) -> BarPlateTint {
        let dark = barTint.isDark(systemIsDark: systemIsDark)
        return BarPlateTint(
            white: dark ? Self.darkBarTintWhite : Self.upstreamBarTintWhite,
            opacity: barOpacity ?? (dark ? Self.darkBarDefaultOpacity : upstreamOpacity),
            isDark: dark
        )
    }

    /// For ink drawn straight on the plate (the zone divider, the "Auto" running dot): upstream's
    /// black-based tint becomes white-based on a dark bar, a little stronger, because thin white
    /// marks on dark glass read weaker than black ones on light glass.
    func resolvedPlateInk(upstream: DockTint, systemIsDark: Bool) -> DockTint {
        guard barTint.isDark(systemIsDark: systemIsDark), upstream.base == .black else { return upstream }
        return DockTint(base: .white, opacity: min(upstream.opacity + 0.2, 1))
    }

    /// Dot tint for the cases this file can express. `nil` = use the system accent colour.
    func resolvedDotTint(upstream: DockTint, systemIsDark: Bool = false) -> DockTint? {
        switch dotColor {
        case .upstream: return resolvedPlateInk(upstream: upstream, systemIsDark: systemIsDark)
        case .white: return .white(0.95)
        case .black: return .black(0.85)
        case .accent: return nil
        }
    }

    /// Card fill, resting and hover. Untouched tint and opacity return `upstream` itself, so
    /// upstream's `DOCK_CHIP_PILL_FILL` tuning switch keeps working.
    func resolvedCardFill(upstream: DockTintPair, systemIsDark: Bool) -> DockTintPair {
        let dark = cardTint.isDark(systemIsDark: systemIsDark)
        guard dark || cardOpacity != nil else { return upstream }
        let resting = cardOpacity ?? (dark ? Self.darkCardDefaultOpacity : upstream.normal.opacity)
        let hover = min(resting * Self.hoverOpacityFactor, 1)
        let base: DockTintBase = dark ? .black : .white
        return DockTintPair(normal: DockTint(base: base, opacity: resting),
                            emphasized: DockTint(base: base, opacity: hover))
    }

    /// Title colour on the card. A dark card flips the text to white and keeps upstream's opacity,
    /// so "on the desktop" vs "minimised" stays the same step apart.
    ///
    /// A dark **bar** does the same even with a light card: the card's fill is translucent, so what
    /// the title actually sits on is the dark plate showing through.
    func resolvedCardLabel(upstream: DockTint, systemIsDark: Bool) -> DockTint {
        guard cardTint.isDark(systemIsDark: systemIsDark) || barTint.isDark(systemIsDark: systemIsDark) else {
            return upstream
        }
        return DockTint(base: .white, opacity: min(upstream.opacity + 0.1, 1))
    }

    func resolvedCardCornerRadius(scale: CGFloat) -> CGFloat {
        CGFloat(cardCornerRadius ?? Self.upstreamCardCornerRadius) * scale
    }

    // MARK: Spacing resolution
    //
    // Three of upstream's rules are written in terms of the 2pt gap and have to move with it. Each
    // function below returns upstream's constant exactly when `itemSpacing` is untouched
    // (`ForkSpacingTests` pins that), so nothing changes until the slider is moved.

    /// Unscaled gap between entries.
    func resolvedItemSpacing() -> CGFloat { CGFloat(itemSpacing ?? Self.upstreamItemSpacing) }

    /// Unscaled gap before a window card that follows a card of the same app.
    func resolvedSameAppSpacing() -> CGFloat { CGFloat(sameAppSpacing ?? itemSpacing ?? Self.upstreamItemSpacing) }

    /// Unscaled padding at both ends of the plate.
    func resolvedEdgePadding() -> CGFloat { CGFloat(edgePadding ?? Self.upstreamEdgePadding) }

    /// `StripContextMenuZone`: a right-click between two entries opens the bar's own menu only in a
    /// gap at least this wide. It has to sit strictly between an ordinary gap (`spacing`) and the gap
    /// around a zone divider (`spacing + 5 + spacing`: a 1pt hairline with 2pt padding each side,
    /// between two gaps); otherwise either every gap steals the app's menu or no gap opens the bar's.
    /// Upstream: 5 for a spacing of 2. `spacing + 3` keeps that and is below `2 * spacing + 5` for
    /// every spacing >= 0.
    func resolvedContextMenuGapThreshold() -> CGFloat { resolvedItemSpacing() + 3 }

    /// `StripHoverResolution`: how far each entry's hover area reaches into the gap beside it, so the
    /// gap has no dead zone and the boundary is its midpoint. Upstream: 2 for a spacing of 2 (each
    /// side covers the whole gap and the nearer edge wins). Half the gap is enough for any wider
    /// spacing, and keeps the reach into the blank ends of the bar and around dividers small.
    func resolvedHoverGapBridge() -> CGFloat { max(2, resolvedItemSpacing() / 2) }

    /// Width of the scroll view's fade-out at both ends. Upstream: 16, inside its 20pt edge padding,
    /// so a resting first card is never faded. Kept at 80% of the padding so that stays true when
    /// the padding shrinks; never wider than upstream's.
    func resolvedEdgeFadeWidth() -> CGFloat { min(16, resolvedEdgePadding() * 0.8) }

    // MARK: Card width resolution

    /// Whether titles are capped at all. Only "Fit to text" without equal-width cards is uncapped.
    var capsTitleWidth: Bool { titleMode != .fit || equalWidthCards }

    /// Unscaled cap on the title's width; `.greatestFiniteMagnitude` when uncapped. Untouched, this is
    /// upstream's 140.
    func resolvedTitleCap() -> CGFloat {
        guard capsTitleWidth else { return .greatestFiniteMagnitude }
        return CGFloat((maxCardWidth ?? Self.upstreamMaxCardWidth) - Self.cardChrome)
    }

    /// Width of the title box for a title that measures `intrinsic` (already scaled), under a scaled
    /// `cap`. Upstream: the title's own width up to the cap. Equal-width cards: always the cap.
    func resolvedLabelWidth(intrinsic: CGFloat, cap: CGFloat) -> CGFloat {
        equalWidthCards ? ceil(cap) : ceil(min(intrinsic, cap))
    }

    /// Changes exactly when an override that affects title-box width changes. `ChipView` uses it as
    /// the title box's identity so such a change *snaps* to the new width. Upstream animates the box
    /// over 0.6s and has the panel follow frame by frame, but only for title changes it is told
    /// about; an animation the panel is not following would leave the glass plate and the cards
    /// out of step for its whole duration.
    var layoutIdentity: String {
        "\(titleFontOffset)|\(maxCardWidth.map { String($0) } ?? "-")|\(titleMode.rawValue)|\(equalWidthCards)"
    }

    /// Ellipsis in the middle instead of at the end.
    var truncatesTitleInMiddle: Bool { titleMode == .middle }

    /// `upstream` is the size upstream computes (`max(10, 12 * scale)`). The offset is applied after
    /// that floor, and the result never drops below 8pt.
    func resolvedTitleFontSize(upstream: CGFloat) -> CGFloat {
        guard titleFontOffset != 0 else { return upstream }
        return max(8, upstream + CGFloat(titleFontOffset))
    }
}

/// fork: `ForkAppearance` <-> UserDefaults. One key per option, under upstream's prefix so they sort
/// with the rest. A missing key is the upstream state, so "reset" is "remove the keys".
enum ForkAppearanceStorage {
    enum Keys {
        static let dotColor = "com.tungsten.edge.appearance.dotColor"
        static let dotSize = "com.tungsten.edge.appearance.dotSize"
        static let cardTint = "com.tungsten.edge.appearance.cardTint"
        static let cardOpacity = "com.tungsten.edge.appearance.cardOpacity"
        static let cardCornerRadius = "com.tungsten.edge.appearance.cardCornerRadius"
        static let titleFontOffset = "com.tungsten.edge.appearance.titleFontOffset"
        static let maxCardWidth = "com.tungsten.edge.appearance.maxCardWidth"
        static let titleMode = "com.tungsten.edge.appearance.titleMode"
        static let equalWidthCards = "com.tungsten.edge.appearance.equalWidthCards"
        static let bottomMargin = "com.tungsten.edge.appearance.bottomMargin"
        static let itemSpacing = "com.tungsten.edge.appearance.itemSpacing"
        static let sameAppSpacing = "com.tungsten.edge.appearance.sameAppSpacing"
        static let barTint = "com.tungsten.edge.appearance.barTint"
        static let barOpacity = "com.tungsten.edge.appearance.barOpacity"
        static let edgePadding = "com.tungsten.edge.appearance.edgePadding"
    }

    static func load(from defaults: UserDefaults) -> ForkAppearance {
        var value = ForkAppearance()
        value.dotColor = defaults.string(forKey: Keys.dotColor).flatMap(ForkAppearance.DotColor.init) ?? .upstream
        value.dotSize = defaults.string(forKey: Keys.dotSize).flatMap(ForkAppearance.DotSize.init) ?? .upstream
        value.cardTint = defaults.string(forKey: Keys.cardTint).flatMap(ForkAppearance.CardTint.init) ?? .upstream
        value.cardOpacity = DefaultsValueParsing.finiteNumericValue(defaults.object(forKey: Keys.cardOpacity))
        value.cardCornerRadius = DefaultsValueParsing.finiteNumericValue(defaults.object(forKey: Keys.cardCornerRadius))
        value.titleFontOffset = (defaults.object(forKey: Keys.titleFontOffset) as? Int) ?? 0
        value.maxCardWidth = DefaultsValueParsing.finiteNumericValue(defaults.object(forKey: Keys.maxCardWidth))
        value.titleMode = defaults.string(forKey: Keys.titleMode).flatMap(ForkAppearance.TitleMode.init) ?? .upstream
        value.equalWidthCards = defaults.bool(forKey: Keys.equalWidthCards)
        value.bottomMargin = DefaultsValueParsing.finiteNumericValue(defaults.object(forKey: Keys.bottomMargin))
        value.itemSpacing = DefaultsValueParsing.finiteNumericValue(defaults.object(forKey: Keys.itemSpacing))
        value.sameAppSpacing = DefaultsValueParsing.finiteNumericValue(defaults.object(forKey: Keys.sameAppSpacing))
        value.barTint = defaults.string(forKey: Keys.barTint).flatMap(ForkAppearance.BarTint.init) ?? .upstream
        value.barOpacity = DefaultsValueParsing.finiteNumericValue(defaults.object(forKey: Keys.barOpacity))
        value.edgePadding = DefaultsValueParsing.finiteNumericValue(defaults.object(forKey: Keys.edgePadding))
        return value.sanitized
    }

    /// Writes only what differs from upstream and removes the rest, so an untouched option leaves no
    /// trace on disk.
    static func save(_ value: ForkAppearance, to defaults: UserDefaults) {
        func write(_ object: Any?, _ key: String) {
            if let object { defaults.set(object, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        let value = value.sanitized
        write(value.dotColor == .upstream ? nil : value.dotColor.rawValue, Keys.dotColor)
        write(value.dotSize == .upstream ? nil : value.dotSize.rawValue, Keys.dotSize)
        write(value.cardTint == .upstream ? nil : value.cardTint.rawValue, Keys.cardTint)
        write(value.cardOpacity, Keys.cardOpacity)
        write(value.cardCornerRadius, Keys.cardCornerRadius)
        write(value.titleFontOffset == 0 ? nil : value.titleFontOffset, Keys.titleFontOffset)
        write(value.maxCardWidth, Keys.maxCardWidth)
        write(value.titleMode == .upstream ? nil : value.titleMode.rawValue, Keys.titleMode)
        write(value.equalWidthCards ? true : nil, Keys.equalWidthCards)
        write(value.bottomMargin, Keys.bottomMargin)
        write(value.itemSpacing, Keys.itemSpacing)
        write(value.sameAppSpacing, Keys.sameAppSpacing)
        write(value.barTint == .upstream ? nil : value.barTint.rawValue, Keys.barTint)
        write(value.barOpacity, Keys.barOpacity)
        write(value.edgePadding, Keys.edgePadding)
    }
}
