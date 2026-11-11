import CoreGraphics

/// Taskbar size steps. **Steps are defined by panel height and the scale factor is
/// derived from it.** The reverse (pick a factor like 0.85, then compute the height)
/// gives heights like 44.2, putting corner radii, icons and separators on half pixels.
enum DockSize: String, CaseIterable {
    case small
    case medium
    case large
    case extraLarge

    static let `default` = DockSize.medium

    /// Four steps 8pt apart; the middle step matches the native Dock.
    ///
    /// **Middle step changed from 52 to 54 on 2026-08-16 to match the measured native macOS 26
    /// Dock.** In the same round the icon went from 36 to 40 (`ChipHoverVisual.bareIconSize`);
    /// the two must change together: a native @2x screenshot measures bar height 108px = 54pt
    /// with 21px = 10.5pt of padding above and below the icon, and (54 − 40) / 2 = 7pt nominal
    /// padding plus the roughly 18% transparent margin built into Apple's icon assets gives
    /// exactly 10.5pt. Changing only one moves the icon/bar-height ratio off the native 0.741.
    ///
    /// This overturns the earlier freeze contract that the
    /// middle step be byte-identical to before 2026-07-30.
    var panelHeight: CGFloat {
        switch self {
        case .small: return 46
        case .medium: return 54
        case .large: return 62
        case .extraLarge: return 70
        }
    }

    /// Every size that scales with the step is multiplied by it. Always `1.0` for the middle step.
    var scale: CGFloat { panelHeight / DockSize.medium.panelHeight }

    var title: String {
        switch self {
        case .small: return String(localized: "Small")
        case .medium: return String(localized: "Medium")
        case .large: return String(localized: "Large")
        case .extraLarge: return String(localized: "Extra Large")
        }
    }

    /// Single source of panel geometry: the AppKit side (PanelCoordinator) and the
    /// SwiftUI side both read it from here instead of each computing their own.
    var metrics: PanelLayoutMetrics {
        PanelLayoutMetrics(
            panelHeight: panelHeight,
            // Shadow margin **does not scale with the step**: shadow tokens are frozen (the dark
            // set was already 3pt over budget), and scaling them would change the finalized look.
            shadowPadding: PanelLayoutMetrics.shadowPadding,
            // An expression rather than a literal: the relation 52 + 2×20 = 92 used to exist
            // only in a comment, so the window height was easily missed when the height changed.
            windowHeight: panelHeight + 2 * PanelLayoutMetrics.shadowPadding,
            bottomGap: 8,
            outerMargin: 12,
            capsuleWidth: panelHeight,
            capsuleGap: 8,
            minimumDockWidth: 120 * scale,
            minimumDrawerExtent: 120
        )
    }
}

struct PanelLayoutMetrics: Equatable {
    var panelHeight: CGFloat
    var shadowPadding: CGFloat
    var windowHeight: CGFloat
    var bottomGap: CGFloat
    var outerMargin: CGFloat
    var capsuleWidth: CGFloat
    var capsuleGap: CGFloat
    var minimumDockWidth: CGFloat
    var minimumDrawerExtent: CGFloat

    /// Fixed value, does not vary with the step (see the note on `DockSize.metrics`).
    static let shadowPadding: CGFloat = 20

    /// Middle step, only a baseline for existing default arguments
    /// and unit tests; real values come from `DockSize.metrics`.
    static let standard = DockSize.medium.metrics
}

struct PanelScreenGeometry: Equatable {
    var frame: CGRect
    var visibleFrame: CGRect
    var safeAreaTop: CGFloat

    /// The drawer's top cap still follows top system UI. On displays without a notch,
    /// this usually tracks visibleFrame.maxY and may change when the menu bar auto-hides.
    /// On notched displays, the safe-area cap can take over once the menu bar is hidden,
    /// so the same known edge can be smaller there than on external displays.
    var topUsableY: CGFloat {
        min(visibleFrame.maxY, frame.maxY - safeAreaTop)
    }
}

enum PanelGeometry {
    static let windowTitleTooltipScreenMargin: CGFloat = 8
    /// Shadow padding **does not scale with the step**: the bubble's shadow token is
    /// fixed, and scaling it would change the finalized look. The view side and this
    /// must use the same value (the view does `.padding(it)`, this subtracts it back).
    static let windowTitleTooltipShadowPadding: CGFloat = 8

    static func dockTargetFrame(
        contentWidth: CGFloat,
        on screen: PanelScreenGeometry,
        metrics: PanelLayoutMetrics = .standard,
        reservesCapsule: Bool = true
    ) -> CGRect {
        // fork: `reservesCapsule == false` (drawer hidden) gives the strip the room upstream keeps
        // free on both sides for the capsule. The strip is centred either way.
        let capsuleReserve = reservesCapsule ? metrics.capsuleGap + metrics.capsuleWidth : 0
        let maxWidth = screen.frame.width - 2 * (metrics.outerMargin + capsuleReserve)
        let panelWidth = max(min(contentWidth, maxWidth), metrics.minimumDockWidth)
        let x = screen.frame.minX + (screen.frame.width - panelWidth) / 2
        return CGRect(
            x: x - metrics.shadowPadding,
            y: screen.frame.minY + metrics.bottomGap - metrics.shadowPadding,
            width: panelWidth + metrics.shadowPadding * 2,
            height: metrics.windowHeight
        )
    }

