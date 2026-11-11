import XCTest

/// The theme table has only **one** set of values
/// (`DockThemeTokens.standard`): the product is fixed to light, and dark mode
/// was removed by decision on 2026-08-16.
///
/// Before that, this file locked "dark column frozen byte for byte +
/// light column asserted item by item", 38 fields in all. **That contract
/// went away with the feature, do not restore it from the old
/// values.** Now it only locks invariants tied to function:
/// the foreground must tint black (white vanishes on light glass), pill and
/// halo must push the backing away from the text, shadows stay within budget,
/// all effect switches default to off. Individual values are
/// freely tunable look and should not be pinned by tests.
final class DockThemeTests: XCTestCase {
    private let theme = DockThemeTokens.standard
    private let shadowPadding: CGFloat = 20

    // MARK: - Foreground direction

    /// The foreground must tint **black**, not white: white vanishes
    /// on light glass and leaves only the stroke standing alone,
    /// so every card becomes a hollow box, exactly the "very
    /// visible boxes around things" users complained about.
    func testForegroundsAreDarkTinted() {
        let mustBeBlack: [(String, DockTint)] = [
            ("labelActive", theme.labelActive),
            ("labelInactive", theme.labelInactive),
            ("labelHover", theme.labelHover),
            ("labelSubtitle", theme.labelSubtitle),
            ("runningDot", theme.runningDot),
            ("zoneDivider", theme.zoneDivider),
            ("capsuleGlyph", theme.capsuleGlyph),
            ("folderDropRing", theme.folderDropRing),
            ("popupCellLabel", theme.popupCellLabel),
            ("popupCellHover", theme.popupCellHover),
            ("popupSecondaryText", theme.popupSecondaryText),
            ("backChipFill", theme.backChipFill),
            ("tooltipText", theme.tooltipText),
        ]
        for (name, tint) in mustBeBlack {
            XCTAssertEqual(tint.base, .black, "\(name) must tint black, white vanishes on light glass")
        }
    }

    /// The shelf is the only chip on the bar that is **not
    /// an app icon**. It must be an **opaque solid tile**:
    /// translucent, it vanishes as soon as what is under the glass
    /// gets dark (reported 2026-08-16), so its colors use `DockRGB`
    /// rather than `DockTint` with its two base colors, black and white. This
    /// assertion stops anyone from turning it back into a translucent tint.
    func testShelfTileIsAnOpaqueColouredTile() {
        for style in DockShelfTileStyle.allCases {
            let c = style.colors
            XCTAssertNotEqual(c.top, c.bottom, "\(style) needs a gradient, a flat color does not look like a real icon")
            // Symbol and tile must sit at opposite ends of light and
            // dark, otherwise the symbol vanishes on its own background.
            let tileLuma = (c.top.luminance + c.bottom.luminance) / 2
            XCTAssertGreaterThan(abs(c.glyph.luminance - tileLuma), 0.3,
                                 "\(style): not enough contrast between symbol and tile")
        }
    }

    /// A drop hit **brightens the whole tile** ("intensifying" means nothing on a solid tile).
    func testShelfTileDropTargetLifts() {
        XCTAssertGreaterThan(DockShelfTileStyle.dropTargetLift, 0)
        let base = DockShelfTileStyle.blue.colors.top
        XCTAssertGreaterThan(base.lightened(by: DockShelfTileStyle.dropTargetLift).luminance,
                             base.luminance)
    }

    /// An unrecognized name falls back to the default style, no crash and no black screen.
    func testShelfTileStyleFallsBackToDefault() {
        for bad in ["", " ", "purple", "1"] {
            XCTAssertEqual(DockShelfTileStyle.resolve(bad), .tray, "invalid value \(bad) must fall back")
        }
        XCTAssertEqual(DockShelfTileStyle.resolve(" GRAPHITE "), .graphite)
        XCTAssertEqual(theme.effectiveShelfTile, theme.shelfTile,
                       "the test process sets no env var, so the effective value must be the table value")
    }

