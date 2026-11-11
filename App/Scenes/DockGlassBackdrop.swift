import AppKit
import SwiftUI

/// Floating panel backplate: native Liquid Glass when `macOS 26 + switch on + background window built`,
/// otherwise
/// the existing frosted material.
///
/// **`usesLiquidGlass` is passed in explicitly, with no default value**, the existing rule of `scale` /
/// `hoverStyle`
/// (Taskbar Size Tiers project rule): omitting it is a compile error rather than silently rendering one path.
/// It used to be a mutable static, which SwiftUI can't observe, so views still read the old value after panel
/// teardown.
struct DockGlassBackdrop: View {
    /// Material for the fallback path (`DockThemeTokens.panelMaterial`). Used when glass is unavailable.
    let material: DockPanelMaterial
    let usesLiquidGlass: Bool
    var cornerRadius: CGFloat = DockShape.panelCornerRadius
    var saturation: Double = 1.0
    var thicknessEnabled: Bool = false
    /// fork: whether this plate follows Appearance > Bar (tint and opacity). Only the taskbar passes
    /// true. `false` is the right default here, not a trap: every other panel must stay upstream's.
    var followsForkBarStyle: Bool = false

    var body: some View {
        Group {
            if #available(macOS 26.0, *), usesLiquidGlass {
                DockLiquidGlassPlate(
                    cornerRadius: cornerRadius,
                    configuration: DockGlassPresentation.configuration,
                    followsForkBarStyle: followsForkBarStyle
                )
                // The glass is a view in its own right and must opt out of hit testing explicitly;
                // **it can't be attached outside the Group**: that would change the fallback path too, and
                // the fallback path must match
                // the pre-change state pixel for pixel and behavior for behavior.
                .allowsHitTesting(false)
            } else {
                DockVisualEffectView(material: material)
                    .dockBackdropSaturation(saturation)
                    .forkBarFallbackStyle(enabled: followsForkBarStyle)   // fork: identity when untouched
            }
        }
        .onAppear {
            DockGlassPresentation.logResolvedPath(compositeActive: usesLiquidGlass)
            DockEffectSwitches.logActiveOverrides(
                material: material,
                saturation: saturation,
                thickness: thicknessEnabled
            )
        }
    }
}

/// Backplate shared by the five floating panels (taskbar / drawer capsule / drawer / folder popup / shelf
/// popup).
///
/// Bundles "backplate + 2pt outset + rounded clip" in one place: the five call sites each had their own copy,
/// and missing any of them when glass became the default would leave that panel with a different material
/// (that is how the drawer capsule ended up visibly brighter and more solid than the taskbar in a screenshot).
///
/// `.padding(-2)` is a leftover from the frosted-material era (avoids seams at the material edge). It is
/// harmless for glass,
/// but **clips a stroke drawn inside the backplate**, so the edge highlight goes through `View.dockPanelRim`,
/// attached at the outermost level of the panel body, not drawn here.
struct DockPanelBackdrop: View {
    let theme: DockThemeTokens
    let cornerRadius: CGFloat
    let usesLiquidGlass: Bool
    var followsForkBarStyle: Bool = false   // fork, see `DockGlassBackdrop`

    var body: some View {
        DockGlassBackdrop(material: theme.effectivePanelMaterial,
                          usesLiquidGlass: usesLiquidGlass,
                          cornerRadius: cornerRadius,
                          saturation: theme.effectiveBackdropSaturation,
                          thicknessEnabled: theme.drawsEffectiveThickness,
                          followsForkBarStyle: followsForkBarStyle)
            .padding(-2)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .ignoresSafeArea()
    }
}

