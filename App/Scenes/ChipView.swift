import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Chip View

/// Width driver for the label box: an `Animatable` view whose `animatableData` is the box width; body reruns
/// on every animation frame with the interpolated
/// `width`, and `content(width)` uses it to draw `.frame(width:)`. **It must be driven this way, not by the
/// implicit animation of `.frame(width:)`
/// itself**: screen burst captures (2026-09-13) confirmed that path renders in a single step in this taskbar,
/// even with an animation in the transaction and even with the probe measuring the animated variable
/// interpolating; same mechanism as the hover pill's `ChipHoverProgress`.
/// The `boxA:` probe (`DOCK_LABEL_PROBE=1`) also records the per-frame width, to compare with `panel:` on the
/// panel side.
private struct LabelBoxWidthDriver<Content: View>: View, Animatable {
    var width: CGFloat
    let chipID: String
    @ViewBuilder let content: (CGFloat) -> Content
    @Environment(\.labelBoxWidthTick) private var tick
    var animatableData: CGFloat {
        get { width }
        set { width = newValue }
    }
    var body: some View {
        // Report the current box width to the panel every frame (`PanelCoordinator.labelBoxWidthDidTick`);
        // the panel sets its frame in the same turn,
        // committed together with this frame's content. Only SwiftUI's clock is left: the backplate no longer
        // has its own curve or prediction.
        let _ = tick(chipID, width)
        let _ = HoverTrace.width("boxA:" + String(chipID.suffix(4)), width)
        content(width)
    }
}

/// Reporting outlet for the label box's per-frame width, injected by `DockStripView` and pointing at the
/// coordinator of its panel unit. Empty by default:
/// bars not attached to a panel, such as drag carrier snapshots, have no backplate to follow.
struct LabelBoxWidthTickKey: EnvironmentKey {
    static let defaultValue: (String, CGFloat) -> Void = { _, _ in }
}

extension EnvironmentValues {
    var labelBoxWidthTick: (String, CGFloat) -> Void {
        get { self[LabelBoxWidthTickKey.self] }
        set { self[LabelBoxWidthTickKey.self] = newValue }
    }
}