    /// The panel stroke is "bright top edge (white highlight) + dark bottom
    /// edge (thin black line)", the lighting direction of Apple's native glass.
    /// A uniform white stroke all around is the gray frame users saw on a light backing.
    func testPanelRimIsBrightTopDarkBottom() {
        XCTAssertEqual(theme.panelRimTop.base, .white)
        XCTAssertEqual(theme.panelRimBottom.base, .black)
        XCTAssertGreaterThan(theme.panelRimTop.opacity, theme.panelRimBottom.opacity)
    }

    /// The bubble backing locks the **composited reading**, not
    /// individual values, so a rewrite cannot drift either.
    /// The two anchors are measurements of one native bubble on two
    /// backgrounds: 173 on pure black, 216 on the green wallpaper (145).
    func testTooltipPlateMatchesTheMeasuredNativeBubble() {
        func composite(over background: Double) -> Double {
            theme.tooltipPlateOpacity * theme.tooltipPlate.luminance * 255
                + (1 - theme.tooltipPlateOpacity) * background
        }
        XCTAssertEqual(composite(over: 0), 173, accuracy: 6, "measured 173 on black")
        XCTAssertEqual(composite(over: 145), 216, accuracy: 6, "measured 216 on the green wallpaper")
        XCTAssertEqual(composite(over: 235), 247, accuracy: 6, "measured 247 on a light window (third point added 2026-08-17)")
        // Conversely pin "it is translucent": fully opaque cannot
        // follow the background and looks dirty on a light wallpaper.
        XCTAssertLessThan(theme.tooltipPlateOpacity, 0.85)
    }

    /// **The bubble stroke must be brighter than the fill.** The native
    /// profile (black background @2x) is 0 -> 191 -> 209 -> 173:
    /// a specular rim brighter than the fill, which is what cuts
    /// the bubble out of the background. We once used black 0.1,
    /// which amounts to no rim, and the result looked "not crisp".
    func testTooltipRimIsBrighterThanItsFill() {
        XCTAssertEqual(theme.tooltipRim.base, .white, "a dark rim is no rim")
        // The stroke sits on the **composited fill**, not on the
        // backing color; the two differ a lot on a near-white backing.
        func fill(over background: Double) -> Double {
            theme.tooltipPlateOpacity * theme.tooltipPlate.luminance * 255
                + (1 - theme.tooltipPlateOpacity) * background
        }
        func rim(over background: Double) -> Double {
            let f = fill(over: background)
            return f + theme.tooltipRim.opacity * (255 - f)
        }
        // Native measurements: 209 on black (fill 173), 235 on the green wallpaper (fill 216).
        XCTAssertEqual(rim(over: 0), 209, accuracy: 6)
        XCTAssertEqual(rim(over: 145), 235, accuracy: 6)
        // It must be really visible on both backgrounds, that is where "crisp" comes from.
        XCTAssertGreaterThan(rim(over: 0) - fill(over: 0), 20)
        XCTAssertGreaterThan(rim(over: 145) - fill(over: 145), 12)
    }

    // MARK: - Pill and halo: must push the backing away from the text

    /// **The pill's direction must be opposite to the text.**
    ///
    /// The backing is translucent and its luminance follows the **wallpaper**, while the text
    /// color is fixed black; a pill in the same direction as the text flattens the contrast.
    /// Before 2026-08-16 this was black 0.05, tuned back then
    /// to "make a card look like a card", not for legibility,
    /// and exactly the same direction. **Do not follow that intuition and
    /// change it back to black.** The "looks like a card" job belongs to the
    /// `chipPillRimTop` stroke, not to the fill.
    func testChipPillPushesAgainstTheTextColour() {
        XCTAssertEqual(theme.labelActive.base, .black, "premise: the text is black")
        XCTAssertEqual(theme.chipPillFill.normal.base, .white, "wrong direction: the pill must push the backing away from the black text")
        XCTAssertEqual(theme.chipPillFill.emphasized.base, .white)
        XCTAssertGreaterThan(theme.chipPillFill.emphasized.opacity, theme.chipPillFill.normal.opacity,
                             "hover must be stronger than normal")
    }

