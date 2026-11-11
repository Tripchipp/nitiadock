import CoreGraphics
import Foundation

enum DockLiquidGlassRenderPath: Equatable {
    case visualEffectFallback
    case layeredTaskbar
}

/// Tunable parameters of the liquid glass backing.
///
/// **Only "how the glass backing is drawn" belongs here, no geometry.** Panel height, corner radius and
/// bottom offset from the screen all come from `DockSize.metrics` and `DockShape.panelCornerRadius` (project
/// rule: the single source of geometry). A second set of sizes on the glass would break the four-tier
/// scaling, because `scale` is defined as `panelHeight / 52`.
///
/// **No shadow either.** The drop shadow is drawn by `.dockShadow(theme.stripShadow)` on the SwiftUI side, in
/// the content window's 20pt transparent margin; drawing it on the background window's layer was tried, but
/// that window's frame equals the backing itself, and a layer shadow outside the window is clipped entirely.
/// Net effect: no shadow in glass mode. Do not change it back.
struct DockLiquidGlassConfiguration: Equatable {
    let isEnabled: Bool
    /// Gray tint strength of `Glass.clear`. The glass itself is too transparent and icons become
    /// unrecognizable (the reason pure native glass was rejected on 2026-07-30); this layer is the main
    /// handle for pulling transparency back into a usable range.
    let clearTintOpacity: Double
    /// A whitening layer **below** the glass. Default 0.
    let whiteOverlayOpacity: Double
    /// The dimming/brightening layer in the background window (black or white depending on light/dark).
    /// Default 0.
    ///
    /// **Drawn once, in the background window only.** The content window used to stack a hardcoded black
    /// layer too, and the two colors disagreed (always black on the SwiftUI side, switching with appearance
    /// on the background window side); invisible at the default 0, exposed as soon as it was tuned.
    let dimmingOpacity: Double
    /// **Peak** alpha of the edge highlight, at the top-left / bottom-right corners. The whole ring is drawn
    /// at it and then pulled down by the mask.
    ///
    /// **Cannot be computed directly as `α = 78/171 ≈ 0.45`**: on a straight edge a 0.5pt stroke sits exactly
    /// on one full row of pixels, on a rounded corner it is diagonal and thinned by antialiasing, so the same
    /// alpha yields only about 2/3 at the corner. 0.75 was tuned by measurement (0.45 -> only +52 at the
    /// corner, 0.62 -> +64, 0.75 -> +73; with the wallpaper on the left raising the backing baseline by about
    /// 8, it already lands on native's +76 / +81).
    ///
    /// **This is the most valuable knob for "does it look native".** The native Dock uses this ring to draw
    /// the outline out of the background; without it the bar blurs into the background as if painted straight
    /// on the screen, and even the corners look squarer than they are (measured: NitiaDock's 16pt corner
    /// radius is actually larger than native's 14pt, yet looks squarer).
    let borderPeakOpacity: Double
    /// Ratio of the four long edges relative to the peak. The long edges need an absolute alpha of 0.375 (+67
    /// above the backing), divided by the peak 0.75 gives 0.5. **Changing the peak requires changing this
    /// too**, or the long edges brighten with it.
    let borderEdgeLevel: Double
    /// Cut amount at the top-right / bottom-left corners (applied to `borderEdgeLevel`).
    /// Native's highlight at these two corners is only +5 / +7 above the backing, practically none.
    let borderCornerCut: Double
    /// Radius of the corner modulation, in **multiples of the corner radius** (so it scales with the tier).
    let borderCornerSpread: Double
    /// Stroke width. Native's outermost line measures 1px @2x = **0.5pt**, much thinner than intuition
    /// suggests.
    let borderLineWidth: Double
    /// A second, darker line drawn right **inside** the outer ring, making up native's two-pixel bright edge.
    ///
    /// The native top edge profile measures `148 -> 120 -> 81 (backing)`: one full pixel + one half step, two
    /// pixels in total. With a single line the peak is still 148, but **the visual weight is only half, and
    /// to the eye it is "not as bright as native"** (2026-08-16 feedback; measuring showed the peak had
    /// matched all along and the width was what was missing). Solving back: raising the backing from 84 to
    /// 120 needs `α = (120 − 84) / (255 − 84) ≈ 0.21`.
    let borderInnerOpacity: Double
    /// Opacity of the `.menu` material layer in the background window, adding a bit of solidity beyond the
    /// glass. Default 0.
    let backgroundMaterialOpacity: Double
    /// WindowServer blur radius of the background window (SkyLight). **Default 0 = unused.**
    ///
    /// This value was copied from BestDock's on-device layer stack (6pt there). In NitiaDock's compositing it
    /// **only does harm**: WindowServer's window background blur applies to the **window rectangle**, not the
    /// rounded corners we draw, so at the four corners the area "outside the rounded corner, inside the
    /// bounding rectangle" is blurred square, and the blur's own spread bleeds out further. Reported
    /// 2026-08-16 as "something is off outside the rounded corners"; it disappeared on the spot after A/B to
    /// 0.
    ///
    /// Transparency **does not depend on it**: the backing luminance is set by `.glassEffect(.clear)` plus
    /// `clearTintOpacity`, and measured, blur 6 -> 0 moves the backing only from 138.4 to 138.5.
    ///
    /// To re-enable it later: **the rounded corners must be solved first**. Either give the background window
    /// itself a rounded shape (today only the content layer is rounded, the window shape is still a
    /// rectangle), or do not use window-level blur. It also **must be drawn on a window separate from the
    /// glass host**: setting this value on the same window that hosts the SwiftUI glass composites the
    /// vertical lighting a second time (measured with controlled color bars: top/bottom average luminance
    /// goes from about 131/127 to 101/163).
    let windowBlurRadius: Double
    /// How much the glass shape is expanded and then inset again, leaving headroom for the glass's own edge
    /// rendering.
    let contentInset: Double
    /// Opacity of the black base on the background window's root layer. **Not a look parameter**:
    /// WindowServer needs a shape with non-zero alpha before it will blur this window's background; this is
    /// the minimal anchor for it.
    let backgroundPlateOpacity: Double

