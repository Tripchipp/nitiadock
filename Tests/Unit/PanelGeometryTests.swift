import CoreGraphics
import XCTest

final class PanelGeometryTests: XCTestCase {
    private let metrics = PanelLayoutMetrics.standard

    func testBottomDockVisibleFrameChangeDoesNotMoveBottomPanelsVertically() {
        let hidden = screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let shown = screen(
            frame: hidden.frame,
            visibleFrame: CGRect(x: 0, y: 80, width: 1512, height: 869)
        )

        let hiddenLayout = layout(on: hidden)
        let shownLayout = layout(on: shown)

        XCTAssertEqual(hiddenLayout.dock.minY, shownLayout.dock.minY)
        XCTAssertEqual(hiddenLayout.capsule.minY, shownLayout.capsule.minY)
        XCTAssertEqual(hiddenLayout.drawer.minY, shownLayout.drawer.minY)
    }

    func testSideDockVisibleFrameChangeDoesNotMoveOrResizeBottomPanelsHorizontally() {
        let hidden = screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let leftDockShown = screen(
            frame: hidden.frame,
            visibleFrame: CGRect(x: 90, y: 0, width: 1422, height: 949)
        )
        let rightDockShown = screen(
            frame: hidden.frame,
            visibleFrame: CGRect(x: 0, y: 0, width: 1422, height: 949)
        )

        let hiddenLayout = layout(on: hidden)
        for candidate in [layout(on: leftDockShown), layout(on: rightDockShown)] {
            XCTAssertEqual(candidate.dock.minX, hiddenLayout.dock.minX)
            XCTAssertEqual(candidate.dock.width, hiddenLayout.dock.width)
            XCTAssertEqual(candidate.capsule.minX, hiddenLayout.capsule.minX)
            XCTAssertEqual(candidate.drawer.minX, hiddenLayout.drawer.minX)
        }
    }

    func testBottomAnchoringUsesNonZeroScreenMinY() {
        let upperScreen = screen(frame: CGRect(x: -488, y: 982, width: 2560, height: 1440))
        let lowerScreen = screen(frame: CGRect(x: -2408, y: -640, width: 1920, height: 1080))

        XCTAssertEqual(layout(on: upperScreen).dock.minY, upperScreen.frame.minY + metrics.bottomGap - metrics.shadowPadding)
        XCTAssertEqual(layout(on: lowerScreen).dock.minY, lowerScreen.frame.minY + metrics.bottomGap - metrics.shadowPadding)
    }