    /// **The stroke must be brighter than the fill.** A card "looks
    /// like a card" through the `chipPillRimTop` rim, not the fill;
    /// on 2026-08-28 the fill went from 0.13 to 0.24 for legibility
    /// on dark wallpapers, and going higher would swallow the rim
    /// and degrade the card into a white slab smeared on the bar.
    /// To raise the fill further, raise the stroke with it first.
    func testChipPillRimStaysBrighterThanTheFill() {
        XCTAssertEqual(theme.chipPillRimTop.normal.base, .white)
        XCTAssertGreaterThan(theme.chipPillRimTop.normal.opacity, theme.chipPillFill.normal.opacity,
                             "normal: the stroke must be brighter than the fill")
        XCTAssertGreaterThan(theme.chipPillRimTop.emphasized.opacity, theme.chipPillFill.emphasized.opacity,
                             "hover: the stroke must be brighter than the fill")
    }

    /// **The pill fill and the "not on this desktop" text level are a pair, do not tune only one of them.**
    /// Translucent black text is drawn on the pill, text luminance = pill
    /// luminance ×(1−α), so brightening the pill brightens the text too.
    /// Raising the pill therefore rescues `labelActive` (nearly opaque) but not `labelInactive`.
    /// This locks "the gray text must not fade back": it must be clearly
    /// more solid than half, otherwise it dissolves on dark wallpapers
    /// (the 0.45 version is the one that was reported on 2026-08-28).
    func testInactiveLabelStaysReadableOnADarkBackdrop() {
        XCTAssertGreaterThanOrEqual(theme.labelInactive.opacity, 0.55,
                                    "gray text too faint, it dissolves on dark wallpapers and brightening the pill cannot make up for it")
        XCTAssertLessThan(theme.labelInactive.opacity, theme.labelActive.opacity,
                          "it still has to be fainter than the on-desktop level, 'on the current desktop or not' relies entirely on this difference")
    }

    /// The halo of bare text (text with no pill behind it)
    /// also takes the opposite direction of the text, `y = 0`:
    /// the goal is a ring wrapping the text, not a drop shadow.
    func testLabelHaloOpposesTheTextColour() {
        XCTAssertEqual(theme.labelHalo.tint.base, .white, "the text is black, so the halo must be white")
        XCTAssertEqual(theme.labelHalo.y, 0, "the halo has no downward offset")
        XCTAssertGreaterThan(theme.labelHalo.radius, 0)
    }

    // MARK: - Value validity

    func testShadowsFitInsideShadowPaddingBudget() {
        XCTAssertLessThanOrEqual(theme.stripShadow.verticalExtent, shadowPadding)
        XCTAssertLessThanOrEqual(theme.popupShadow.verticalExtent, shadowPadding)
        XCTAssertLessThanOrEqual(theme.labelHalo.verticalExtent, shadowPadding)
    }

    /// Easy to overshoot when tuning by hand.
    func testAllOpacitiesAreInRange() {
        for tint in theme.allTints {
            XCTAssertTrue((0 ... 1).contains(tint.opacity), "opacity out of range: \(tint)")
        }
    }

