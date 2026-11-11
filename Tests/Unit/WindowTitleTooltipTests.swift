import AppKit
import XCTest

final class WindowTitleTooltipTests: XCTestCase {
    func testFontUsesRenderedSizeRules() {
        XCTAssertEqual(WindowTitleTextMetrics.font(scale: 0.5).pointSize, 10)
        XCTAssertEqual(WindowTitleTextMetrics.font(scale: 1).pointSize, 12)
        XCTAssertEqual(WindowTitleTextMetrics.font(scale: 1.5).pointSize, 18)
    }

    func testFontUsesRoundedSystemDesign() {
        XCTAssertTrue(WindowTitleTextMetrics.font(scale: 1).fontName.contains("Rounded"))
    }

    func testIntrinsicWidthTracksScale() {
        let title = "activity-list.vue - project"
        let small = WindowTitleTextMetrics.intrinsicWidth(of: title, scale: 0.5)
        let regular = WindowTitleTextMetrics.intrinsicWidth(of: title, scale: 1)
        let large = WindowTitleTextMetrics.intrinsicWidth(of: title, scale: 1.5)

        XCTAssertLessThan(small, regular)
        XCTAssertLessThan(regular, large)
    }

    func testInStripTitleWidthTracksTheDockScale() {
        // The in-strip title width scales with the taskbar, and the truncation check must use the same width.
        // Hardcoding 140 in both places gives "looks truncated but no tooltip" (or the reverse).
        // This test covers only the **in-strip** text;
        // the bubble's own scaling is locked in `testMediumTierKeepsTheNativePixelsAndOtherTiersScaleWholesale`.
        for tier in DockSize.allCases {
            XCTAssertEqual(WindowTitleTextMetrics.maximumWidth(for: tier.scale),
                           WindowTitleTextMetrics.maximumWidth * tier.scale, accuracy: 0.001)
        }
        // The medium tier must match the historical literal.
        XCTAssertEqual(WindowTitleTextMetrics.maximumWidth(for: 1.0), 140)
    }

    // The truncation check (`isTruncated` / `needsTooltip`) and its three tests were removed on 2026-08-17.
    // It was the "tooltip only when the title is truncated" gate; the bubble first changed to show on hover,
    // then to show only the app name, so production code has no callers. Do not restore the old signatures.
}

/// Chip geometry **stays fixed** on hover: on 2026-08-16 the app name became a bubble directly above the
/// icon, like the native Dock, so the chip no longer needs to make room for it inside.
///
/// This used to lock the `ChipSubtitleMetrics` shift formulas (e.g. `pillHoverShift = 3s - 1 - Hs/2`,
/// solved against the earlier `VStack(spacing: 2)` layout). **That type and all its tests were removed
/// with the feature; do not restore the old formulas.**
final class ChipHoverGeometryTests: XCTestCase {
    private let tiers: [CGFloat] = DockSize.allCases.map(\.scale)

    func testHoverDoesNotMoveAnyGeometry() {
        for scale in tiers {
            let rest = ChipHoverVisual.resolve(progress: 0, scale: scale)
            let hover = ChipHoverVisual.resolve(progress: 1, scale: scale)
            XCTAssertEqual(rest.bareIconSize, hover.bareIconSize, accuracy: 0.001,
                           "hover must not shrink the icon (scale=\(scale))")
            XCTAssertEqual(rest.pillHeight, hover.pillHeight, accuracy: 0.001,
                           "hover must not shrink the pill (scale=\(scale))")
            XCTAssertEqual(rest.pillIconSize, hover.pillIconSize, accuracy: 0.001,
                           "hover must not shrink the icon inside the pill (scale=\(scale))")
        }
    }

    /// The only value that still changes on hover: the brightening of the pill fill and stroke.
    func testOnlyEmphasisTracksHover() {
        XCTAssertEqual(ChipHoverVisual.resolve(progress: 0, scale: 1).emphasisProgress, 0)
        XCTAssertEqual(ChipHoverVisual.resolve(progress: 1, scale: 1).emphasisProgress, 1)
        XCTAssertEqual(ChipHoverVisual.resolve(progress: 0.5, scale: 1).emphasisProgress, 0.5)
    }