extension View {
    /// Panel stroke. Each path draws its own: frosted material uses the `DockThemeTokens` ring, glass uses a
    /// uniform white highlight
    /// measured to match the native Dock. The whole-frame drop-hit highlight (`highlighted`) is **stacked on
    /// top of** both,
    /// replacing neither layer; the decision is in `DockPanelRimPlan`, which records where this rule came from.
    ///
    /// **The glass highlight must be drawn here, not inside `DockLiquidGlassPlate`.** The backplate view is
    /// wrapped in
    /// the legacy `.padding(-2)` (frosted material needs a 2pt outset to avoid edge seams), so the glass
    /// view's frame is
    /// 2pt larger than the bar, and the ring `strokeBorder` draws inward lands exactly in the clipped 2pt.
    /// Measured: at a width of
    /// 4pt only half shows (4px of 8px), and 0.5pt disappears entirely. The overlay here is attached to the
    /// whole body,
    /// positioned at the bar's real edge.
    func dockPanelRim<S: ShapeStyle>(
        cornerRadius: CGFloat,
        style: S,
        lineWidth: CGFloat,
        usesLiquidGlass: Bool,
        highlighted: Bool = false
    ) -> some View {
        let configuration = DockGlassPresentation.configuration
        let strokeWidth = DockPanelRimPlan.themeStrokeWidth(usesLiquidGlass: usesLiquidGlass,
                                                            highlighted: highlighted,
                                                            lineWidth: lineWidth)
        return overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(style, lineWidth: strokeWidth)
        }
        .overlay {
            if DockPanelRimPlan.glassRimVisible(usesLiquidGlass: usesLiquidGlass) {
                DockGlassRim(cornerRadius: cornerRadius, configuration: configuration)
            }
        }
    }
}

/// Edge highlight of the glass backplate.
///
/// **Two pixels wide + modulated per corner**, both measured pixel by pixel against the native Dock:
///
/// | Position | Highlight − backplate |
/// |---|---|
/// | Four long edges | +67 (profile 148 / 120 / backplate, one full pixel + one half step) |
/// | Top-left / bottom-right corners | +76 / +81 (brighter than the long edges) |
/// | Top-right / bottom-left corners | +7 / +5 (highlight almost gone) |
///
/// Background interference is ruled out: backplate inside the four corners 79.8–82.5, wallpaper outside the
/// corners 30.6–36.6, about the same in all four,
/// so the brightness difference is a property of **the highlight itself**.
///
/// **A linear gradient can't make this shape**: the bright part is the ↖↘ diagonal and the dark part the ↗↙
/// one, while a linear gradient
/// is monotonic along its axis and can't brighten two opposite corners at once. The original `topLeading ->
/// bottomTrailing` diagonal
/// gradient got the direction half right but the shape inverted (it darkened ↘), and on an 800pt-wide bar the
/// gradient had fully decayed
/// by the horizontal midpoint: measured with parameters maxed out, the left edge clipped at 254 while the
/// middle was only 158. **Don't go back to that approach.**
///
/// Everything used is SwiftUI available since macOS 12 (`RadialGradient` / `mask` / `blendMode`),
/// so there is no availability annotation; it is just **in practice** only attached on the glass path.
private struct DockGlassRim: View {
    let cornerRadius: CGFloat
    let configuration: DockLiquidGlassConfiguration

    var body: some View {
        let width = CGFloat(configuration.borderLineWidth)
        ZStack {
            // Outer ring: the full pixel.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(configuration.borderPeakOpacity),
                              lineWidth: width)
            // Inner ring: the half step right inside the outer ring. With only the outer ring the peak is the
            // same but the visual weight is half,
            // which reads as "not as bright as native" (feedback 2026-08-16).
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .inset(by: width)
                .strokeBorder(Color.white.opacity(configuration.borderInnerOpacity),
                              lineWidth: width)
        }
        // Draw the whole ring at peak level, then use the mask to press the long edges down to edgeLevel and
        // cut the ↗↙ corners to almost nothing.
        .mask { cornerModulation }
    }

    /// Corner modulation mask. SwiftUI's `.mask` takes **alpha**, not luminance, so darkening means cutting
    /// alpha,
    /// hence `.destinationOut` for the two ↗↙ corners.
    private var cornerModulation: some View {
        let radius = cornerRadius * CGFloat(configuration.borderCornerSpread)
        return ZStack {
            Color.white.opacity(configuration.borderEdgeLevel)
            // ↖↘: brighten to full level.
            cornerGradient(.topLeading, radius: radius, color: .white)
            cornerGradient(.bottomTrailing, radius: radius, color: .white)
            // ↗↙: cut out, leaving only a trace.
            cornerGradient(.topTrailing, radius: radius,
                           color: .white.opacity(configuration.borderCornerCut))
                .blendMode(.destinationOut)
            cornerGradient(.bottomLeading, radius: radius,
                           color: .white.opacity(configuration.borderCornerCut))
                .blendMode(.destinationOut)
        }
        // Without it, destinationOut would cut through to the backplate instead of acting only inside this
        // mask.
        .compositingGroup()
    }

    private func cornerGradient(_ center: UnitPoint, radius: CGFloat, color: Color) -> some View {
        RadialGradient(colors: [color, color.opacity(0)],
                       center: center,
                       startRadius: 0,
                       endRadius: radius)
    }
}