    func renderPath(
        isGlassAPIAvailable: Bool,
        isCompositeAvailable: Bool
    ) -> DockLiquidGlassRenderPath {
        guard isEnabled, isGlassAPIAvailable, isCompositeAvailable else {
            return .visualEffectFallback
        }
        return .layeredTaskbar
    }

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        Self(
            // **On by default** (graduated 2026-08-17). Before that it was "off by default, on only with
            // `DOCK_LIQUID_GLASS=1`", which is right for an exploration phase; keeping it off after the look
            // was signed off only causes "running the wrong instance": the process relaunched automatically
            // after a system restart has no environment variables and shows the old look without glass (this
            // did happen). `=0` is still the switch that turns it off; macOS 12-25 uses the frosted glass
            // fallback in `renderPath`, unrelated to this.
            isEnabled: trimmed(DebugSwitch.liquidGlass.value(in: environment)) != "0",
            clearTintOpacity: boundedDouble(
                DebugSwitch.liquidGlassClearTint.value(in: environment),
                range: 0 ... 1,
                fallback: 0.4
            ),
            whiteOverlayOpacity: boundedDouble(
                DebugSwitch.liquidGlassWhiteOverlay.value(in: environment),
                range: 0 ... 1,
                fallback: 0
            ),
            dimmingOpacity: boundedDouble(
                DebugSwitch.liquidGlassDimming.value(in: environment),
                range: 0 ... 1,
                fallback: 0
            ),
            borderPeakOpacity: boundedDouble(
                DebugSwitch.liquidGlassBorder.value(in: environment),
                range: 0 ... 1,
                fallback: 0.75
            ),
            borderEdgeLevel: boundedDouble(
                DebugSwitch.liquidGlassBorderEdge.value(in: environment),
                range: 0 ... 1,
                fallback: 0.5
            ),
            borderCornerCut: boundedDouble(
                DebugSwitch.liquidGlassBorderCut.value(in: environment),
                range: 0 ... 1,
                fallback: 0.92
            ),
            borderCornerSpread: boundedDouble(
                DebugSwitch.liquidGlassBorderSpread.value(in: environment),
                range: 0.5 ... 6,
                fallback: 2.2
            ),
            borderLineWidth: boundedDouble(
                DebugSwitch.liquidGlassBorderWidth.value(in: environment),
                range: 0 ... 4,
                fallback: 0.5
            ),
            borderInnerOpacity: boundedDouble(
                DebugSwitch.liquidGlassBorderInner.value(in: environment),
                range: 0 ... 1,
                fallback: 0.21
            ),
            backgroundMaterialOpacity: boundedDouble(
                DebugSwitch.liquidGlassBackgroundOpacity.value(in: environment),
                range: 0 ... 1,
                fallback: 0
            ),
            windowBlurRadius: boundedDouble(
                DebugSwitch.liquidGlassWindowBlur.value(in: environment),
                range: 0 ... 64,
                fallback: 0
            ),
            contentInset: boundedDouble(
                DebugSwitch.liquidGlassContentInset.value(in: environment),
                range: 0 ... 12,
                fallback: 4
            ),
            backgroundPlateOpacity: 0.001
        )
    }

    private static func boundedDouble(
        _ raw: String?,
        range: ClosedRange<Double>,
        fallback: Double
    ) -> Double {
        guard let raw = trimmed(raw),
              let value = Double(raw),
              value.isFinite,
              range.contains(value) else { return fallback }
        return value
    }

    private static func trimmed(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

enum DockLiquidGlassPanelGeometry {
    /// Background window frame = the **visible backing rectangle**, i.e. the content window minus its 20pt
    /// transparent shadow margin.
    ///
    /// The content window keeps the transparent margin (the shadow lives there, and a set of drop zones / hit
    /// tests convert via "window frame minus shadowPadding"), while the background window must fit the
    /// backing exactly, or WindowServer's blur leaks out past the glass edge.
    static func backgroundFrame(
        for contentPanelFrame: CGRect,
        shadowPadding: CGFloat
    ) -> CGRect {
        guard shadowPadding > 0 else { return contentPanelFrame }
        return contentPanelFrame.insetBy(dx: shadowPadding, dy: shadowPadding)
    }
}

enum DockLiquidGlassPanelRole: Equatable {
    case background
    case content
}

enum DockLiquidGlassPanelLifecyclePlan {
    static func ordering(
        isCompositeActive: Bool,
        shouldShow: Bool
    ) -> [DockLiquidGlassPanelRole] {
        guard isCompositeActive else { return [.content] }
        return shouldShow ? [.background, .content] : [.content, .background]
    }
}