    /// Gate of the thickness layer: **draw if either pair (inner highlight
    /// / inner shadow) has both color and line width non-zero**.
    /// The test is within one pair: a pair with color 0 or
    /// line width 0 does not count, otherwise an invisible
    /// offscreen render pass is drawn (`.blur(radius: 0)` triggers one too).
    func testThicknessGateNeedsBothColourAndWidthWithinAPair() {
        XCTAssertFalse(DockThemeTokens.drawsThickness(
            highlight: .white(0), highlightWidth: 3, shadow: .black(0), shadowWidth: 3),
            "both pairs have color 0 -> not drawn")
        XCTAssertFalse(DockThemeTokens.drawsThickness(
            highlight: .white(0.1), highlightWidth: 0, shadow: .black(0.1), shadowWidth: 0),
            "both pairs have line width 0 -> not drawn")
        XCTAssertTrue(DockThemeTokens.drawsThickness(
            highlight: .white(0), highlightWidth: 3, shadow: .black(0.1), shadowWidth: 3),
            "inner shadow pair complete -> drawn")
        XCTAssertTrue(DockThemeTokens.drawsThickness(
            highlight: .white(0.1), highlightWidth: 3, shadow: .black(0), shadowWidth: 0),
            "inner highlight pair complete -> drawn")
    }

    // MARK: - Effect switches

    /// **Unaccepted effects are always off by default.** This went wrong
    /// once on 2026-07-30: the glass exploration was correctly default off,
    /// but the saturation boost and thickness layer that landed the same day
    /// were default on, so the bar silently drifted from the approved version.
    func testAllEffectsAreOffByDefault() {
        let empty: [String: String] = [:]
        XCTAssertEqual(DockEffectSwitches.saturation(from: empty, candidate: 1.25), 1.0,
                       "no env var -> no saturation boost")
        XCTAssertFalse(DockEffectSwitches.thicknessEnabled(from: empty), "no env var -> no thickness layer")
        XCTAssertEqual(DockPanelMaterial.resolved(from: empty, fallback: .popover), .popover,
                       "no env var -> material from the token")
    }

    func testSaturationSwitch() {
        XCTAssertEqual(DockEffectSwitches.saturation(
            from: ["DOCK_PANEL_SATURATION": "candidate"], candidate: 1.25), 1.25)
        XCTAssertEqual(DockEffectSwitches.saturation(
            from: ["DOCK_PANEL_SATURATION": " 1.8 "], candidate: 1.25), 1.8)
        for bad in ["", "abc", "0", "-1", "99"] {
            XCTAssertEqual(DockEffectSwitches.saturation(
                from: ["DOCK_PANEL_SATURATION": bad], candidate: 1.25), 1.0, "invalid value \(bad) must fall back")
        }
    }

    func testThicknessSwitch() {
        XCTAssertTrue(DockEffectSwitches.thicknessEnabled(from: ["DOCK_PANEL_THICKNESS": "1"]))
        XCTAssertTrue(DockEffectSwitches.thicknessEnabled(from: ["DOCK_PANEL_THICKNESS": " 1 "]))
        for bad in ["", "0", "true", "yes"] {
            XCTAssertFalse(DockEffectSwitches.thicknessEnabled(from: ["DOCK_PANEL_THICKNESS": bad]))
        }
    }

    func testMaterialOverrideParsesKnownNames() {
        XCTAssertEqual(DockPanelMaterial.resolved(
            from: ["DOCK_PANEL_MATERIAL": "hudWindow"], fallback: .popover), .hudWindow)
        XCTAssertEqual(DockPanelMaterial.resolved(
            from: ["DOCK_PANEL_MATERIAL": " MENU "], fallback: .popover), .menu)
    }

    func testMaterialOverrideFallsBackOnUnknownOrEmpty() {
        for bad in ["", "  ", "notAMaterial"] {
            XCTAssertEqual(DockPanelMaterial.resolved(
                from: ["DOCK_PANEL_MATERIAL": bad], fallback: .popover), .popover, "'\(bad)' must fall back")
        }
    }

    func testMaterialAllCoversEveryCase() {
        XCTAssertEqual(DockPanelMaterial.all.count, 14, "14 system material candidates; update this when adding a case")
    }

    // MARK: - Contrast tuning knobs
    //
    // These two are not the same thing as the "effect switches" above:
    // the defaults **are the approved look**, and the env vars are only
    // tuning knobs for switching back and forth without recompiling
    // (like `DOCK_DRAG_FLIGHT_MS`). So the assertion is
    // "unset / garbage always falls back to the table", not "default off".