    func testProgressIsClamped() {
        XCTAssertEqual(ChipHoverVisual.resolve(progress: -3, scale: 1).progress, 0)
        XCTAssertEqual(ChipHoverVisual.resolve(progress: 9, scale: 1).progress, 1)
    }

    func testSizesTrackTheTier() {
        for scale in tiers {
            let v = ChipHoverVisual.resolve(progress: 0, scale: scale)
            XCTAssertEqual(v.bareIconSize, ChipPillMetrics.bareIconSlot * scale, accuracy: 0.001)
            XCTAssertEqual(v.pillHeight, ChipPillMetrics.boxHeight * scale, accuracy: 0.001)
            XCTAssertEqual(v.pillIconSize, ChipPillMetrics.iconSlot * scale, accuracy: 0.001)
        }
    }
}

/// Label width animation curve: the strip and the panel backing share one bezier, and a malformed
/// tuning string must silently fall back to the default.
final class LabelWidthAnimationTests: XCTestCase {
    func testDefaultCurveIsAValidBezier() {
        let c = LabelWidthAnimation.defaultCurve
        XCTAssertGreaterThan(c.duration, 0)
        XCTAssertTrue((0...1).contains(c.c1x))
        XCTAssertTrue((0...1).contains(c.c2x))
    }

    func testParsesTheOverrideString() {
        XCTAssertEqual(LabelWidthAnimation.parse("300, 0.25, 0.1, 0.25, 1"),
                       LabelWidthAnimation.Curve(duration: 0.3, c1x: 0.25, c1y: 0.1, c2x: 0.25, c2y: 1))
    }

    func testRejectsMalformedOverrides() {
        XCTAssertNil(LabelWidthAnimation.parse(nil))
        XCTAssertNil(LabelWidthAnimation.parse(""))
        XCTAssertNil(LabelWidthAnimation.parse("300,0.25,0.1,0.25"))         // one item short
        XCTAssertNil(LabelWidthAnimation.parse("0,0.25,0.1,0.25,1"))         // non-positive duration
        XCTAssertNil(LabelWidthAnimation.parse("300,1.5,0.1,0.25,1"))        // control point x out of range
        XCTAssertNil(LabelWidthAnimation.parse("300,a,0.1,0.25,1"))          // not a number
    }
}

/// Since the probe now measures the card rect, the tooltip's anchor contract (pill rect) is derived from
/// these constants, so the derivation must use the same values as rendering.
final class ChipPillMetricsTests: XCTestCase {
    func testWidthMatchesTheRenderedComposition() {
        let title = "psd-文件"
        let scale: CGFloat = 1
        let titleWidth = min(WindowTitleTextMetrics.intrinsicWidth(of: title, scale: scale),
                             WindowTitleTextMetrics.maximumWidth(for: scale))
        let expected = (2 * 10 + 22 + 6) * scale + ceil(titleWidth)
        XCTAssertEqual(ChipPillMetrics.width(title: title, scale: scale), expected, accuracy: 0.001)
    }

