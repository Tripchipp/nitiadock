import SwiftUI

// fork: the SwiftUI side of the Appearance overrides. `ForkAppearance` (Core/Support) decides
// values; this file only turns them into colours and views, the same split upstream keeps between
// `DockThemeTokens` and `DockTheme.swift`.

extension ForkAppearanceModel {
    /// Card fill (resting + hover) for the current overrides.
    func cardFill(theme: DockThemeTokens) -> DockTintPair {
        value.resolvedCardFill(upstream: theme.effectiveChipPillFill, systemIsDark: systemIsDark)
    }

    /// The bar plate's tint for the current overrides.
    func barPlate(upstreamOpacity: Double) -> ForkAppearance.BarPlateTint {
        value.resolvedBarPlate(upstreamOpacity: upstreamOpacity, systemIsDark: systemIsDark)
    }

    /// Ink drawn straight on the bar's plate (zone divider).
    func plateInk(_ upstream: DockTint) -> DockTint {
        value.resolvedPlateInk(upstream: upstream, systemIsDark: systemIsDark)
    }

    /// Title colour on a card. Pass the upstream tint for the card's state (active / inactive).
    func cardLabel(_ upstream: DockTint) -> DockTint {
        value.resolvedCardLabel(upstream: upstream, systemIsDark: systemIsDark)
    }
}

/// The running-app dot under an icon, shared by `ChipView` and `LauncherChip`.
///
/// Untouched, it is pixel-identical to the `Circle` it replaced: upstream's tint, 4pt, 2pt above
/// the card's bottom edge. Larger sizes grow around the same centre, so the dot does not drift
/// towards the icon.
struct ForkRunningDot: View {
    let theme: DockThemeTokens
    @ObservedObject private var fork = ForkAppearanceModel.shared

    private static let upstreamDiameter: CGFloat = 4
    private static let upstreamBottomPadding: CGFloat = 2

    var body: some View {
        let diameter = fork.value.resolvedDotDiameter()
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .padding(.bottom, max(0, Self.upstreamBottomPadding - (diameter - Self.upstreamDiameter) / 2))
    }

    private var color: Color {
        // nil = the accent case, which only the SwiftUI layer can name.
        fork.value.resolvedDotTint(upstream: theme.runningDot, systemIsDark: fork.systemIsDark)?.color
            ?? Color.accentColor
    }
}

// MARK: - Bar plate on the pre-Liquid-Glass path

/// macOS 12-25 (or `DOCK_LIQUID_GLASS=0`) draw the plate with an `NSVisualEffectView`. There is no
/// tint to turn there, so the closest equivalents are used: a dark bar renders the material in the
/// dark appearance, and opacity fades the material. Untouched, both modifiers are skipped entirely,
/// because even an identity `.opacity(1)` can change how the material composites.
private struct ForkBarFallbackStyle: ViewModifier {
    let enabled: Bool
    @ObservedObject private var fork = ForkAppearanceModel.shared

    func body(content: Content) -> some View {
        let value = fork.value
        if enabled, value.barTint != .upstream || value.barOpacity != nil {
            let plate = fork.barPlate(upstreamOpacity: 1)
            content
                .environment(\.colorScheme, plate.isDark ? .dark : .light)
                .opacity(value.barOpacity == nil ? 1 : max(0.05, plate.opacity))
        } else {
            content
        }
    }
}

extension View {
    func forkBarFallbackStyle(enabled: Bool) -> some View {
        modifier(ForkBarFallbackStyle(enabled: enabled))
    }
}