enum DockGlassPresentation {
    static let configuration = DockLiquidGlassConfiguration.resolve()

    /// Whether glass compositing can be built for the taskbar. Three gates: system ≥ 26, switch on, both
    /// SkyLight symbols resolved.
    static var shouldAttemptTaskbarComposite: Bool {
        let glassAvailable: Bool
        if #available(macOS 26.0, *) { glassAvailable = true } else { glassAvailable = false }
        // Short-circuit: don't dlopen SkyLight on older systems.
        let compositeAvailable = glassAvailable && TEDockGlassCanSetWindowBackgroundBlur()
        return configuration.renderPath(
            isGlassAPIAvailable: glassAvailable,
            isCompositeAvailable: compositeAvailable
        ) == .layeredTaskbar
    }

    /// Prints one line at launch saying which path this run takes. `print` rather than `Logger`: some
    /// environments can't read back
    /// the unified log (same reason as `[edgehover]`).
    static func logResolvedPath(compositeActive: Bool) {
        guard configuration.isEnabled else { return }
        if compositeActive {
            let c = configuration
            let rim = "peak=\(c.borderPeakOpacity) edge=\(c.borderEdgeLevel) "
                + "cut=\(c.borderCornerCut) spread=\(c.borderCornerSpread) w=\(c.borderLineWidth)"
            print("[glass] taskbar composite active, clearTint=\(c.clearTintOpacity), rim(\(rim)), "
                + "background=\(c.backgroundMaterialOpacity), windowBlur=\(c.windowBlurRadius)")
        } else if #available(macOS 26.0, *) {
            print("[glass] composite unavailable; using NSVisualEffectView")
        } else {
            print("[glass] enabled but macOS < 26; using NSVisualEffectView")
        }
    }
}

/// The glass backplate itself. Shared by the five floating panels (only the taskbar was wired during the
/// spike).
@available(macOS 26.0, *)
private struct DockLiquidGlassPlate: View {
    let cornerRadius: CGFloat
    let configuration: DockLiquidGlassConfiguration
    var followsForkBarStyle: Bool = false
    /// fork: observed so the bar repaints live while the Appearance sliders move.
    @ObservedObject private var fork = ForkAppearanceModel.shared