struct ChipView: View {
    @EnvironmentObject var runtime: AppRuntime
    @EnvironmentObject var drawerStore: DrawerStore
    @EnvironmentObject var messagingStore: MessagingAppStore
    @EnvironmentObject var keptAppStore: KeptAppStore
    @EnvironmentObject var appMembershipController: AppMembershipController
    private let theme = DockThemeTokens.standard
    /// fork: Appearance overrides. Observed so a change in Settings repaints every chip live.
    @ObservedObject private var fork = ForkAppearanceModel.shared
    let item: StripItem
    /// The line of text shown on the card, computed by the projection layer (app-name suffix removed + the
    /// common segment of one app's cards, issue #41).
    /// **Deliberately no default value**: a missing argument would silently show the unprocessed long title,
    /// and all tests here are pure geometry,
    /// none checks the SwiftUI call sites, so the missing default is the regression test (same hard rule as
    /// `scale`).
    /// The full title goes through `fullTitle`, only for the system tooltip of `.help()`.
    let labelTitle: String
    /// Tier factor (`DockSize.scale`). **Deliberately no default value**: the message zone once silently
    /// omitted it because it defaulted to 1.0,
    /// and rendered at medium size in non-medium tiers (see the Taskbar Size Tiers project rule). Omitting it
    /// must be a compile error.
    let scale: CGFloat
    /// Hover effect style. **Also deliberately no default value**: omitting it is a compile error, for the
    /// reason given at `scale` above.
    /// Under `.quiet` hover causes no visual change; the full-text overlay for long titles is unaffected (it
    /// follows the bare `isHovering`).
    let hoverStyle: HoverStyle
    /// Whether the pointer is on this card. **Computed by the taskbar's single whole-bar tracking area and
    /// passed in**; the card no longer attaches its own `.onHover`
    /// (missed cells + direction-dependent boundaries, cause and measurements in `StripHoverResolution`).
    /// Also deliberately no default value.
    let isHovered: Bool
    /// Whether the top of the context menu lists the Dock-style window list. True only for entries where "one
    /// icon stands for the whole app"
    /// (live zone = `item.isAppLevelFallback`, message-zone main-window card = always true); an ordinary
    /// window card is itself
    /// that window, always false. **Deliberately no default value**: omitting it must be a compile error
    /// (same hard rule as `scale`).
    let showsWindowListInMenu: Bool
    var iconOnly: Bool = false
    var showRunningDot: Bool = false
    /// See `EnvironmentValues.isDragCarrierSnapshot`: no dot and no baked shadow when capturing the copy.
    @Environment(\.isDragCarrierSnapshot) private var isDragCarrierSnapshot
    var drawerTap: (() -> Void)? = nil
    /// Pulse signal from external gestures (force click / middle-click preview): a nonce change fires one
    /// fireTapPulse,
    /// an instant "got the click" confirmation covering the ~200ms reverse-lookup delay of live Finder window
    /// preview. Default 0 = no pulse.
    var pulseNonce: Int = 0
    /// Unread badge text (messaging app cards: the message-zone icon, or the leftmost one in the regular
    /// zone), `nil` = not drawn. Defaulting to `nil` is the **correct** omission semantics
    /// (most chips have no badge anyway), so this one may have a default, unlike `scale` /
    /// `hoverStyle`, where an omission silently renders wrong.
    /// Drawn inside the chip rather than stacked by the caller in a ZStack, for the reason in `ChipBadgeView`.
    var badgeText: String? = nil
    /// Whether this card's slot is currently empty because it is **being held in the hand**
    /// (`DragController.hiddenSlotPayload`).
    /// As soon as it turns true the press scale is cleared: an in-bar reorder moves this card, SwiftUI then
    /// cancels the press gesture,
    /// and `isTapPressed` can only be reset by the 1s watchdog, so when the card reappears on landing it may
    /// still be at 0.93 or bouncing back,
    /// a visible gap from the carrier resting at 1.0 (one component of the 2026-08-19 "landing jitter").
    /// Cleared while the card is hidden,
    /// so it is always 1.0 when it reappears. Defaulting to `false` is the correct omission semantics (cards
    /// not being dragged don't need it), same as `badgeText`.
    var slotHidden: Bool = false
    /// Click confirmation pulse: a state-independent press bounce. Activating an "already visible" window
    /// changes nothing on the bright/dim axis,
    /// so without it there is "no response at all" (2026-07-06). Pure view-layer signal, never feeds the
    /// planner/frontmost axis.
    /// Driven by declarative .animation(value:) (lesson from the LauncherChip zombie animation: no
    /// repeatForever+reset).
    @State private var isTapPressed = false

    /// Visual hover state: the real pointer hover OR forced (drag copy), then gated by the hover style.
    /// Always false in "quiet" mode, so the icon doesn't shrink, the app name doesn't appear, the pill fill
    /// doesn't brighten and the row doesn't reflow.
    private var showsHover: Bool { hoverStyle.showsExpressiveHover(isHovering: isHovered) }
    /// Hover feedback for quiet mode (always false in standard mode, whose feedback is the name bubble).
    private var quietHoverFeedback: Bool {
        hoverStyle.showsQuietHoverFeedback(isHovering: isHovered)
    }
    private var animationTraceKind: String {
        !iconOnly && (item.showsTitle || isMessagingAppWindow) ? "window" : "icon"
    }

    /// Diagnostic outlet for press state. The state machine itself lives in `ChipPressFeedback`; this only
    /// adds trace.
    private func recordPressEvent(_ pressed: Bool) {
        ChipAnimationTrace.event(
            chipID: item.id,
            kind: animationTraceKind,
            event: ChipAnimationTraceEvent.tap(pressed),
            isTapPressed: pressed,
            showsHover: showsHover
        )
    }

    private func recordHoverEvent(_ hovering: Bool) {
        ChipAnimationTrace.event(
            chipID: item.id,
            kind: animationTraceKind,
            event: ChipAnimationTraceEvent.hover(hovering),
            isTapPressed: isTapPressed,
            showsHover: hoverStyle.isExpressive && hovering
        )
    }

    /// Optimistic state first (interaction polish 2026-06-13): on click the chip renders the predicted state
    /// at once
    /// (minimize -> dim), without waiting for the snapshot round-trip and without a spinner.
    private var effectiveStatus: String {
        runtime.optimisticStatesByWindowID[item.actionWindowID]?.status.rawValue ?? item.status
    }