    /// Label box width is the shared source for rendering and derivation: the constrained title width
    /// rounded up; `width` only adds constants around it.
    func testLabelWidthIsTheCeiledCappedIntrinsicWidth() {
        let title = "psd-文件"
        let long = String(repeating: "very-long-window-title-", count: 20)
        for scale in [CGFloat(0.85), 1, 1.15, 1.3] {
            let intrinsic = WindowTitleTextMetrics.intrinsicWidth(of: title, scale: scale)
            XCTAssertEqual(ChipPillMetrics.labelWidth(title: title, scale: scale),
                           ceil(min(intrinsic, WindowTitleTextMetrics.maximumWidth(for: scale))), accuracy: 0.001)
            XCTAssertEqual(ChipPillMetrics.labelWidth(title: long, scale: scale),
                           ceil(WindowTitleTextMetrics.maximumWidth(for: scale)), accuracy: 0.001)
            XCTAssertFalse(ChipPillMetrics.labelTruncates(title: title, scale: scale))
            XCTAssertTrue(ChipPillMetrics.labelTruncates(title: long, scale: scale))
            XCTAssertEqual(ChipPillMetrics.width(title: long, scale: scale)
                               - ChipPillMetrics.width(title: title, scale: scale),
                           ChipPillMetrics.labelWidth(title: long, scale: scale)
                               - ChipPillMetrics.labelWidth(title: title, scale: scale), accuracy: 0.001)
        }
    }

    func testWidthIsCappedByTheTitleMaximum() {
        let long = String(repeating: "very-long-window-title-", count: 20)
        let scale: CGFloat = 1
        let expected = (2 * 10 + 22 + 6) * scale + ceil(WindowTitleTextMetrics.maximumWidth(for: scale))
        XCTAssertEqual(ChipPillMetrics.width(title: long, scale: scale), expected, accuracy: 0.001)
    }

    // MARK: - Quiet hover zoom: tapered by card width

    /// **Main lock**: the icon card's look does not change by one pixel.
    ///
    /// The cap rule yields 1.15 on a 40pt card, which the `quietHoverScale` ceiling clamps back to 1.10:
    /// the taper should only bite cards wide enough to crowd. All four icon cards
    /// (window card / kept / message zone / shelf) have this width.
    func testIconCardKeepsTheAcceptedFullScale() {
        for tier in DockSize.allCases {
            let width = ChipPillMetrics.cardWidth * tier.scale
            XCTAssertEqual(
                ChipPillMetrics.quietHoverScale(forCardWidth: width, scale: tier.scale),
                ChipPillMetrics.quietHoverScale, accuracy: 0.0001,
                "icon card at tier \(tier) must still be 1.10"
            )
        }
    }

    /// At any card width, the outward growth per side stays within budget:
    /// that is the direct test for "no more crowding".
    /// (The scale factor itself does not matter; the user sees edge displacement.)
    func testNoCardGrowsBeyondTheEdgeBudget() {
        for tier in DockSize.allCases {
            let budget = ChipPillMetrics.quietHoverEdgeBudget * tier.scale
            for base in [40, 60, 96, 140, 168.5, 196, 400] as [CGFloat] {
                let width = base * tier.scale
                let s = ChipPillMetrics.quietHoverScale(forCardWidth: width, scale: tier.scale)
                let growthPerSide = width * (s - 1) / 2
                XCTAssertLessThanOrEqual(growthPerSide, budget + 0.0001,
                                         "card width \(base) tier \(tier) grows \(growthPerSide) per side, over budget")
            }
        }
    }

    /// Two full-width titled cards side by side: a gap must remain after zooming.
    /// Resting visible gap = `2 * titledCardInset + chipSpacing` = 10pt, budget 3pt -> at least 7pt left.
    func testTwoWidestTitledCardsStillLeaveAVisibleGap() {
        let scale: CGFloat = 1
        let longTitle = String(repeating: "very-long-window-title-", count: 20)
        let cardWidth = ChipPillMetrics.width(title: longTitle, scale: scale)
            + 2 * ChipPillMetrics.titledCardInset * scale
        let restingGap = 2 * ChipPillMetrics.titledCardInset * scale + 2 /* Style.chipSpacing */
        let s = ChipPillMetrics.quietHoverScale(forCardWidth: cardWidth, scale: scale)
        let remaining = restingGap - cardWidth * (s - 1) / 2

        XCTAssertEqual(restingGap, 10, accuracy: 0.001, "resting gap composition changed, recompute this criterion")
        XCTAssertGreaterThanOrEqual(remaining, 7 - 0.001,
                                    "only \(remaining)pt left after zooming, wide cards crowd their neighbours again")
    }

