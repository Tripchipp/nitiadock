import CoreGraphics
import XCTest

/// fork: the adjustable bottom margin.
final class ForkBottomMarginTests: XCTestCase {
    private let screen = PanelScreenGeometry(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949),
        safeAreaTop: 0
    )

    func testUntouchedMarginLeavesUpstreamsMetricsAlone() {
        for size in DockSize.allCases {
            XCTAssertEqual(size.metrics.withBottomMargin(nil), size.metrics)
            XCTAssertEqual(size.metrics.bottomGap, CGFloat(ForkAppearance.upstreamBottomMargin))
        }
    }

    func testMarginMovesTheBarAndItsCapsuleTogether() {
        let upstream = DockSize.medium.metrics
        let raised = upstream.withBottomMargin(40)

        let dockBefore = PanelGeometry.dockTargetFrame(contentWidth: 600, on: screen, metrics: upstream)
        let dockAfter = PanelGeometry.dockTargetFrame(contentWidth: 600, on: screen, metrics: raised)
        XCTAssertEqual(dockAfter.minY - dockBefore.minY, 32)
        XCTAssertEqual(dockAfter.minX, dockBefore.minX)
        XCTAssertEqual(dockAfter.size, dockBefore.size)
        // The visible bar (panel minus its shadow border) sits exactly `margin` above the edge.
        XCTAssertEqual(dockAfter.minY + raised.shadowPadding, 40)

        let capsuleBefore = PanelGeometry.capsuleTargetFrame(forDock: dockBefore, on: screen, metrics: upstream)
        let capsuleAfter = PanelGeometry.capsuleTargetFrame(forDock: dockAfter, on: screen, metrics: raised)
        XCTAssertEqual(capsuleAfter.minY - capsuleBefore.minY, 32)
        XCTAssertEqual(capsuleAfter.midY, dockAfter.midY)
    }

    func testMarginZeroPutsTheBarOnTheEdge() {
        let metrics = DockSize.medium.metrics.withBottomMargin(0)
        let dock = PanelGeometry.dockTargetFrame(contentWidth: 600, on: screen, metrics: metrics)
        XCTAssertEqual(dock.minY + metrics.shadowPadding, 0)
    }

    func testBarTopForTheWindowLiftFollowsTheMargin() {
        // `PanelCoordinator.windowLiftAvoidanceContext` computes this same sum from `layoutMetrics`.
        let metrics = DockSize.large.metrics.withBottomMargin(60)
        XCTAssertEqual(screen.frame.minY + metrics.bottomGap + metrics.panelHeight, 60 + 62)
    }

    func testNoCorridorWhileThePanelReachesTheScreenEdge() {
        // Upstream: 8pt gap, 20pt shadow border -> the panel starts 12pt below the edge.
        let metrics = DockSize.medium.metrics
        let dock = PanelGeometry.dockTargetFrame(contentWidth: 600, on: screen, metrics: metrics)
        XCTAssertNil(ForkBottomMargin.approachCorridor(dockPanelFrame: dock, screenFrame: screen.frame))

        let atBorder = DockSize.medium.metrics.withBottomMargin(20)
        let dockAtBorder = PanelGeometry.dockTargetFrame(contentWidth: 600, on: screen, metrics: atBorder)
        XCTAssertNil(ForkBottomMargin.approachCorridor(dockPanelFrame: dockAtBorder, screenFrame: screen.frame))
    }

    func testCorridorBridgesTheEdgeAndARaisedBar() throws {
        let metrics = DockSize.medium.metrics.withBottomMargin(60)
        let dock = PanelGeometry.dockTargetFrame(contentWidth: 600, on: screen, metrics: metrics)
        let corridor = try XCTUnwrap(ForkBottomMargin.approachCorridor(dockPanelFrame: dock, screenFrame: screen.frame))
        XCTAssertEqual(corridor.minY, screen.frame.minY)
        XCTAssertEqual(corridor.maxY, dock.minY, "no gap between corridor and panel")
        XCTAssertEqual(corridor.height, 40)
        XCTAssertEqual(corridor.minX, dock.minX)
        XCTAssertEqual(corridor.width, dock.width)
        // Below the bar: inside. Beside the bar at the same height: not.
        XCTAssertTrue(corridor.contains(CGPoint(x: dock.midX, y: 20)))
        XCTAssertFalse(corridor.contains(CGPoint(x: dock.minX - 50, y: 20)))
    }

    func testCorridorIsRelativeToTheBarsOwnScreen() throws {
        // A display arranged below the primary one has a negative origin.
        let lower = PanelScreenGeometry(
            frame: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: -1080, width: 1920, height: 1055),
            safeAreaTop: 0
        )
        let metrics = DockSize.medium.metrics.withBottomMargin(50)
        let dock = PanelGeometry.dockTargetFrame(contentWidth: 600, on: lower, metrics: metrics)
        let corridor = try XCTUnwrap(ForkBottomMargin.approachCorridor(dockPanelFrame: dock, screenFrame: lower.frame))
        XCTAssertEqual(corridor.minY, -1080)
        XCTAssertEqual(corridor.height, 30)
    }

    // MARK: Plate hugs narrow content

    func testPlateShrinksToNarrowContentAndStaysCentred() {
        // The reported case: small tier, two icons, 6pt edge padding, no spacing.
        let scale = DockSize.small.scale
        let content = 2 * ChipPillMetrics.cardWidth * scale + 2 * 6 * scale
        let upstream = DockSize.small.metrics
        XCTAssertLessThan(content, upstream.minimumDockWidth, "precondition: narrower than upstream's minimum")

        let stuck = PanelGeometry.dockTargetFrame(contentWidth: content, on: screen, metrics: upstream)
        XCTAssertEqual(stuck.width - 2 * upstream.shadowPadding, upstream.minimumDockWidth, "upstream leaves the surplus")

        let hugging = upstream.huggingContent(contentWidth: content, emptyContentWidth: 2 * 6 * scale)
        let frame = PanelGeometry.dockTargetFrame(contentWidth: content, on: screen, metrics: hugging)
        XCTAssertEqual(frame.width - 2 * hugging.shadowPadding, content, accuracy: 0.001)
        XCTAssertEqual(frame.midX, screen.frame.midX, accuracy: 0.001)
    }

    func testWideContentKeepsUpstreamsMetrics() {
        let metrics = DockSize.medium.metrics
        XCTAssertEqual(metrics.huggingContent(contentWidth: 600, emptyContentWidth: 40), metrics)
        XCTAssertEqual(metrics.huggingContent(contentWidth: .nan, emptyContentWidth: 40), metrics)
    }

    func testAnEmptyStripIsASquarePlateNeverWiderThanOneIcon() {
        for size in DockSize.allCases {
            let scale = size.scale
            for edge in [6.0, 20.0, 60.0] {
                let emptyWidth = 2 * CGFloat(edge) * scale
                let empty = size.metrics.huggingContent(contentWidth: emptyWidth, emptyContentWidth: emptyWidth)
                let emptyFrame = PanelGeometry.dockTargetFrame(contentWidth: emptyWidth, on: screen, metrics: empty)
                let emptyPlate = emptyFrame.width - 2 * empty.shadowPadding
                // A sliver is no use, and the reported bug was an empty bar wider than a bar with an app.
                XCTAssertGreaterThanOrEqual(emptyPlate, size.panelHeight, "\(size) edge \(edge)")
                XCTAssertEqual(emptyFrame.midX, screen.frame.midX, accuracy: 0.001)

                let oneIcon = emptyWidth + ChipPillMetrics.cardWidth * scale
                let one = size.metrics.huggingContent(contentWidth: oneIcon, emptyContentWidth: emptyWidth)
                let onePlate = PanelGeometry.dockTargetFrame(contentWidth: oneIcon, on: screen, metrics: one).width
                    - 2 * one.shadowPadding
                if emptyWidth <= size.panelHeight {
                    XCTAssertLessThanOrEqual(emptyPlate, max(onePlate, size.panelHeight) + 0.001, "\(size) edge \(edge)")
                }
            }
        }
    }

    func testMarginPersistsAndRejectsOutOfRange() {
        let suiteName = "com.tungsten.edge.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        var appearance = ForkAppearance()
        appearance.bottomMargin = 24
        ForkAppearanceStorage.save(appearance, to: defaults)
        XCTAssertEqual(ForkAppearanceStorage.load(from: defaults).bottomMargin, 24)

        defaults.set(400, forKey: ForkAppearanceStorage.Keys.bottomMargin)
        XCTAssertNil(ForkAppearanceStorage.load(from: defaults).bottomMargin)
        XCTAssertEqual(ForkAppearance().layoutIdentity, appearance.layoutIdentity, "the margin does not change card widths")
    }
}