    func testDockFrameKeepsOriginalBottomCoordinate() {
        let screen = screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982))

        let dock = PanelGeometry.dockTargetFrame(contentWidth: 620, on: screen, metrics: metrics)

        XCTAssertEqual(dock.minY, -12, "bottomGap 8 − shadowPadding 20, independent of the tier height")
        XCTAssertEqual(dock.height, 94, "medium tier 54 + 2×20")
    }

    func testDrawerTopCapUsesVisibleFrameWhenMenuBarIsLowerThanSafeAreaCap() {
        let screen = PanelScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 920),
            safeAreaTop: 32
        )
        XCTAssertEqual(screen.topUsableY, 920)

        let drawer = layout(on: screen, drawerSize: CGSize(width: 210, height: 900)).drawer

        XCTAssertEqual(drawer.maxY, 920)
    }

    func testDrawerTopCapUsesSafeAreaWhenNotchIsLowerThanVisibleFrame() {
        let screen = PanelScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            safeAreaTop: 32
        )
        XCTAssertEqual(screen.topUsableY, 950)

        let drawer = layout(on: screen, drawerSize: CGSize(width: 210, height: 900)).drawer

        XCTAssertEqual(drawer.maxY, 950)
    }

    func testMaxDrawerContentHeightUsesSameTopCapAsDrawerFrame() {
        let screen = PanelScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            safeAreaTop: 32
        )
        let frames = layout(on: screen)

        let maxHeight = PanelGeometry.maxDrawerContentHeight(forCapsule: frames.capsule, on: screen, metrics: metrics)

        XCTAssertEqual(maxHeight, (screen.topUsableY - frames.drawer.minY) - 2 * metrics.shadowPadding)
    }

    // MARK: - Folder popup

    func testFolderPopupAnchorsAboveAnchorRectAndCenters() {
        let screen = screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let anchor = CGRect(x: 700, y: 8, width: 44, height: 52)

        let popup = PanelGeometry.folderPopupTargetFrame(
            anchorVisibleRect: anchor, size: CGSize(width: 400, height: 300), on: screen, metrics: metrics
        )

        XCTAssertEqual(popup.minY, anchor.maxY + 8)
        XCTAssertEqual(popup.midX, anchor.midX)
        XCTAssertEqual(popup.height, 300)
    }

    func testFolderPopupClampsHorizontallyIntoScreen() {
        let screen = screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let leftAnchor = CGRect(x: 4, y: 8, width: 44, height: 52)
        let rightAnchor = CGRect(x: 1500, y: 8, width: 44, height: 52)
        let size = CGSize(width: 400, height: 300)

        let left = PanelGeometry.folderPopupTargetFrame(anchorVisibleRect: leftAnchor, size: size, on: screen, metrics: metrics)
        let right = PanelGeometry.folderPopupTargetFrame(anchorVisibleRect: rightAnchor, size: size, on: screen, metrics: metrics)

        XCTAssertEqual(left.minX, screen.frame.minX)
        XCTAssertEqual(right.maxX, screen.frame.maxX)
    }

    func testFolderPopupHeightCappedByTopUsableY() {
        let screen = PanelScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 920),
            safeAreaTop: 0
        )
        let anchor = CGRect(x: 700, y: 8, width: 44, height: 52)

        let popup = PanelGeometry.folderPopupTargetFrame(
            anchorVisibleRect: anchor, size: CGSize(width: 400, height: 2000), on: screen, metrics: metrics
        )
        let maxContent = PanelGeometry.maxFolderPopupContentHeight(anchorVisibleRect: anchor, on: screen, metrics: metrics)

        XCTAssertEqual(popup.maxY, screen.topUsableY)
        XCTAssertEqual(maxContent, (screen.topUsableY - (anchor.maxY + 8)) - 2 * metrics.shadowPadding)
    }

    // MARK: - Window title tooltip

    func testWindowTitleTooltipAnchorsVisibleBubbleAbovePillAndCenters() {
        let screen = screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let anchor = CGRect(x: 700, y: 20, width: 160, height: 34)
        let frame = PanelGeometry.windowTitleTooltipTargetFrame(
            anchorVisibleRect: anchor, size: CGSize(width: 300, height: 60),
            tipGap: WindowTitleTooltipStyle.native.tipGap, on: screen
        )
        let bubble = frame.insetBy(dx: PanelGeometry.windowTitleTooltipShadowPadding,
                                   dy: PanelGeometry.windowTitleTooltipShadowPadding)

        XCTAssertEqual(bubble.minY, anchor.maxY + WindowTitleTooltipStyle.native.tipGap)
        XCTAssertEqual(bubble.midX, anchor.midX)
    }

    func testWindowTitleTooltipClampsVisibleBubbleInsideNonZeroScreenEdges() {
        let screen = screen(frame: CGRect(x: -1512, y: 982, width: 1512, height: 982))
        let size = CGSize(width: 300, height: 60)
        let left = PanelGeometry.windowTitleTooltipTargetFrame(
            anchorVisibleRect: CGRect(x: screen.frame.minX, y: 1000, width: 40, height: 30),
            size: size, tipGap: WindowTitleTooltipStyle.native.tipGap, on: screen
        ).insetBy(dx: PanelGeometry.windowTitleTooltipShadowPadding,
                  dy: PanelGeometry.windowTitleTooltipShadowPadding)
        let right = PanelGeometry.windowTitleTooltipTargetFrame(
            anchorVisibleRect: CGRect(x: screen.frame.maxX - 40, y: 1000, width: 40, height: 30),
            size: size, tipGap: WindowTitleTooltipStyle.native.tipGap, on: screen
        ).insetBy(dx: PanelGeometry.windowTitleTooltipShadowPadding,
                  dy: PanelGeometry.windowTitleTooltipShadowPadding)

        XCTAssertEqual(left.minX, screen.frame.minX + PanelGeometry.windowTitleTooltipScreenMargin)
        XCTAssertEqual(right.maxX, screen.frame.maxX - PanelGeometry.windowTitleTooltipScreenMargin)
    }

    func testWindowTitleTooltipRespectsTopUsableY() {
        let screen = PanelScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 920),
            safeAreaTop: 0
        )
        let frame = PanelGeometry.windowTitleTooltipTargetFrame(
            anchorVisibleRect: CGRect(x: 700, y: 900, width: 100, height: 30),
            size: CGSize(width: 300, height: 60),
            tipGap: WindowTitleTooltipStyle.native.tipGap, on: screen
        )
        let bubble = frame.insetBy(dx: PanelGeometry.windowTitleTooltipShadowPadding,
                                   dy: PanelGeometry.windowTitleTooltipShadowPadding)

        XCTAssertEqual(bubble.maxY, screen.topUsableY)
    }

    // MARK: - Size tiers

    func testDockSizeTiersKeepIntegerHeightsAndDerivedWindowHeight() {
        let expected: [DockSize: CGFloat] = [.small: 46, .medium: 54, .large: 62, .extraLarge: 70]
        for size in DockSize.allCases {
            let m = size.metrics
            XCTAssertEqual(m.panelHeight, expected[size], "\(size) panel height")
            XCTAssertEqual(m.panelHeight.rounded(), m.panelHeight, "tier heights must be integers, otherwise corners and icons land on half pixels")
            // This relation used to live only in comments; the window height is the easiest thing to miss
            // when changing heights.
            XCTAssertEqual(m.windowHeight, m.panelHeight + 2 * m.shadowPadding)
            XCTAssertEqual(m.shadowPadding, 20, "shadow padding does not scale with the tier: the shadow token is frozen")
            XCTAssertEqual(m.capsuleWidth, m.panelHeight, "the capsule is square, its side follows the panel height")
        }
    }

    /// Medium is the baseline of the four tiers (`scale == 1`), locked field by field.
    ///
    /// **Changed from 52 to 54 on 2026-08-16 to match the native macOS 26 Dock** (measured on @2x
    /// screenshots: native bar height 108px = 54pt). Before that this locked "byte-for-byte equal to the
    /// historical literals from before 2026-07-30"; that freeze contract was overturned by this decision,
    /// so do not change it back to the old values. It goes with icon 36→40 (`ChipHoverVisual.bareIconSize`)
    /// and card height 52→54 (`ChipPillMetrics.chipHeight`); the three must move together.
    func testMediumTierMatchesTheNativeDockBaseline() {
        XCTAssertEqual(DockSize.medium.scale, 1.0)
        XCTAssertEqual(DockSize.medium.metrics, PanelLayoutMetrics(
            panelHeight: 54, shadowPadding: 20, windowHeight: 94,
            bottomGap: 8, outerMargin: 12, capsuleWidth: 54, capsuleGap: 8,
            minimumDockWidth: 120, minimumDrawerExtent: 120
        ))
    }

    /// Cards must fill the bar height with no gap above or below: right-click detection on empty taskbar
    /// areas relies on "no vertical gap".
    func testChipHeightFillsTheMediumPanelExactly() {
        XCTAssertEqual(ChipPillMetrics.chipHeight, DockSize.medium.panelHeight)
    }

    func testCapsuleGridContentFitsEveryTier() {
        // 3-column grid: 3×icon + 2×spacing + 2×padding must fit the capsule width. Medium is 3×9 +
        // 2×4 + 2×6 = 47pt and the small capsule is only 44pt: without scaling down it gets clipped.
        for size in DockSize.allCases {
            let s = size.scale
            let content = (3 * 9 + 2 * 4 + 2 * 6) * s
            XCTAssertLessThanOrEqual(content, size.metrics.capsuleWidth, "\(size) capsule content too wide")
        }
    }

    func testEveryTierLaysOutBottomAnchoredAndCentered() {
        let screen = screen(frame: CGRect(x: -1512, y: -400, width: 1512, height: 982))
        for size in DockSize.allCases {
            let m = size.metrics
            let dock = PanelGeometry.dockTargetFrame(contentWidth: 620, on: screen, metrics: m)
            let capsule = PanelGeometry.capsuleTargetFrame(forDock: dock, on: screen, metrics: m)
            // A screen with a non-zero origin must also sit on the physical bottom edge, and the panel height
            // follows the tier.
            XCTAssertEqual(dock.minY, screen.frame.minY + m.bottomGap - m.shadowPadding, "\(size) bottom edge")
            XCTAssertEqual(dock.height, m.windowHeight, "\(size) panel height")
            XCTAssertEqual(dock.midX, screen.frame.midX, accuracy: 0.5, "\(size) centered")
            // The capsule is vertically centered on the taskbar (centers coincide when both have the same
            // height).
            XCTAssertEqual(capsule.midY, dock.midY, accuracy: 0.5, "\(size) capsule vertical alignment")
        }
    }

    func testLiftTargetTracksTierHeight() {
        // The maximize lift's taskbarTop = screen bottom + bottomGap + panelHeight and must change
        // with the tier, otherwise the lifted window's bottom edge does not meet the new taskbar.
        let screenMinY: CGFloat = -400
        var tops: [CGFloat] = []
        for size in DockSize.allCases {
            let m = size.metrics
            tops.append(screenMinY + m.bottomGap + m.panelHeight)
        }
        XCTAssertEqual(tops, [-346, -338, -330, -322], "medium starts at 54, tiers differ by 8pt")
        XCTAssertEqual(Set(tops).count, DockSize.allCases.count, "the lift targets of the four tiers must be pairwise distinct")
    }

    private func layout(
        on screen: PanelScreenGeometry,
        contentWidth: CGFloat = 620,
        drawerSize: CGSize = CGSize(width: 210, height: 260)
    ) -> (dock: CGRect, capsule: CGRect, drawer: CGRect) {
        let dock = PanelGeometry.dockTargetFrame(contentWidth: contentWidth, on: screen, metrics: metrics)
        let capsule = PanelGeometry.capsuleTargetFrame(forDock: dock, on: screen, metrics: metrics)
        let drawer = PanelGeometry.drawerTargetFrame(forCapsule: capsule, size: drawerSize, on: screen, metrics: metrics)
        return (dock, capsule, drawer)
    }

    private func screen(frame: CGRect, visibleFrame: CGRect? = nil, safeAreaTop: CGFloat = 0) -> PanelScreenGeometry {
        PanelScreenGeometry(frame: frame, visibleFrame: visibleFrame ?? frame, safeAreaTop: safeAreaTop)
    }
}