    /// Unread badge size: the medium tier equals the historical literals exactly, the others follow `scale`.
    ///
    /// Before scaling, these four numbers were hardcoded and identical in all four tiers,
    /// the same kind of miss as the hover bubble.
    func testBadgeMetricsKeepTheMediumLiteralsAndScaleWithTheTier() {
        XCTAssertEqual(ChipPillMetrics.badgeFontSize, 10)
        XCTAssertEqual(ChipPillMetrics.badgeMinimumSize, 16)
        XCTAssertEqual(ChipPillMetrics.badgeHorizontalPadding, 5)
        XCTAssertEqual(ChipPillMetrics.badgeTopOffset, 5)
        // Medium-tier scale is always 1, so "times scale" is the original value at medium;
        // this also locks that identity.
        XCTAssertEqual(DockSize.medium.scale, 1.0, accuracy: 0.0000001)
    }

    /// A width of 0 (not measured yet) must not produce NaN / infinity.
    func testZeroWidthFallsBackToTheCap() {
        XCTAssertEqual(ChipPillMetrics.quietHoverScale(forCardWidth: 0, scale: 1),
                       ChipPillMetrics.quietHoverScale)
    }

    /// The pill is horizontally centred in the card -> midX is the card's; vertical values all come from constants.
    func testPillRectIsHorizontallyCenteredOnTheCard() {
        let card = CGRect(x: 100, y: 200, width: 180, height: 52)
        let rect = ChipPillMetrics.pillRect(inCard: card, title: "psd-文件", scale: 1)
        XCTAssertEqual(rect.midX, card.midX, accuracy: 0.001)
    }

    /// Screen coordinates have y up: the resting pill's top edge = `boxTopInset` below the card's top edge.
    func testRestPillRectSitsBoxTopInsetBelowTheCardTop() {
        let card = CGRect(x: 0, y: 0, width: 180, height: ChipPillMetrics.chipHeight)
        let rect = ChipPillMetrics.pillRect(inCard: card, title: "psd-文件", scale: 1)
        XCTAssertEqual(rect.maxY, card.maxY - ChipPillMetrics.boxTopInset, accuracy: 0.001)
        XCTAssertEqual(rect.height, 34, accuracy: 0.001)
    }

}


final class ScreenRectReaderTests: XCTestCase {
    private final class Task: ScreenRectDeliveryTask {
        private let action: () -> Void
        private(set) var isCancelled = false

        init(action: @escaping () -> Void) { self.action = action }
        func cancel() { isCancelled = true }
        func run() { if !isCancelled { action() } }
        func forceRun() { action() }
    }

    private final class Scheduler: ScreenRectDeliveryScheduling {
        struct Scheduled {
            let delay: TimeInterval
            let task: Task
        }

        private(set) var scheduled: [Scheduled] = []

        func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> ScreenRectDeliveryTask {
            let task = Task(action: action)
            scheduled.append(Scheduled(delay: delay, task: task))
            return task
        }

        func runAll() {
            let tasks = scheduled
            scheduled.removeAll()
            tasks.forEach { $0.task.run() }
        }
    }

    func testReportsEveryDistinctRectInOrder() {
        let scheduler = Scheduler()
        var reported: [CGRect] = []
        let view = ScreenRectReader.TrackingView(
            scheduler: scheduler, onChange: { reported.append($0) }
        )
        let a = CGRect(x: 1, y: 2, width: 3, height: 4)
        let b = CGRect(x: 2, y: 3, width: 4, height: 5)

        view.enqueue(a)
        view.enqueue(a)
        view.enqueue(b)
        view.enqueue(a)
        scheduler.runAll()

        XCTAssertEqual(reported, [a, b, a])
        XCTAssertEqual(scheduler.scheduled.count, 0)
    }