    var body: some View {
        let inset = CGFloat(configuration.contentInset)
        // Outset first, then inset: leaves margin for the glass's own edge rendering, then negative padding
        // restores the layout size.
        let shape = RoundedRectangle(
            cornerRadius: cornerRadius + inset,
            style: .continuous
        ).inset(by: inset)
        // fork: untouched (and for every panel but the bar) this is upstream's grey 127 at
        // `clearTintOpacity`, value for value.
        let plate = followsForkBarStyle
            ? fork.barPlate(upstreamOpacity: configuration.clearTintOpacity)
            : ForkAppearance.upstream.resolvedBarPlate(upstreamOpacity: configuration.clearTintOpacity, systemIsDark: false)
        let tint = Color(nsColor: NSColor(deviceWhite: CGFloat(plate.white), alpha: 1))
            .opacity(plate.opacity)

        shape
            .fill(Color.clear)
            .glassEffect(.clear.tint(tint).interactive(false), in: shape)
            // fork: the glass's own highlights and refraction follow the scheme too. The app is
            // pinned to light, so without this a dark tint sits on light-mode glass.
            .environment(\.colorScheme, plate.isDark ? .dark : .light)
            .background {
                shape.fill(Color.white.opacity(configuration.whiteOverlayOpacity))
            }
            // The edge highlight is **not drawn here**, see `View.dockPanelRim`: the backplate is wrapped in
            // `.padding(-2)`,
            // so anything drawn at this layer gets clipped.
            // The panel never becomes the key window; unless forced, the material renders as "inactive" and
            // turns grey.
            .materialActiveAppearance(.active)
            .environment(\.appearsActive, true)
            .padding(-inset)
    }

}

/// WindowServer side of glass compositing. It owns a click-through panel of its own, so the window blur
/// doesn't composite the
/// SwiftUI glass in the content window a second time.
///
/// **No shadow is drawn here.** The frame of this view's window equals the backplate exactly, so a layer
/// shadow drawn outside the window would be clipped
/// entirely; the drop shadow belongs to the content window's `.dockShadow`, which has a 20pt transparent
/// margin.
final class DockTaskbarLiquidGlassBackgroundView: NSView {
    private let liveBackdropSubscriptionView = NSVisualEffectView()
    private let materialView = NSVisualEffectView()
    private let dimmingOverlayView = NSView()
    private var configuration: DockLiquidGlassConfiguration
    private var plateCornerRadius: CGFloat

    init(
        frame frameRect: NSRect,
        cornerRadius: CGFloat,
        configuration: DockLiquidGlassConfiguration
    ) {
        self.configuration = configuration
        self.plateCornerRadius = cornerRadius
        super.init(frame: frameRect)

        wantsLayer = true
        configureVisualEffectView(liveBackdropSubscriptionView)
        // Very-low-alpha subscription layer: keeps WindowServer feeding the content behind into this window,
        // otherwise the background blur freezes on one frame.
        liveBackdropSubscriptionView.material = .underWindowBackground
        liveBackdropSubscriptionView.alphaValue = 3.0 / 255.0

        configureVisualEffectView(materialView)
        materialView.material = .menu
        materialView.alphaValue = configuration.backgroundMaterialOpacity

        dimmingOverlayView.wantsLayer = true
        for view in [liveBackdropSubscriptionView, materialView, dimmingOverlayView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        apply(cornerRadius: cornerRadius, configuration: configuration)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateOverlayColor()
    }

    func apply(
        cornerRadius: CGFloat,
        configuration: DockLiquidGlassConfiguration
    ) {
        guard cornerRadius != plateCornerRadius || configuration != self.configuration else { return }
        self.configuration = configuration
        plateCornerRadius = cornerRadius
        materialView.alphaValue = configuration.backgroundMaterialOpacity
        materialView.isHidden = configuration.backgroundMaterialOpacity <= 0
        dimmingOverlayView.isHidden = configuration.dimmingOpacity <= 0
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        // Not a visual layer: WindowServer needs a shape with non-zero alpha before it does background blur.
        layer?.backgroundColor = NSColor.black
            .withAlphaComponent(configuration.backgroundPlateOpacity)
            .cgColor
        for view in [liveBackdropSubscriptionView, materialView, dimmingOverlayView] {
            view.wantsLayer = true
            view.layer?.cornerRadius = cornerRadius
            view.layer?.cornerCurve = .continuous
            view.layer?.masksToBounds = true
        }
        updateOverlayColor()
    }

    private func configureVisualEffectView(_ view: NSVisualEffectView) {
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
    }

    private func updateOverlayColor() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = isDark ? NSColor.black : NSColor.white
        dimmingOverlayView.layer?.backgroundColor = color
            .withAlphaComponent(configuration.dimmingOpacity)
            .cgColor
    }
}