    static func capsuleTargetFrame(
        forDock dockFrame: CGRect,
        on screen: PanelScreenGeometry,
        metrics: PanelLayoutMetrics = .standard
    ) -> CGRect {
        let rawX = dockFrame.maxX - metrics.shadowPadding + metrics.capsuleGap
        let rawY = dockFrame.minY + metrics.shadowPadding + (metrics.panelHeight - metrics.capsuleWidth) / 2
        let clampedX = min(max(rawX, screen.frame.minX), screen.frame.maxX - metrics.capsuleWidth)
        let clampedY = min(max(rawY, screen.frame.minY), screen.frame.maxY - metrics.capsuleWidth)
        return CGRect(
            x: clampedX - metrics.shadowPadding,
            y: clampedY - metrics.shadowPadding,
            width: metrics.capsuleWidth + metrics.shadowPadding * 2,
            height: metrics.capsuleWidth + metrics.shadowPadding * 2
        )
    }

    /// **Single source of truth** for popup anchoring and clamping: given "desired center X /
    /// desired bottom Y / size", computes the screen-clamped origin. folderPopupTargetFrame
    /// (first frame / reposition) and each interpolated frame of the switch animation both
    /// use it, so the clamping rule is not written twice and left to drift.
    static func folderPopupClampedOrigin(
        desiredCenterX: CGFloat,
        desiredBottomY: CGFloat,
        size: CGSize,
        on screen: PanelScreenGeometry
    ) -> CGPoint {
        let bottom = max(desiredBottomY, screen.frame.minY)
        let x = min(max(desiredCenterX - size.width / 2, screen.frame.minX), screen.frame.maxX - size.width)
        return CGPoint(x: x, y: bottom)
    }

    /// Pinned folder popup: 8pt above the anchor (the chip's visible rect, screen coordinates),
    /// horizontally centered and clamped to the screen, grows upward only and is capped at topUsableY,
    /// the same bottom-anchor policy as the drawer. `size` is the whole panel size including shadow.
    static func folderPopupTargetFrame(
        anchorVisibleRect: CGRect,
        size: CGSize,
        on screen: PanelScreenGeometry,
        metrics: PanelLayoutMetrics = .standard
    ) -> CGRect {
        let origin = folderPopupClampedOrigin(
            desiredCenterX: anchorVisibleRect.midX, desiredBottomY: anchorVisibleRect.maxY + 8,
            size: size, on: screen)
        let height = min(size.height, max(metrics.minimumDrawerExtent, screen.topUsableY - origin.y))
        return CGRect(x: origin.x, y: origin.y, width: size.width, height: height)
    }

    static func maxFolderPopupContentHeight(
        anchorVisibleRect: CGRect,
        on screen: PanelScreenGeometry,
        metrics: PanelLayoutMetrics = .standard
    ) -> CGFloat {
        let bottom = anchorVisibleRect.maxY + 8
        return max(metrics.minimumDrawerExtent, (screen.topUsableY - bottom) - 2 * metrics.shadowPadding)
    }

    /// Window-title tooltip panel frame. The panel includes transparent padding for its SwiftUI
    /// shadow, while the visible bubble stays 8pt above the pill and 8pt inside the screen edges.
    /// `tipGap` = distance from the bubble's **tip** to the anchor's top edge. It scales
    /// with the step and is passed in by the caller from `WindowTitleTooltipStyle.tipGap`:
    /// the factor is computed in the style only, not a second time here.
    static func windowTitleTooltipTargetFrame(
        anchorVisibleRect: CGRect,
        size: CGSize,
        tipGap: CGFloat,
        on screen: PanelScreenGeometry
    ) -> CGRect {
        let inset = windowTitleTooltipShadowPadding
        let visibleWidth = max(0, size.width - 2 * inset)
        let visibleHeight = max(0, size.height - 2 * inset)
        let minVisibleX = screen.frame.minX + windowTitleTooltipScreenMargin
        let maxVisibleX = screen.frame.maxX - windowTitleTooltipScreenMargin - visibleWidth
        let desiredVisibleX = anchorVisibleRect.midX - visibleWidth / 2
        let visibleX = min(max(desiredVisibleX, minVisibleX), maxVisibleX)
        let desiredVisibleY = anchorVisibleRect.maxY + tipGap
        let maxVisibleY = screen.topUsableY - visibleHeight
        let visibleY = min(desiredVisibleY, maxVisibleY)

        return CGRect(
            x: visibleX - inset,
            y: visibleY - inset,
            width: size.width,
            height: size.height
        )
    }

    static func drawerTargetFrame(
        forCapsule capsuleFrame: CGRect,
        size: CGSize,
        on screen: PanelScreenGeometry,
        metrics: PanelLayoutMetrics = .standard
    ) -> CGRect {
        let bottom = max(capsuleFrame.maxY - metrics.shadowPadding + 8, screen.frame.minY)
        let height = min(size.height, max(metrics.minimumDrawerExtent, screen.topUsableY - bottom))
        let rawX = capsuleFrame.maxX - size.width
        let clampedX = min(max(rawX, screen.frame.minX), screen.frame.maxX - size.width)
        return CGRect(x: clampedX, y: bottom, width: size.width, height: height)
    }

    static func maxDrawerContentHeight(
        forCapsule capsuleFrame: CGRect,
        on screen: PanelScreenGeometry,
        metrics: PanelLayoutMetrics = .standard
    ) -> CGFloat {
        let drawerBottomY = capsuleFrame.maxY - metrics.shadowPadding + 8
        return max(metrics.minimumDrawerExtent, (screen.topUsableY - drawerBottomY) - 2 * metrics.shadowPadding)
    }
}