    func testPendingDeliveryUsesTheLatestCallback() {
        let scheduler = Scheduler()
        var old: [CGRect] = []
        var latest: [CGRect] = []
        let view = ScreenRectReader.TrackingView(
            scheduler: scheduler, onChange: { old.append($0) }
        )
        let rect = CGRect(x: 1, y: 2, width: 3, height: 4)

        view.enqueue(rect)
        view.update(onChange: { latest.append($0) })
        scheduler.runAll()

        XCTAssertTrue(old.isEmpty)
        XCTAssertEqual(latest, [rect])
    }

    func testDetachCancellationBlocksPendingCallbacks() {
        let scheduler = Scheduler()
        var reported: [CGRect] = []
        let view = ScreenRectReader.TrackingView(
            scheduler: scheduler, onChange: { reported.append($0) }
        )
        view.enqueue(CGRect(x: 1, y: 2, width: 3, height: 4))
        view.cancelPendingDelivery()
        scheduler.runAll()
        XCTAssertTrue(reported.isEmpty, "deliveries queued after detach must be dropped")
    }


    /// Moving the window / changing screens must report again.
    ///
    /// `layout()` fires only when the view tree changes, and moving the panel to another screen or up and down
    /// does not change the view tree, so each card's cached screen rect stays at the old position and the bubble
    /// pops up on the screen that has no taskbar. This locks "an observer is installed, and it can be removed".
    func testWindowMovementTriggersAFreshReport() {
        let scheduler = Scheduler()
        var reported: [CGRect] = []
        let view = ScreenRectReader.TrackingView(
            scheduler: scheduler, onChange: { reported.append($0) }
        )
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(view)
        view.frame = CGRect(x: 10, y: 10, width: 50, height: 20)
        scheduler.runAll()
        reported.removeAll()

        window.setFrameOrigin(CGPoint(x: 400, y: 300))
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)
        scheduler.runAll()
        XCTAssertFalse(reported.isEmpty, "must report once more after the window moves")