    func testContrastOverridesFallBackToTheTable() {
        let pair = DockTintPair(normal: .white(0.24), emphasized: .white(0.336))
        XCTAssertEqual(DockEffectSwitches.chipPillFill(from: [:], candidate: pair), pair)
        XCTAssertEqual(DockEffectSwitches.labelInactive(from: [:], candidate: .black(0.62)), .black(0.62))
        for bad in ["", "  ", "abc", "-0.1", "1.2", "0.2,", "0.2,abc", "0.2,0.3,0.4"] {
            XCTAssertEqual(DockEffectSwitches.chipPillFill(
                from: ["DOCK_CHIP_PILL_FILL": bad], candidate: pair), pair, "invalid value '\(bad)' must fall back")
            XCTAssertEqual(DockEffectSwitches.labelInactive(
                from: ["DOCK_LABEL_INACTIVE": bad], candidate: .black(0.62)), .black(0.62),
                "invalid value '\(bad)' must fall back")
        }
    }

    func testChipPillFillOverrideParses() {
        let pair = DockTintPair(normal: .white(0.24), emphasized: .white(0.336))
        // Only one number given -> hover is derived with the table's existing ×1.4.
        XCTAssertEqual(DockEffectSwitches.chipPillFill(
            from: ["DOCK_CHIP_PILL_FILL": " 0.3 "], candidate: pair),
            DockTintPair(normal: .white(0.3), emphasized: .white(0.3 * 1.4)))
        XCTAssertEqual(DockEffectSwitches.chipPillFill(
            from: ["DOCK_CHIP_PILL_FILL": "0.18, 0.4"], candidate: pair),
            DockTintPair(normal: .white(0.18), emphasized: .white(0.4)))
        // The ×1.4 result must not overflow 1.0.
        XCTAssertEqual(DockEffectSwitches.chipPillFill(
            from: ["DOCK_CHIP_PILL_FILL": "0.9"], candidate: pair).emphasized, .white(1))
    }

    func testLabelInactiveOverrideParses() {
        XCTAssertEqual(DockEffectSwitches.labelInactive(
            from: ["DOCK_LABEL_INACTIVE": " 0.55 "], candidate: .black(0.62)), .black(0.55))
    }

    /// The **base color** of an override has no knob: the pill is always
    /// white and the text always black, an env var cannot flip the direction
    /// (flipping it flattens the contrast, see the comment on `DockThemeTokens.chipPillFill`).
    func testContrastOverridesCannotFlipTheDirection() {
        let pair = DockEffectSwitches.chipPillFill(
            from: ["DOCK_CHIP_PILL_FILL": "0.3"], candidate: theme.chipPillFill)
        XCTAssertEqual(pair.normal.base, .white)
        XCTAssertEqual(pair.emphasized.base, .white)
        XCTAssertEqual(DockEffectSwitches.labelInactive(
            from: ["DOCK_LABEL_INACTIVE": "0.5"], candidate: theme.labelInactive).base, .black)
    }
}

private extension DockThemeTokens {
    /// For iteration: every tint in this table (including the tints carried by shadows). Add new fields here.
    var allTints: [DockTint] {
        [panelRimTop, panelRimBottom, panelRimHighlighted,
         panelInnerHighlight, panelInnerShadow,
         stripShadow.tint, popupShadow.tint,
         chipPillFill.normal, chipPillFill.emphasized,
         chipPillRimTop.normal, chipPillRimTop.emphasized, chipPillRimBottom,
         labelActive, labelInactive, labelHover, labelSubtitle, labelHalo.tint,
         runningDot, zoneDivider,
         shelfDropGlow,
         capsuleGlyph, capsuleStashGlow,
         folderDropRing, folderThumbHairline,
         popupCellLabel, popupCellHover, popupPrimaryText, popupSecondaryText,
         backChipFill, backChipRim, backChipGlyph,
         tooltipRim, tooltipText, tooltipShadow.tint]
    }
}