    private var effectiveIsOnDesktop: Bool {
        guard let optimistic = runtime.optimisticStatesByWindowID[item.actionWindowID] else {
            return item.isOnDesktop
        }
        return optimistic.status == .active
    }

    private var isMessagingAppWindow: Bool {
        guard let bid = item.bundleIdentifier else { return false }
        return !item.isAppLevelFallback && messagingStore.contains(bid)
    }

    var body: some View {
        Group {
            if !iconOnly && (item.showsTitle || isMessagingAppWindow) {
                multiWindowChip
            } else {
                bareIconChip
            }
        }
        .animation(.easeInOut(duration: 0.2), value: item.showsTitle)
        // Clear the press as soon as the slot empties (reason at `slotHidden`). The card is transparent now,
        // so nobody sees this bounce.
        .onChange(of: slotHidden) { hidden in
            if hidden, isTapPressed { isTapPressed = false }
        }
    }

    // MARK: - Icon-only chip

    private var bareIconChip: some View {
        let capturedFullTitle = fullTitle
        // **Hover on an icon-only card changes no pixels**, so no animation driver is attached here.
        //
        // Since the app name moved into the bubble above the icon, the icon no longer shrinks, the slot no
        // longer changes, and the icon never fades by state
        // (2026-08-02), so the only thing `ChipHoverProgress` still did was run an animatable scalar
        // for the full 0.18s, recomputing a dozen frames for nothing on every hover enter/exit. Sweeping
        // across a row of icons stacks that cost on the main thread,
        // and when the main thread is busy macOS **coalesces mouse-move events**, so the cells passed over
        // never get a hover callback at all:
        // exactly the "many don't show in time when sweeping at constant speed" report. The same mechanism
        // bit menus once,
        // see the 100ms stickiness item in the Menus, Panels, And Screens project rule.
        //
        // Titled cards still need it: the pill fill and stroke brightening really do animate.
        let hover = ChipHoverVisual.resolve(progress: 0, scale: scale)
        let _ = ChipAnimationTrace.record(
            chipID: item.id,
            kind: "icon",
            visual: hover,
            isTapPressed: isTapPressed,
            showsHover: showsHover
        )
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            appIcon(size: hover.bareIconSize)
            // The slot height must equal the **resting** icon size: this ZStack is .top aligned,
            // so a slot smaller than the icon overflows downward as a whole (measured 4pt down when 36 was
            // hardcoded and the icon became 40).
            .frame(width: ChipPillMetrics.cardWidth * scale,
                   height: ChipPillMetrics.bareIconSlot * scale,
                   alignment: .top)
            Spacer(minLength: 0)
        }
        .frame(width: ChipPillMetrics.cardWidth * scale,
               height: ChipPillMetrics.chipHeight * scale)
        // The dragged copy draws no dot (same as the native Dock: the dot disappears while dragging and
        // returns on landing).
        // The bitmap is therefore **transparent** where the dot is, and during the handoff turn the dot of
        // the card on the bar shows straight through: no flash, no delay.
        .overlay(alignment: .bottom) {
            if showRunningDot && !isDragCarrierSnapshot {
                ForkRunningDot(theme: theme)
            }
        }
        // Unread badge: **must be attached before both scales**, otherwise it stays still while the icon
        // grows / shrinks on press
        // (2026-08-17: should the number badge also change when the icon grows).
        .overlay(alignment: .topTrailing) {
            if let badgeText {
                ChipBadgeView(text: badgeText, scale: scale)
            }
        }
        // Hover feedback for quiet mode: the whole block grows slightly. Placed **after** the running-dot
        // overlay so icon and dot grow together;
        // placed before `chipPressScale` so on press the two scales multiply, like one object being pressed.
        // Card width 40 -> the cap rule yields 1.15, clamped back to 1.10 by the upper bound, so icon cards
        // look pixel-identical.
        .chipQuietHoverScale(quietHoverFeedback,
                             cardWidth: ChipPillMetrics.cardWidth * scale,
                             scale: scale)
        .chipPressScale(isTapPressed)
        // This card neither measures hover itself nor sends the bubble itself: both belong to the taskbar's
        // whole-bar tracking area
        // (`StripHoverResolution`). All that is left here is "draw according to `isHovered`".
        .contentShape(Rectangle())
        .onChange(of: isHovered) { recordHoverEvent($0) }
        .onTapGesture {
            if let drawerTap { drawerTap() } else { runtime.toggle(windowID: item.actionWindowID) }
        }
        // Press follows **press-down**, no longer waiting for onTapGesture (which fires on mouse up).
        // Attached after contentShape,
        // so the hit area matches the click exactly.
        .chipPressGesture(
            isPressed: $isTapPressed,
            pulseNonce: pulseNonce,
            onEvent: recordPressEvent
        )
        .nativeContextMenu { buildChipMenu() }
        .help(capturedFullTitle)
    }

    // MARK: - Labeled chip

    /// The pill's fill + stroke, the **only** thing on this card that still changes with hover.
    /// Per-frame interpolation stops here, for the reason in the comment in `multiWindowChip`.
    private var pillEmphasisBackground: some View {
        ChipHoverProgress(progress: showsHover ? 1 : 0) { progress in
            let shape = RoundedRectangle(cornerRadius: fork.value.resolvedCardCornerRadius(scale: scale), style: .continuous)
            // The diagnostic sampling point for hover progress must stay here: it needs the per-frame progress
            // (`DOCK_CHIP_ANIM_TRACE=1`, off by default).
            let _ = ChipAnimationTrace.record(
                chipID: item.id,
                kind: "window",
                visual: ChipHoverVisual.resolve(progress: progress, scale: scale),
                isTapPressed: isTapPressed,
                showsHover: showsHover
            )
            shape
                .fill(fork.cardFill(theme: theme).color(emphasisProgress: Double(progress)))
                .overlay(
                    shape.strokeBorder(
                        theme.chipPillRimStyle(emphasisProgress: Double(progress)),
                        lineWidth: 0.5
                    )
                )
        }
        .animation(.easeInOut(duration: 0.18), value: showsHover)
    }

    private var multiWindowChip: some View {
        // The icon always keeps its original color (no fading by state, 2026-08-02); "on the desktop or not"
        // is expressed by the title color only.
        let titleColor: Color = fork.cardLabel(effectiveIsOnDesktop ? theme.labelActive : theme.effectiveLabelInactive).color
        let capturedDisplayTitle = displayTitle
        let capturedFullTitle = fullTitle
        // **The animatable scalar wraps only the pill's fill and stroke, not the whole card.**
        //
        // `ChipHoverProgress` is an `Animatable` view: each change of its `animatableData` reruns
        // the content closure. It used to wrap the whole card, so **every frame** of the 0.18s animation
        // recomputed the icon, text,
        // padding and layout, while only the pill fill and stroke actually moved; the other fields of
        // `ChipHoverVisual`
        // (icon size, pill height) have all been constants since hover geometry was frozen on 2026-08-16.
        // When sweeping across a row of titled cards this cost is multiplied by the card count.
        //
        // Moved inside `.background`, only two shapes are recomputed per frame, with identical interpolation
        // function and values,
        // so the look is pixel-identical (that is the signed-off look).
        let metrics = ChipHoverVisual.resolve(progress: 0, scale: scale)
        let pill = HStack(spacing: ChipPillMetrics.iconSpacing * scale) {
            appIcon(size: metrics.pillIconSize)
                .frame(width: ChipPillMetrics.iconSlot * scale, height: ChipPillMetrics.iconSlot * scale)
                // Unread badge (also drawn on regular-zone cards since 2026-08-23): sits on the top-right
                // corner of the small icon in the pill, shrunk one step by
                // `titledCardBadgeScale`: a 16pt badge on a 22pt icon is too crowded.
                // Also attached before both scales, moving with hover / press / tier.
                .overlay(alignment: .topTrailing) {
                    if let badgeText {
                        ChipBadgeView(text: badgeText, scale: scale * ChipPillMetrics.titledCardBadgeScale)
                    }
                }
            titleLabel(capturedDisplayTitle, color: titleColor)
        }
        .padding(.horizontal, ChipPillMetrics.horizontalPadding * scale)
        .frame(height: metrics.pillHeight)
        .background(pillEmphasisBackground)

        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            pill
                .frame(height: ChipPillMetrics.boxHeight * scale, alignment: .top)
            Spacer(minLength: 0)
        }
        .frame(height: ChipPillMetrics.chipHeight * scale)
        .padding(.horizontal, ChipPillMetrics.titledCardInset * scale)
        // Hover feedback for quiet mode: the whole block grows slightly (standard mode's feedback is the name
        // bubble + pill brightening).
        //
        // **The card width passed must be this card's own**: uniform scaling expands far more on a wide card
        // (measured: a 168.5pt card
        // expands 8.4pt per side, squeezing the 10pt gap between cards to 3.5pt, reported 2026-08-17).
        // The width uses the same `ChipPillMetrics.width` that renders the pill, not a second copy.
        .chipQuietHoverScale(
            quietHoverFeedback,
            cardWidth: ChipPillMetrics.width(title: capturedDisplayTitle, scale: scale)
                + 2 * ChipPillMetrics.titledCardInset * scale,
            scale: scale
        )
        .chipPressScale(isTapPressed)
        // Same as bareIconChip: hover and bubble belong to the taskbar's whole-bar tracking area; this only
        // draws according to `isHovered`.
        .contentShape(Rectangle())
        .onChange(of: isHovered) { recordHoverEvent($0) }
        .onTapGesture {
            if let drawerTap { drawerTap() } else { runtime.toggle(windowID: item.actionWindowID) }
        }
        .chipPressGesture(
            isPressed: $isTapPressed,
            pulseNonce: pulseNonce,
            onEvent: recordPressEvent
        )
        .nativeContextMenu { buildChipMenu() }
        // The label truncates at 140pt, and the title on this card also has the app-name suffix removed, so
        // this is the only outlet left for the full title.
        // (The hover bubble doesn't count: it shows the app name, and new installs default to `.quiet` with
        // no bubble at all.)
        .help(capturedFullTitle)
    }

    // MARK: - Title Label

    /// Label text transition: the old text fades out quickly **first**, the new text **then** slides in from
    /// the icon side and fades in. The two phases are staggered, not overlapped
    /// (with a simultaneous cross-fade two lines of different length overlap and the word start ghosts for a
    /// moment). The total must be shorter than the box's width animation
    /// (`LabelWidthAnimation.curve.duration`): the text settles first while the box is still finishing; the
    /// other way round it reads as two separate motions.
    private static let labelRemoval: Animation = .easeOut(duration: 0.16)
    private static let labelInsertion: Animation = .easeOut(duration: 0.34).delay(0.14)
    /// Offset of the new text from its final position at the start (unscaled), toward the icon side.
    private static let labelInsertionOffset: CGFloat = 3

    /// The line of text on a titled card.
    ///
    /// **The width is given explicitly, the text is swapped by identity**: when the title goes from short to
    /// long (or back), three things on this card
    /// change: the text, the pill width, the position of the neighbor card on the right; the panel window's
    /// glass backplate is chased by `PanelCoordinator`
    /// with a separate 0.22s AppKit animation. If `Text` sizes itself, the first three change in one step and
    /// only
    /// the backplate slides, which is the "stiff, abrupt" report of 2026-09-12. The three are separated here:
    /// - the outer box's `.frame(width:)` uses the taskbar layout animation that shares the backplate's curve
    ///   and duration
    ///   (the one triggered by `labelTitleByChipID` on `DockStripView`); the pill and neighbor cards slide
    ///   with it;
    /// - the text swaps identity via `.id(title)` with an asymmetric transition: the old text fades out
    ///   first, then the new text slides and fades in, no instant swap;
    /// - each `Text` only knows its own width (fixed width and truncation only above the limit) and is **not
    ///   re-laid out at the box's intermediate widths**,
    ///   otherwise the ellipsis is recomputed on every frame of the animation and the tail jitters.
    /// `.clipped()` only clips to the box's current width: when growing, the new text is revealed frame by
    /// frame from the icon side; when shrinking, the old text is tucked in.
    private func titleLabel(_ title: String, color: Color) -> some View {
        let boxWidth = ChipPillMetrics.labelWidth(title: title, scale: scale)
        let truncates = ChipPillMetrics.labelTruncates(title: title, scale: scale)
        return LabelBoxWidthDriver(width: boxWidth, chipID: item.id) { liveWidth in ZStack(alignment: .leading) {
            Text(title)
                .font(.system(size: WindowTitleTextMetrics.fontSize(scale: scale), weight: .medium, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(fork.value.truncatesTitleInMiddle ? .middle : .tail)   // fork; .tail is SwiftUI's default
                .frame(width: truncates ? WindowTitleTextMetrics.maximumWidth(for: scale) : nil,
                       alignment: .leading)
                .fixedSize(horizontal: !truncates, vertical: false)
                .id(title)
                .transition(.asymmetric(
                    insertion: .opacity
                        .combined(with: .offset(x: -Self.labelInsertionOffset * scale))
                        .animation(Self.labelInsertion),
                    removal: .opacity.animation(Self.labelRemoval)
                ))
        }
        // Wraps only the text transition; the box's `.frame(width:)` is **outside** this layer and gets the
        // taskbar layout animation.
        // Each of the two transition phases has its own curve; this one only puts the swap in an animatable
        // transaction.
        .animation(Self.labelInsertion, value: title)
        // The box width is the `liveWidth` the driver gives each frame (reason at `LabelBoxWidthDriver`);
        // neighbor cards reflow with it per frame.
        .frame(width: liveWidth, alignment: .leading)
        .clipped()
        }
        // Drives only `LabelBoxWidthDriver.animatableData`; the curve is `LabelWidthAnimation`, shared with
        // the panel backplate.
        .animation(LabelWidthAnimation.swiftUI, value: boxWidth)
        // fork: a width change caused by an Appearance setting snaps (see `layoutIdentity`).
        .id(fork.value.layoutIdentity)
    }

    // MARK: - Shared Icon

    private func appIcon(size: CGFloat) -> some View {
        Image(nsImage: AppIconResolver.icon(for: item.bundleIdentifier ?? item.appID))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size / 4, style: .continuous))
            // We add **no extra** outer shadow (2026-08-19): the layer once added was a pure surplus;
            // measured on the bar, directly below the icon was 18–24 darker than the gaps on either side.
            // Same for the shelf tile and folder covers.
            //
            // ⚠️ This used to say "measured: macOS icon assets cast no shadow, alpha right below the body is
            // exactly 0".
            // **That was wrong, disproven on 2026-08-20**: it measured only one line right below the icon,
            // while the ring of shadow built into the asset
            // is **all around**. Per-pixel measurement (Preview's icon, 32pt): about 5px outside the body is
            // semi-transparent pure black,
            // alpha rising from 0.004 to 0.102, brightness always 0 (measured 2026-08-20).
            // So the dark rim around the icon at rest is **drawn into the asset by Apple**, not by us.
    }

    // MARK: - Context Menu

    // Interruptible (2026-06-13): menu items are no longer greyed out by pending; show/hide actions are
    // clickable at any time
    // (the optimistic overlay keeps things consistent), and runtime.trigger guards close / quit against
    // reentry.
    // State branches read effectiveStatus, so right-clicking right after a minimize already shows "Restore".
    private var isFinderChip: Bool { FinderTaskbarPolicy.isFinder(item.bundleIdentifier) }

    /// Native AppKit menu rebuilt fresh on each right-click (captures live runtime
    /// + store + optimistic state). See AppMenuFragments for why this isn't SwiftUI.
    private func buildChipMenu() -> NSMenu {
        let menu = NSMenu()
        let bid = item.bundleIdentifier
        // Window list first (app-level entries only; order set 2026-08-24): ✓ frontmost window, ◇
        // minimized.
        // Read-only snapshot: the menu is built synchronously at right-click, with no AX on this path.
        if showsWindowListInMenu, let listBid = bid {
            AppMenuBuilder.appendWindowList(
                to: menu,
                entries: WindowListMenuPlan.entries(
                    snapshot: runtime.snapshot,
                    bundleID: listBid,
                    fallbackTitle: AppDisplayNameResolver.displayName(for: listBid)
                ),
                activate: { runtime.activate(windowID: $0) }
            )
        }
        // Recents on top: Finder shows "Recently used folders" (FXRecentFolders), other apps show "Recently
        // used files".
        if isFinderChip {
            AppMenuBuilder.appendFinderRecentFolders(to: menu)
        } else {
            AppMenuBuilder.appendRecentDocuments(to: menu, bundleID: bid)
        }
        if item.isAppLevelFallback {
            if isFinderChip { AppMenuBuilder.appendFinderItems(to: menu) }
            if effectiveStatus == "hidden" {
                menu.addItem(ClosureMenuItem(String(localized: "Show")) { runtime.activate(windowID: item.actionWindowID) })
            } else {
                menu.addItem(ClosureMenuItem(String(localized: "Hide")) { runtime.hide(windowID: item.actionWindowID) })
            }
            // Member items first, Quit always last, consistent with the window card branch below.
            appendMembershipItems(to: menu)
            menu.addItem(.separator())
            AppMenuBuilder.appendQuitItems(to: menu, bundleID: bid) {
                runtime.quit(windowID: item.actionWindowID)
            }
        } else {
            if isFinderChip { AppMenuBuilder.appendFinderItems(to: menu) }
            menu.addItem(ClosureMenuItem(String(localized: "New Window")) { runtime.newWindow(windowID: item.actionWindowID) })
            if effectiveStatus == "minimized" {
                menu.addItem(ClosureMenuItem(String(localized: "Restore")) { runtime.activate(windowID: item.actionWindowID) })
            } else {
                menu.addItem(ClosureMenuItem(String(localized: "Minimize")) { runtime.minimize(windowID: item.actionWindowID) })
            }
            if effectiveStatus == "hidden" {
                menu.addItem(ClosureMenuItem(String(localized: "Show")) { runtime.activate(windowID: item.actionWindowID) })
            } else {
                menu.addItem(ClosureMenuItem(String(localized: "Hide App")) { runtime.hide(windowID: item.actionWindowID) })
            }
            appendMembershipItems(to: menu)
            menu.addItem(.separator())
            // Close the whole group (2026-06-14): "Close Window" on a tab group closes every tab in the group;
            // an ordinary window has memberWindowIDs == [id], behavior unchanged.
            menu.addItem(ClosureMenuItem(String(localized: "Close Window")) {
                for wid in item.memberWindowIDs { runtime.close(windowID: wid) }
            })
            AppMenuBuilder.appendQuitItems(to: menu, bundleID: bid) {
                runtime.quit(windowID: item.actionWindowID)
            }
        }
        AppMenuBuilder.appendForkSettingsItem(to: menu)   // fork
        return menu
    }

    /// Kept membership conversions go through the controller. Messaging remains
    /// mutually exclusive with kept membership. Stashing (into the drawer) gets no menu entry:
    /// the only path is dragging onto the capsule/drawer (2026-07-10: the context menu keeps only "Keep in
    /// Dock" and the messaging mark).
    private func appendMembershipItems(to menu: NSMenu) {
        guard let bid = item.bundleIdentifier else { return }
        let items = LauncherMembershipItem.items(
            surface: .strip,
            bundleID: bid,
            isKept: keptAppStore.contains(bid),
            isMessaging: messagingStore.contains(bid),
            controller: appMembershipController
        )
        guard !items.isEmpty else { return }
        menu.addItem(.separator())
        for descriptor in items {
            menu.addItem(AppMenuBuilder.membershipItem(descriptor))
        }
        AppMenuBuilder.appendForkSettingsItem(to: menu, separated: false)   // fork
    }

    // MARK: - Helpers

    /// The label rendered on the card (`labelTitle` computed by the projection layer).
    ///
    /// **This one string feeds three places**: the rendered `Text`, the `chipQuietHoverScale` derived from
    /// `ChipPillMetrics.width(title:scale:)`,
    /// and the bubble anchor computed by `ChipPillMetrics.pillRect`. If any of them goes back to
    /// `fullTitle`, the hover scale cap and the bubble tail anchor to a width that doesn't exist.
    private var displayTitle: String { labelTitle }

    /// The untruncated full title, for the system tooltip only: an icon-only card shows no text, so a
    /// truncated app name would be visible nowhere.
    private var fullTitle: String {
        WindowDisplayTitle.resolve(rawTitle: item.title, fallbackName: appName)
    }

    private var appName: String {
        let name = item.bundleIdentifier.map(AppDisplayNameResolver.displayName(for:)) ?? item.appID
        return WindowDisplayTitle.resolve(rawTitle: nil, fallbackName: name)
    }
}