        // Must not fire after removal, or the observer outlives the view.
        view.removeFromSuperview()
        reported.removeAll()
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)
        scheduler.runAll()
        XCTAssertTrue(reported.isEmpty, "a detached probe must not report again")
    }

    /// Bubble dimensions were measured pixel by pixel from native macOS 26 Dock screenshots on 2026-08-17,
    /// not designed. This locks those numbers: to change them, re-screenshot and re-measure, do not tune by feel.
    func testBubbleMetricsMatchTheMeasuredNativeDockLabel() {
        let native = WindowTitleTooltipStyle.native
        XCTAssertEqual(native.height, 26)
        XCTAssertEqual(native.fontSize, 14)
        XCTAssertEqual(native.horizontalPadding, 13)
        XCTAssertEqual(native.tailWidth, 23)
        XCTAssertEqual(native.tailHeight, 6.5)
        XCTAssertEqual(native.tipGap, 6.5)
        XCTAssertEqual(native.maximumWidth, 360)
        // Measured slope of the straight mid section (half-width/depth) is ≈1.17;
        // the proof of the round tip is that it does not extrapolate to the bottom.
        let slope = (native.tailShoulderHalfWidth - native.tailTipHalfWidth)
            / (native.tailTipDepth - native.tailShoulderDepth)
        XCTAssertEqual(slope, 1.17, accuracy: 0.05)
        let extrapolated = native.tailTipDepth + native.tailTipHalfWidth / slope
        XCTAssertGreaterThan(extrapolated, native.tailHeight,
                             "straight-edge extrapolation must land below the actual tip: the difference is the round cap")
        // **A capsule, not a rounded rectangle**: the corner radius must be exactly half the height.
        XCTAssertEqual(native.cornerRadius, native.height / 2)
    }

    /// The bubble scales with the taskbar tier (2026-08-17), but **the medium tier must not move a pixel**.
    ///
    /// This is also the regression lock for the denominator trap: the factor must be `DockSize.scale`
    /// (normalised to the medium tier), which is exactly 1.0 at medium. If someone changes it to
    /// "bar height / some literal", medium stops being 1 and the signed-off native pixels change.
    func testMediumTierKeepsTheNativePixelsAndOtherTiersScaleWholesale() {
        XCTAssertEqual(DockSize.medium.scale, 1.0, accuracy: 0.0000001)
        let medium = WindowTitleTooltipStyle(scale: DockSize.medium.scale)
        XCTAssertEqual(medium, WindowTitleTooltipStyle.native)

        for tier in DockSize.allCases {
            let style = WindowTitleTooltipStyle(scale: tier.scale)
            XCTAssertEqual(style.height, 26 * tier.scale, accuracy: 0.001)
            XCTAssertEqual(style.fontSize, 14 * tier.scale, accuracy: 0.001)
            XCTAssertEqual(style.tipGap, 6.5 * tier.scale, accuracy: 0.001)
            XCTAssertEqual(style.horizontalPadding, 13 * tier.scale, accuracy: 0.001)
            // Still a capsule after scaling.
            XCTAssertEqual(style.cornerRadius, style.height / 2, accuracy: 0.001)
        }
    }

    /// The tail's round cap is present at every tier (straight-edge extrapolation must overshoot the real tip).
    func testTailStaysRoundedAtEveryTier() {
        for tier in DockSize.allCases {
            let style = WindowTitleTooltipStyle(scale: tier.scale)
            let slope = (style.tailShoulderHalfWidth - style.tailTipHalfWidth)
                / (style.tailTipDepth - style.tailShoulderDepth)
            let extrapolated = style.tailTipDepth + style.tailTipHalfWidth / slope
            XCTAssertGreaterThan(extrapolated, style.tailHeight, "the tip at tier \(tier) must not become sharp")
        }
    }

    /// The tail must be drawn in the same closed path: overlaying a triangle leaves a horizontal line at the seam.
    /// This verifies the shape does extend a tail downward, with the tip at the horizontal centre.
    func testShapeExtendsADownwardTailAtTheHorizontalCentre() {
        let style = WindowTitleTooltipStyle.native
        let rect = CGRect(x: 0, y: 0, width: 85, height: style.height + style.tailHeight)
        let box = WindowTitleTooltipShape(style: style).path(in: rect).boundingRect
        XCTAssertEqual(box.maxY, rect.maxY, accuracy: 0.5, "tip must reach the bottom edge of the shape")
        XCTAssertEqual(box.width, rect.width, accuracy: 0.5, "body must span the full width")

        // The row at the tip is only a narrow sliver, and centred.
        let tip = WindowTitleTooltipShape(style: style).path(in: rect)
        let nearTip = tip.boundingRect
        XCTAssertEqual(nearTip.midX, rect.midX, accuracy: 0.5)
        XCTAssertFalse(tip.contains(CGPoint(x: rect.minX + 2, y: rect.maxY - 1)),
                       "both sides of the tail must be empty, not a full bottom edge")
        XCTAssertTrue(tip.contains(CGPoint(x: rect.midX, y: rect.maxY - 1)),
                      "the centre column must still be inside the shape")
    }
}

/// Icon centre pitch: the natively measured 42pt, and the same constant the strip actually uses for spacing.
///
/// (This used to hold a full set of `WindowTitleTooltipOwnership` cases: who may claim the one bubble panel,
/// and whether to keep it across gaps. Since 2026-08-17 hover is "one tracking area for the whole bar +
/// lookup by position", so the bubble has a single sender and preemption is structurally impossible; that
/// logic and its cases were removed. Gaps and boundaries are now locked in `StripHoverResolutionTests`.)
final class ChipIconPitchTests: XCTestCase {
    func testIconPitchMatchesTheNativeDock() {
        XCTAssertEqual(ChipPillMetrics.iconPitch, 42)
        XCTAssertEqual(ChipPillMetrics.iconPitch,
                       ChipPillMetrics.cardWidth + ChipPillMetrics.chipSpacing)
    }
}
