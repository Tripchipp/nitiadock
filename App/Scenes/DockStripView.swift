import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

struct DockStripView: View {
    /// fork: Appearance overrides for spacing (the rest are read inside the chips).
    @ObservedObject var fork = ForkAppearanceModel.shared
    @EnvironmentObject var runtime: AppRuntime
    @EnvironmentObject var drawerStore: DrawerStore
    @EnvironmentObject var messagingStore: MessagingAppStore
    @EnvironmentObject var badgeStore: BadgeStore
    @EnvironmentObject var stripOrderStore: StripOrderStore
    @EnvironmentObject var pinnedFolderStore: PinnedFolderStore
    @EnvironmentObject var folderCoverStore: PinnedFolderCoverStore
    @EnvironmentObject var shelfStore: ShelfStore
    @ObservedObject var trashStore = TrashStateStore.shared
    @EnvironmentObject var settingsStore: AppSettingsStore
    @EnvironmentObject var displayTopologyStore: DisplayTopologyStore

    /// Whether this taskbar's backplate is native Liquid Glass. Fixed once by `PanelCoordinator` when
    /// building the panel
    /// (true only if the background window was built), **passed in explicitly with no default value**: like
    /// `scale` / `hoverStyle`,
    /// omitting it is a compile error. Don't go back to reading a global static: SwiftUI can't observe it,
    /// and it reads stale after panel teardown.
    let usesLiquidGlass: Bool
    /// This taskbar's surface identity in `DragController` (under multi-display ③④ there is one per display
    /// with identical content, see
    /// `DragController.activeStripSurfaceID`). **Passed in explicitly, no default**: omitting it means two
    /// bars write back the landing at once.
    let stripSurfaceID: String
    /// The display this bar is on (a ③④ fixed unit passes the display UUID; a ①② following unit passes nil).
    /// Under multi-display ④ only window cards belonging to
    /// this display are drawn. **Passed in explicitly, no default**: omitting it means every display draws
    /// all windows and ④ silently degrades to ③.
    /// Switching ③↔④ doesn't rebuild units (same key list), so whether to filter is read from
    /// `settingsStore.taskbarScreenPlacement`.
    let displayUUID: String?

    /// Whether this bar is the active surface of the current drag. With no claimant (a drawer drag not yet
    /// converted) every bar may act: the one whose bar box contains the pointer converts and claims.
    var ownsActiveDrag: Bool {
        guard let active = dragController.activeStripSurfaceID else { return true }
        return active == stripSurfaceID
    }

    /// Panel geometry and scale factor derived from the current size tier. **No bare size numbers inside the
    /// bar**: every value that
    /// scales with the taskbar is multiplied by `dockScale`; hairlines (divider width, strokes) stay 1pt
    /// unscaled.
    private var metrics: PanelLayoutMetrics { settingsStore.dockSize.metrics }
    var dockScale: CGFloat { settingsStore.dockSize.scale }
    /// Taskbar corner radius. **Same value for glass and frosted material**: geometry has a single source,
    /// `DockSize.metrics` /
    /// `DockShape`, and changing the backplate material doesn't change sizes (otherwise the four-tier scaling
    /// breaks; `scale` is defined
    /// as `panelHeight / 52`).
    private var taskbarCornerRadius: CGFloat { Style.cornerRadius * dockScale }
    /// Hover effect style. Every chip in the bar receives it explicitly (like `dockScale`, omitting it is a
    /// compile error);
    /// the drawer panel and the drawer entry capsule are deliberately unaffected (2026-08-02).
    var hoverStyle: HoverStyle { settingsStore.hoverStyle }
    @EnvironmentObject var keptAppStore: KeptAppStore
    @EnvironmentObject var runningApplicationStore: RunningApplicationStore
    @EnvironmentObject var appMembershipController: AppMembershipController

    /// The light / dark sets of visual values (see `DockThemeTokens`). The dark column is frozen historical
    /// values; tune the look in the light column only.
    private let theme = DockThemeTokens.standard

    /// Folder chip click -> popup toggle (path + chip visible rect in screen coordinates). Injected by
    /// PanelCoordinator.
    var onFolderPopupToggle: (String, CGRect) -> Void = { _, _ in }
    /// Shelf click -> shelf popup toggle (chip visible rect in screen coordinates). Injected by
    /// PanelCoordinator.
    var onShelfPopupToggle: (CGRect) -> Void = { _ in }
    /// Trash click -> Trash popup toggle (chip visible rect in screen coordinates). Injected by
    /// PanelCoordinator.
    var onTrashPopupToggle: (CGRect) -> Void = { _ in }
    /// Single entry for "Add Folder…" (the NSOpenPanel is owned by AppDelegate).
    var onAddFolder: () -> Void = {}
    /// After an external file hits a pinned folder chip, bubbled up to the composition layer to do the move
    /// in the background.
    var onMoveExternalFiles: ([URL], String) -> Void = { _, _ in }
    /// The **only** outlet for the hover name bubble (the whole bar has this one sender, see `bubbleRequest`).
    /// PanelCoordinator handles presenting and tearing down that separate panel.
    var onWindowTitleTooltipEvent: (WindowTitleTooltipEvent) -> Void = { _ in }
    /// Right-click on the taskbar backplate -> pop up the NitiaDock menu (`StatusMenuController` holds that
    /// menu).
    var onRequestTaskbarMenu: (NSEvent, NSView) -> Void = { _, _ in }
    /// In the SwiftUI update where labels grow or shrink, tells the panel to open the follow window, with the
    /// **starting width** of each label box that begins moving
    /// (`[chipID: old label box width]`, pt); afterwards the live per-frame width is reported by
    /// `onLabelBoxWidthTick`, from which the panel computes the total content width
    /// (`PanelCoordinator.beginLabelWidthFollow(starting:)`). The empty default is the correct omission
    /// semantics: bars not attached to a panel
    /// (drag carrier snapshots) have no backplate to follow.
    var onLabelWidthChange: ([String: CGFloat]) -> Void = { _ in }
    /// The live per-frame width of a label box (reported by `LabelBoxWidthDriver` through the environment),
    /// forwarded to the panel to set its frame per frame.
    var onLabelBoxWidthTick: (String, CGFloat) -> Void = { _, _ in }
    /// Cross-panel drag authority (drag card into drawer, route C): drag start -> beginDrag; reads
    /// draggingItem to hide the card in place,
    /// reads isOverDropZone to stop in-bar reorder on entering the drop zone. Carrier panel / monitors /
    /// teardown all live inside it; this view doesn't touch them.
    @EnvironmentObject var dragController: DragController

    /// Live chip frames by id in the `"strip"` space (on-screen position after scroll offset), collected via
    /// preference. Feeds the grab offset at drag start and the full-frame landing hit-test.
    /// `.background` GeometryReader (not overlay) so it never steals chip clicks.
    @State var chipFrames: [String: CGRect] = [:]
    /// Per-chip pulse counters fired by gesture preview (+1 on force click / middle-click of a live Finder
    /// window, an instant "got the click" for the ~200ms reverse lookup).
    @State var chipPulseNonces: [String: Int] = [:]

    /// Folder chip frames (popup anchor + pin landing routing for external drags). **A separate dictionary,
    /// never mixed into chipFrames**:
    /// those are the input for live window-zone drag reorder and drawer drag-back landing, and mixing would
    /// make window drags hit the folder zone with a no-op landing (review P1).
    @State var folderChipFrames: [String: CGRect] = [:]

    /// Message-zone chip frames (bundleID -> "strip"-space frame). **A separate dictionary, never mixed into
    /// chipFrames for the same reason as folder chips**: feeds in-zone reorder hit-testing + the
    /// "message-zone range" release decision for drawer drag-out.
    @State var messagingChipFrames: [String: CGRect] = [:]
    /// Which message-zone icon the carrier is drawing now (image-swap dedup on the release-to-message-zone
    /// path). See `syncReleasedMessagingCarrier`.
    @State private var carriedMessagingChipID: String?
    /// The `stripSlotCollapsed` seen by the previous body pass (updated one pass late in `.onChange`). If the
    /// two differ in body, this
    /// `layoutKeys` change is the empty slot closing / reopening, and the in-bar animation must use **the
    /// same curve and duration** as the panel window animation:
    /// a spring (0.28s) on top of AppKit easeInEaseOut (0.22s) makes the icons lead and lag the backplate,
    /// which is the "not natively smooth" moment
    /// in the 2026-09-03 screen recording.
    @State private var renderedCollapsed = false
    /// The label table rendered in the previous pass: used to compute how much this label change alters the
    /// total content width (only cards that actually draw a title, form `.multi`).
    @State private var renderedLabelTitles: [String: String] = [:]

    /// Shelf frame ("strip" space). **Reported separately, not put into folderChipFrames** (review: that
    /// dictionary belongs to
    /// folder chips and later also feeds folder reorder hit-testing, so no sentinel may be mixed in). Feeds
    /// the shelf popup anchor + drop routing.
    @State var shelfFrame: CGRect = .zero
    @State var trashFrame: CGRect = .zero

    /// Live drop target of an external file drag (for the hover highlight; nil = no external drag hovering).
    @State var externalDropTarget: StripDropRouting.Target?

    /// Make-room gap while dragging an app in from Finder (nil = no gap). The projection layer inserts an
    /// `.externalDropGhost` from it.
    /// **Written only when the anchor really changed** (the gate in `updateExternalDropGhost`): any change
    /// recomputes the whole bar.
    @State var externalDropGhost: StripDropGhost?

    /// Fallback cleanup of the gap during landing: after `performDrop` the gap stays until the real icon
    /// enters the projection (otherwise
    /// "gap closes -> icon pops in" flashes), and this Timer guarantees it never lingers on any abnormal path.
    @State var externalDropGhostTimeout: Timer?

    /// Bar width frozen during an external drop hover (nil = not hovering, natural width).
    ///
    /// **This breaks a feedback loop, it is not an optimization** (measured 2026-09-08): the bar is
    /// horizontally centered
    /// (`PanelGeometry.dockTargetFrame`); once the make-room gap is inserted the content is one card wider ->
    /// panel relayout ->
    /// the whole bar recenters -> the drop zone moves out from under the **stationary** cursor ->
    /// `dropExited` -> gap and highlight cleared ->
    /// content narrows -> centers back -> `dropEntered` -> inserted again. Measured: 77 enter/exit rounds in
    /// one drag, period ≈33ms,
    /// showing as the plus badge, the bar edge and the gap all flickering together. Freeze the width ->
    /// `fittingSize` unchanged -> no relayout ->
    /// drop zone stays put -> loop broken. The card width the gap makes room for is absorbed by content
    /// overflow (clipped by the `ScrollView`),
    /// the same established approach as "window cards overflow during conversion instead of changing the
    /// panel width".
    @State var frozenStripWidth: CGFloat?

    /// "Drop-end watchdog" + "lighting gate" for the external drop highlight. SwiftUI file drops have two
    /// abnormal endings:
    /// ① after the last dropUpdated the drop gives no performDrop/dropExited ending callback -> the highlight
    /// is left on .pin;
    /// ② ~330ms after a successful drop a stray dropUpdated arrives and lights the highlight again.
    /// Gate: the highlight can only be lit by dropEntered (hoverActive); a stray dropUpdated after
    /// landing/exit is always ignored (fixes the ② re-flash).
    /// Watchdog: a cancellable .common Timer that clears the leftover highlight when hover updates stop for
    /// too long (fixes the ① permanent white edge); generation keeps old timers from clearing by mistake.
    /// Logic in externalDropHoverBegan/Moved/Ended + setExternalDropTarget.
    @State var externalDropWatchdog: Timer?
    @State var externalDropGeneration = 0
    @State var externalDropHoverActive = false

    /// Frame of the taskbar content area ("strip" space) in screen coordinates (bottom-left). Drawer drag
    /// back to taskbar, precise landing, uses it to map
    /// the global mouse position back to "strip" space to hit cards and to decide entering/leaving the
    /// taskbar area (hysteresis). Attached to the same view as the "strip" namespace.
    @State var stripRootScreenRect: CGRect = .zero

    /// Hover hit frames (`StripEntry.id` -> "strip"-space frame). **Yet another separate dictionary**, for
    /// the same reason as the three above:
    /// each has its own purpose (reorder / popup anchor / release decision) and none can stand in for
    /// another. This one is the only basis for "which card is the pointer on",
    /// so it **collects the cards of all four zones**, reported in one place by `stripEntryView`.
    @State var stripHoverFrames: [String: CGRect] = [:]

    /// Which card the pointer is on now. **The single hover truth for the whole bar**: hover visuals and the
    /// name bubble both read it.
    /// Cards no longer attach their own `.onHover`; cause and measurements in `StripHoverResolution`.
    @State var hoveredEntryID: String?

    /// Last pointer position (screen coordinates). **Deliberately kept in a reference box rather than a
    /// `@State` value**:
    /// writing `@State` on every pointer move would recompute the whole body at pointer frequency, while the
    /// only moment that really needs a recompute
    /// is when the owner changes, and that moment writes `hoveredEntryID` above.
    @State var pointerBox = PointerBox()

    /// The chip currently occupying the bubble panel. Only used to report the right id when dismissing the
    /// bubble (`.exit` only takes effect on a match).
    @State private var bubbleOwnerID: String?

    /// IDs of pinned-zone elements whose entrance animation has already played (avoids replays and lets newly
    /// added elements animate).
    @State private var animatedEntryIDs: Set<String> = []

    var body: some View {
        let projection = makeProjection()
        // "How many times one click recomputed the whole bar": `DockStripView` subscribes to the whole
        // `AppRuntime`,
        // so any `@Published` change invalidates the whole bar. Off by default, recorded only with
        // `DOCK_HOVER_TRACE=1`.
        let _ = HoverTrace.stripBody(items: projection.entries.count)
        return ZStack {
            // macOS 26 Liquid Glass is handled by the unified backplate; off by default, and older systems or
            // the switch being off still get the original frosted material.
            DockPanelBackdrop(theme: theme,
                              cornerRadius: taskbarCornerRadius,
                              usesLiquidGlass: usesLiquidGlass,
                              followsForkBarStyle: true)   // fork: Appearance > Bar

            // Glass thickness: above the material, below the content. **Off by default**, on only with
            // `DOCK_PANEL_THICKNESS=1`
            // (unaccepted effects are always opt-in, see DockEffectSwitches). In dark mode neither layer is
            // drawn,
            // and the whole layer stays out of the view tree, keeping dark mode frozen pixel for pixel.
            // Native glass has real edge treatment, so stacking this "fake thickness" on it is pointless;
            // never drawn in glass mode.
            if theme.drawsEffectiveThickness && !usesLiquidGlass {
                theme.panelThicknessLayer(cornerRadius: taskbarCornerRadius)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: fork.value.resolvedItemSpacing() * dockScale) {   // fork: was Style.chipSpacing
                    ForEach(projection.entries) { entry in
                        chipWithReorder(entry, projection: projection)
                            // fork: outside `chipWithReorder`, so the reported card frames (hover, drag and
                            // drop hit tests) stay exactly the card. Negative when the gap is narrower.
                            .padding(.leading, projection.sameAppFollowerIDs.contains(entry.id)
                                ? (fork.value.resolvedSameAppSpacing() - fork.value.resolvedItemSpacing()) * dockScale
                                : 0)
                            .transition(.scale(scale: 0.88).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, fork.value.resolvedEdgePadding() * dockScale)   // fork: was Style.chipContentInset
                .frame(height: metrics.panelHeight)
                .animation(renderedCollapsed != dragController.stripSlotCollapsed
                               ? .easeInOut(duration: DrawerAnimation.duration)          // close up / reopen: follow the panel
                               : .spring(response: 0.28, dampingFraction: 0.82),         // make room: the signed-off spring
                           value: projection.layoutKeys)
                // The width animation for labels growing or shrinking is on the box of `ChipView.titleLabel`
                // (`LabelBoxWidthDriver` changes the real
                // layout width per frame and neighbor cards reflow with it); this layer only tells the panel
                // to start following per frame, plus the start probe.
                // Start the panel in the same update (reason at `onLabelWidthChange`). The probe line stays:
                // compared with the timestamp of
                // `relayout` on the panel side, the difference is how far apart content and backplate start
                // (`DOCK_HOVER_TRACE=1`).
                .onChange(of: projection.labelTitleByChipID) { newTitles in
                    HoverTrace.action("labelChange", phase: "swiftui")
                    let titled = Set(projection.layoutKeys.filter { $0.form == .multi }.map(\.id))
                    var starting: [String: CGFloat] = [:]
                    for id in titled {
                        guard let new = newTitles[id], let old = renderedLabelTitles[id], new != old else { continue }
                        let from = ChipPillMetrics.labelWidth(title: old, scale: dockScale)
                        if from != ChipPillMetrics.labelWidth(title: new, scale: dockScale) { starting[id] = from }
                    }
                    renderedLabelTitles = newTitles
                    if !starting.isEmpty { onLabelWidthChange(starting) }
                }
                .onAppear { renderedLabelTitles = projection.labelTitleByChipID }
                .environment(\.labelBoxWidthTick, onLabelBoxWidthTick)
            }
            .clipShape(RoundedRectangle(cornerRadius: taskbarCornerRadius, style: .continuous))
            .compatLeadingScrollAnchor()
            .mask(alignment: .center) {
                HStack(spacing: 0) {
                    // fork: both were Style.edgeFadeWidth; the fade follows the edge padding.
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: fork.value.resolvedEdgeFadeWidth() * dockScale)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: fork.value.resolvedEdgeFadeWidth() * dockScale)
                }
            }
            .overlay(alignment: .topLeading) {
                WheelScrollInterceptorRepresentable()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Right-click on the taskbar backplate pops up the NitiaDock menu.
            //
            // **Must be attached as `.overlay`, not `.background`**: behind SwiftUI's ScrollView is a real
            // `NSScrollView` that catches hit testing itself, so a host placed below it never receives events
            // (measured: right-clicking the blank ends did nothing). Placing it on top is safe because
            // `shouldClaim` only claims
            // "blank ends + dividers" and returns nil everywhere else to pass through, so right-click on
            // chips / folders / the shelf
            // still gets their own menus. The range decision is in the pure `StripContextMenuZone` (the
            // narrow 8pt gaps between chips
            // are deliberately not claimed, reason at that type).
            //
            // Like background, overlay doesn't affect the parent's size. The taskbar width is measured via
            // `fittingSize`,
            // so never turn this into a ZStack sibling: that would widen the bar.
            .overlay(NativeMenuHost(
                popUpHandler: onRequestTaskbarMenu,
                shouldClaim: { taskbarMenuZoneClaims(atScreen: $0) }
            ))
        }
        // Whole-bar highlight when an external directory drag hovers the folder zone (pin landing): a
        // brighter ring stacked **on top of** the usual one,
        // no longer replacing the glass highlight (that was the cause of the "black ring", see
        // `DockPanelRimPlan`).
        .dockPanelRim(
            cornerRadius: taskbarCornerRadius,
            style: theme.panelRimStyle(highlighted: stripHighlighted),
            lineWidth: theme.panelRimLineWidth(highlighted: stripHighlighted),
            usesLiquidGlass: usesLiquidGlass,
            highlighted: stripHighlighted
        )
        .animation(.easeOut(duration: 0.15), value: stripHighlighted)
        // Freeze the bar width during an external drop hover (reason at `frozenStripWidth`). **Must come
        // before the
        // `.coordinateSpace(name: "strip")` layer below**: the coordinate-space view's width is then constant
        // for the whole hover,
        // `chipFrames` and the `onDrop` location stay same-source, and the attachment layer is untouched.
        // With `nil` no frame is applied at all: normally fully natural width, zero effect on non-drop paths.
        .frame(width: frozenStripWidth)
        // Once cross-panel, the dragged card is drawn by DragController's full-screen carrier panel (no
        // longer on the taskbar overlay:
        // the taskbar window is only 92pt tall and a self-drawn overlay would be clipped and couldn't float
        // out). Only the in-place hiding that "leaves an empty slot" stays here.
        .coordinateSpace(name: "strip")
        // External file drag-in (system drop destination): **must be attached on the same layer that defines
        // the "strip" coordinateSpace**:
        // the DropDelegate's location must be same-source with folderChipFrames/shelfFrame; attached after
        // .padding(shadowPadding)
        // the coordinates are off (settled in review). Routing is the pure function StripDropRouting.route;
        // landing in handleExternalDrop.
        .onDrop(of: [UTType.fileURL], delegate: StripFileDropDelegate(
            // With the shelf turned off pass nil directly: ShelfFramePreferenceKey.reduce deliberately
            // ignores .zero,
            // so the old frame isn't cleared, and going by the frame alone a drop at the old position would
            // still be misjudged as a stash.
            shelfFrame: settingsStore.showShelf ? shelfFrame : nil,
            trashFrame: settingsStore.showTrash ? trashFrame : nil,
            folderFrames: folderChipFrames,
            orderedPaths: pinnedFolderStore.folderPaths,
            // Chip spacing scales with the tier, and the "insert at the very front" slack must scale too,
            // otherwise it is relatively wider at small tiers and
            // eats the move-into area on the left half of the first folder.
            headSlack: StripDropRouting.defaultHeadSlack * dockScale,
            onHoverBegan: { externalDropHoverBegan($0) },
            onHoverMoved: { externalDropHoverMoved($0) },
            onHoverEnded: { isLanding in externalDropHoverEnded(isLanding: isLanding) },
            onCommit: { target, urls in handleExternalDrop(target, urls: urls) },
            onCommitApplications: { urls, location in
                handleExternalApplicationDrop(urls, atX: location.x)
            },
            onGhostMoved: { bundleID, location in
                updateExternalDropGhost(bundleID: bundleID, atX: location.x)
            },
            currentGhostIndex: { externalDropGhost?.insertIndex },
            currentFrozenWidth: { frozenStripWidth },
            currentStripRect: { stripRootScreenRect }
        ))
        // No cursor badge over the Trash. **Must be an `.overlay` directly after `.onDrop`**: AppKit
        // gives the drag to the topmost registered view, and `.background` here lands below SwiftUI's.
        .overlay(StripDropBadgeOverlay())
        // Same view as the "strip" namespace -> its screen frame is the "strip" space origin, used by drawer
        // drag-back for coordinate mapping + enter/leave decisions.
        // **Landing anchors must also be re-reported when the panel itself moves**: all anchors are converted
        // from this rect by `stripFrameToScreen`.
        // On release `teardown` clears `conversion` -> bar width unfreezes -> the whole bar recenters and the
        // message zone (at the far left)
        // shifts left over 0.22s; without this hook the flight home keeps heading for the position **before**
        // the panel moved.
        .background(ScreenRectReader { rect in
            guard rect != stripRootScreenRect else { return }
            stripRootScreenRect = rect
            refreshHoveredEntry(frames: stripHoverFrames, origin: rect)
            updateLandingAnchor()
        })
        // **One tracking area for the whole bar**: every pointer move reports screen coordinates, and which
        // card it is on is computed by the pure decision
        // `StripHoverResolution`. The old per-card `.onHover` missed cells and was direction-dependent;
        // cause and measurements in that type's comment.
        .background(StripPointerTracker { pointer in
            pointerBox.value = pointer
            refreshHoveredEntry(frames: stripHoverFrames, origin: stripRootScreenRect)
            HoverTrace.pointer(x: pointer?.x ?? -1, chip: hoveredEntryID)
        })
        // Force click (trackpad) / middle-click (mouse) -> content preview: local event monitor -> hit
        // reverse lookup (handleGesturePreview).
        .background(GestureMonitorInstaller(
            onGesture: { handleGesturePreview(atScreen: $0) },
            onMiddleClick: { forkHandleMiddleClick(atScreen: $0) }   // fork
        ))
        // The drop shadow lives in the window's 20pt transparent margin, in glass mode too. Drawing it on the
        // background window's
        // layer was tried, but that window's frame equals the backplate exactly, so a shadow outside the
        // window is clipped entirely.
        .dockShadow(theme.stripShadow)
        .padding(PanelCoordinator.shadowPadding)
        // Drawer icon dragged onto the taskbar: on entering the taskbar area it converts to window cards and
        // the block makes room live following the cursor (mirrors DrawerView's global mouse drive).
        // Message-zone reorder/release is also driven by the global mouse: a reorder moves the dragged chip
        // and SwiftUI cancels the original gesture,
        // so the chip's own .onChanged can't be relied on (same lesson as the drawer, 2026-06-22 / review
        // P1-4).
        // **`onReceive` rather than `onChange(of: globalLocation)`**: the latter needs that value to be
        // `@Published`,
        // which was the source of "moving the mouse invalidates the whole taskbar" (measured: 46 whole-bar
        // recomputes in a 1.2s drag).
        // `onReceive` still runs the closure but creates no dependency for this view: it only redraws when
        // the side effects below really change something.
        .onReceive(dragController.pointerMoves) { _ in
            updateStripPresence()                 // entering/leaving the bar: restore make-room / close up, claim handover; must be decided before the gate
            guard ownsActiveDrag else { return }   // the bar on another display is dragging: this bar writes nothing back
            updateDrawerToMessagingRelease(projection: projection)
            updateDrawerToStripConvert(projection: projection)
            updateStripBlockReorder(projection: projection)
            updateLiveReorder(projection: projection)
            updateMessagingReorder(messagingIDs: projection.messagingIDs)
            updateFolderReorder()
            syncConvertedCarrier(projection: projection)
            syncReleasedMessagingCarrier(projection: projection)
            updateFolderDragZone()
            updateLandingAnchor()
        }
        // Clicking the icon during the flight home = clicking this card (2026-08-19: clicking it before
        // landing did nothing).
        // Dispatched by entry, mirroring the tap of each `stripEntryContent` branch verbatim; uses the
        // projection **as of now**, not the drag-start one in the payload.
        .onReceive(dragController.carrierClicks) { payload in
            guard ownsActiveDrag else { return }
            performCarrierClick(payload, projection: freshProjection())
        }

        // At the moment of conversion the projection held by the closure above is still the **old** one (app
        // still in the drawer), so neither the representative card nor the make-room card can be computed.
        // Mouse drive alone would mean "cursor resting at the boundary = permanent double image". Recompute
        // whenever the store changes to fill in that frame.
        .onChange(of: projection.liveOrderIDs) { _ in
            guard ownsActiveDrag else { return }
            syncConvertedCarrier(projection: freshProjection())
        }
        // Same as above, message-zone side: at the moment of release the projection in hand doesn't have this
        // chip yet.
        .onChange(of: projection.messagingIDs) { _ in
            guard ownsActiveDrag else { return }
            syncReleasedMessagingCarrier(projection: freshProjection())
        }
        // Re-evaluate once when the hover suppression switch flips: clear the old hover when the card is
        // hidden at drag start; when the landing hold ends (pointer moved),
        // fill in hover from the current pointer position. **No longer re-evaluated when "the hand is
        // empty"**: that was the source of
        // the card growing right after coming to rest on landing (see `refreshHoveredEntry`).
        .onChange(of: dragController.stripSlotCollapsed) { renderedCollapsed = $0 }
        .onChange(of: dragController.hoverGate) { _ in
            refreshHoveredEntry(frames: stripHoverFrames, origin: stripRootScreenRect)
        }
        // The app of the dragged message chip disappears from the message zone mid-drag (quit / external
        // unmark / snapshot lost) -> cancel the drag so the empty slot doesn't get stuck.
        // The stash preview (messagingToDrawer) is not misjudged: after conversion the payload source is
        // already .drawer (review P2-5).
        .onChange(of: projection.messagingIDs) { ids in
            if let p = dragController.draggingPayload, p.source == .messaging, !ids.contains(p.bundleID) {
                dragController.cancelDrag()
            }
        }
        // Converge the remembered live order with the current snapshot (drop closed, append
        // new) as a side-effect, never during body eval. The `.onAppear` seed mirrors the old
        // `initial: true` so the very first render's reconcile (empty → current) is a no-op.
        // The **only** driver of the name bubble. Which card the pointer is on, where the anchor is and what
        // text to show are all derived in one place by `bubbleRequest`,
        // so anchor drift / app name changes / tier switches all follow automatically. The per-card
        // `.refresh` resend, along with the guard for "who may occupy this panel", is gone:
        // now only one party can send requests, so there is nothing to contend over.
        .onChange(of: bubbleRequest(projection: projection)) { request in
            if let request {
                onWindowTitleTooltipEvent(.update(request))
            } else if let previous = bubbleOwnerID {
                onWindowTitleTooltipEvent(.exit(chipID: previous))
            }
            bubbleOwnerID = request?.chipID
        }
        .onDisappear {
            if let previous = bubbleOwnerID { onWindowTitleTooltipEvent(.exit(chipID: previous)) }
            bubbleOwnerID = nil
        }
        .onChange(of: projection.liveOrderIDs) { _ in reconcileLiveOrder(freshProjection()) }
        .onChange(of: keptAppStore.bundleIDs) { _ in reconcileLiveOrder(freshProjection()) }
        .onChange(of: messagingStore.bundleIDs) { _ in reconcileLiveOrder(freshProjection()) }
        .onAppear { reconcileLiveOrder(projection) }
        // Re-report the landing anchor when card frames change. **`globalLocation` alone is not enough**:
        // after release the pointer produces no more events,
        // while the make-room spring is still running and the slot only settles 100–200ms later. Mid-flight
        // correction of the flight home relies on this.
        .onPreferenceChange(ChipFramePreferenceKey.self) { frames in
            chipFrames = frames
            updateLandingAnchor()
        }
        // On bar reorder / tier switch the pointer hasn't moved but the card under it has changed:
        // re-evaluate in the same place.
        .onPreferenceChange(StripHoverFramePreferenceKey.self) { frames in
            stripHoverFrames = frames
            refreshHoveredEntry(frames: frames, origin: stripRootScreenRect)
        }
        // The frames from these two are also input sources for the landing anchor (one each for the `.folder`
        // / `.messaging` payloads),
        // so changes must be re-reported, for the same reason as `ChipFramePreferenceKey` above.
        .onPreferenceChange(FolderChipFramePreferenceKey.self) { frames in
            folderChipFrames = frames
            updateLandingAnchor()
        }
        .onPreferenceChange(MessagingChipFramePreferenceKey.self) { frames in
            messagingChipFrames = frames
            updateLandingAnchor()
        }
        .onPreferenceChange(ShelfFramePreferenceKey.self) { shelfFrame = $0 }
        .onPreferenceChange(TrashFramePreferenceKey.self) { trashFrame = $0 }
        .onChange(of: pinnedFolderStore.folderPaths) { currentPaths in
            let validIDs = Set(["shelf", "trash"] + currentPaths.map { "folder-\($0)" })
            animatedEntryIDs.formIntersection(validIDs)
        }
        // Showing/hiding the shelf changes the landing geometry of the whole pinned zone: end any external
        // drop hover in progress at once, leaving no highlight.
        // The entrance animation set only drops the "shelf" id: clearing it all would replay the entrance of
        // every folder chip when the shelf is re-enabled.
        .onChange(of: settingsStore.showShelf) { visible in
            if !visible { animatedEntryIDs.remove("shelf") }
            externalDropHoverEnded(isLanding: false)
        }
        .onChange(of: settingsStore.showTrash) { visible in
            if !visible { animatedEntryIDs.remove("trash") }
            externalDropHoverEnded(isLanding: false)
        }
        // No .frame(maxWidth: .infinity) here: lets NSHostingView.fittingSize reflect
        // the natural content width so AppDelegate can read it for panel sizing.
    }

    /// Path of the folder chip being dragged (nil = none). While dragging it is hidden in place as an empty
    /// slot; the copy is drawn by the carrier panel.
    private var draggingFolderPath: String? {
        guard ownsActiveDrag else { return nil }
        if let p = dragController.hiddenSlotPayload, p.source == .folder { return p.id }
        return nil
    }

    /// Reorder within the folder zone: hits the full frame of other folder chips and lands by the left/right
    /// half of the landing point (mirrors the live zone's reorderTarget;
    /// hit-testing only checks folderChipFrames, never chipFrames).
    private func folderReorderTarget(at point: CGPoint, dragging path: String) {
        let draggedID = "folder-" + path
        guard let hit = folderChipFrames.first(where: { kv in
            kv.key != draggedID && kv.value.contains(point)
        }) else { return }
        let targetPath = String(hit.key.dropFirst("folder-".count))
        pinnedFolderStore.reorder(draggedPath: path, relativeTo: targetPath,
                                  after: point.x > hit.value.midX)
    }

    /// Right boundary of the pinned zone ("strip" local coordinates): the right edge of the rightmost of the
    /// shelf + all folder chips.
    /// The dragged chip's own position is unaffected by hiding (opacity doesn't change layout) and its frame
    /// is still reported, so it needn't be excluded.
    ///
    /// nil = the boundary can't be computed (first frame not measured, or the shelf is off and there are no
    /// folder frames yet). **Never treat nil as 0 or
    /// as "no pinned zone"**: when dragging a folder the pinned zone necessarily exists, and a missing
    /// boundary only means it hasn't been measured; judged as
    /// the window zone, a release in place would wrongly unpin it and open Finder. Callers that get nil
    /// simply install no geometry.
    private var folderZoneMaxX: CGFloat? {
        if let framesMaxX = folderChipFrames.values.map(\.maxX).max() { return framesMaxX }
        guard settingsStore.showShelf, shelfFrame != .zero else { return nil }
        return shelfFrame.maxX
    }

    /// Live landing classification while a folder chip is dragged, written into DragController for the
    /// carrier view (across SwiftUI trees) to read for its fade-out.
    /// The final landing reuses the same screen-coordinate geometry, committed by the mouseUp / polling
    /// fallback path of DragController.endDrag.
    private func updateFolderDragZone() {
        guard let p = dragController.draggingPayload, p.source == .folder,
              stripRootScreenRect != .zero,
              // No geometry while the boundary is unmeasured: for nil geometry DragController falls back to
              // .folderZone (no action in place),
              // which is the only safe default here.
              let folderZoneMaxX else {
            dragController.setFolderDragZone(nil)
            dragController.setFolderDropGeometry(nil)
            return
        }
        let geometry = FolderChipDropGeometry(stripScreenRect: stripRootScreenRect,
                                              folderZoneMaxX: folderZoneMaxX,
                                              trashMinX: settingsStore.showTrash && trashFrame != .zero ? trashFrame.minX : nil)
        dragController.setFolderDropGeometry(geometry)
        dragController.setFolderDragZone(geometry.classify(screenPoint: dragController.globalLocation))
    }

    /// Converge the remembered live order with the current snapshot (drop closed, append new).
    /// Called on every `liveOrderIDs` change **and** once on appear (the latter mirrors the old
    /// `onChange(of:initial:)` seed that pre-macOS-14 `onChange` doesn't provide).
    func reconcileLiveOrder(_ projection: StripProjection) {
        let current = projection.liveOrderIDs
        let appKeys = projection.appKeyByChipID
        // The diagnostic payload contains the whole appKey dictionary, so **don't build it when logging is
        // off** (same as AppTracker's isEnabled gate).
        let sample: InventoryOrderProjectionSample? = stripOrderStore.isInventoryLogEnabled
            ? InventoryOrderProjectionSample(
                currentLiveIDs: current,
                absorbedMessagingMainIDs: projection.messaging.compactMap { entry in
                    guard case let .messagingApp(_, mainWindow) = entry else { return nil }
                    return mainWindow?.id
                },
                visibleMessagingBundleIDs: projection.messaging.compactMap { entry in
                    guard case let .messagingApp(bundleID, _) = entry else { return nil }
                    return bundleID
                },
                drawerBundleIDs: drawerStore.bundleIDs,
                appKeyByChipID: appKeys
              )
            : nil
        if HoverTrace.isEnabled, let p = dragController.carriedPayload {
            HoverTrace.orderSync(count: current.count,
                                 carriedID: p.bundleID,
                                 hasCarried: current.contains("app-\(p.bundleID)"))
        }
        stripOrderStore.sync(current: current, appKeyOf: appKeys,
                             headPreferred: Set(messagingStore.bundleIDs),
                             projectionSample: sample)
        // The dragged window disappears mid-drag -> cancel the drag so the empty slot doesn't get stuck.
        // (Release without a callback is covered by DragController's polling fallback.)
        if let p = dragController.draggingPayload, p.source == .strip, !current.contains(p.id) {
            dragController.cancelDrag()
        }
    }

    /// Live-zone reorder during a drag: find the chip whose **full frame** the finger is over
    /// (excluding the dragged chip itself), and place the dragged chip on the half the finger is
    /// in. Drives the existing `stripLayoutKeys` spring so the others slide aside as the gap moves.
    /// Full-frame hit (not x only): when the finger moves up toward the capsule/drawer, y has already left
    /// the bar row, contains misses -> the order isn't changed by mistake (second review).
    private func reorderTarget(at point: CGPoint, dragging id: String, current: [String]) {
        guard let hit = chipFrames.first(where: { kv in
            kv.key != id && kv.value.contains(point)
        }) else { return }
        stripOrderStore.reorder(draggedID: id, relativeTo: hit.key,
                                after: point.x > hit.value.midX, current: current)
    }

    /// The **only** driver of live-zone (window card / kept placeholder) reorder: the pointer position, not
    /// the chip's own gesture
    /// (since 2026-08-19 the same rule as message zone / drawer / converted block). A drag re-grabbed during
    /// the flight home
    /// has no SwiftUI gesture (`DragController.regrabLanding`), so this is the only path that lets it reorder.
    /// No reorder while over a drop zone (capsule / drawer): when the finger moves up toward the capsule, y
    /// has already left the bar row,
    /// and `contains` won't hit either (both gates from item 4 of the second review are kept).
    private func updateLiveReorder(projection: StripProjection) {
        let dc = dragController
        guard let p = dc.draggingPayload, p.source == .strip, !dc.isOverDropZone,
              let pt = stripPoint(from: dc.globalLocation) else { return }
        reorderTarget(at: pt, dragging: p.id, current: projection.liveOrderIDs)
    }

    /// The only driver of reorder within the folder zone, same as above.
    private func updateFolderReorder() {
        let dc = dragController
        guard let p = dc.draggingPayload, p.source == .folder,
              let pt = stripPoint(from: dc.globalLocation) else { return }
        folderReorderTarget(at: pt, dragging: p.id)
    }

    // MARK: - Drawer icon dragged back to taskbar, precise landing (running apps, global mouse driven, mirrors DrawerView)

    /// Drawer drag-out mode (the decision is the pure function `DragConversionPlan.drawerDragOutMode`,
    /// covered by unit tests; this only feeds the current facts).
    private func currentDrawerDragOutMode(_ bid: String, projection: StripProjection) -> DrawerDragOutMode {
        DragConversionPlan.drawerDragOutMode(
            bundleID: bid,
            isMessagingMember: messagingStore.contains(bid),
            isInSnapshot: projection.snapshotBundleIDs.contains(bid),
            // Same source as message-zone visibility (NSWorkspace process projection), **not** the window
            // list; reason at `drawerDragOutMode`.
            isRunningProcess: runningApplicationStore.isRunning(bid),
            hasRealWindow: projection.hasRealWindow(bundleID: bid),
            isKept: keptAppStore.contains(bid)
        )
    }

    /// After conversion, syncs two **different** things, hence two values (reason for the split at
    /// `DragController.convertedChipID`):
    ///
    /// - `rep`: which card the carrier now draws. Must be a real window card; if there is none it stays nil
    ///   and the carrier keeps drawing the small drawer icon.
    /// - `chipID`: which card on the bar is hidden to leave an empty slot. **Includes `.keptApp` placeholders
    ///   and app-level fallback cards**:
    ///   the `keepPlacement` path materializes exactly these two, and missing them is the "two shadows"
    ///   reported 2026-08-18.
    ///
    /// Driven from both `onChange(globalLocation)` and `onChange(liveOrderIDs)`. The latter can't be dropped:
    /// conversion runs in the same closure as this, with the **previous frame's** projection (when the app
    /// was still in the drawer),
    /// so with mouse drive alone a cursor resting at the boundary would leave a permanent double image.
    func syncConvertedCarrier(projection: StripProjection) {
        let dc = dragController
        guard dc.isConvertedToStrip, let p = dc.draggingPayload, p.source == .drawer else { return }
        let rep = projection.liveChipIDs(bundleID: p.bundleID).first
            .flatMap { projection.liveOrderIDs.contains($0) ? projection.item(forID: $0) : nil }
        let chipID = projection.liveEntryIDs(bundleID: p.bundleID).first
        // **Change is detected by chip id, not by representative card**: the `keepPlacement` path
        // materializes a `.keptApp` placeholder or
        // an app-level fallback card, the representative card is always nil, and judged by it nothing ever
        // "changes", so that path carried a 0.7×
        // small drawer icon among 54pt cards the whole way and never became a card (2026-08-20).
        let changed = dc.convertedChipID != chipID
        dc.setConvertedRepresentative(rep, chipID: chipID)
        guard changed else { return }
        // The carrier switches to drawing the card on the bar (same as an in-bar drag); `chipID` back to nil
        // = rollback, pass nil so the carrier switches back to the drag-start image.
        let entry = chipID.flatMap { id in projection.entries.first { $0.id == id } }
        dc.setCarrierSnapshot(entry.flatMap { carrierSnapshot(for: $0, projection: projection) },
                              reanchor: true)
    }

    /// What a card clicked mid-flight should do: **exactly the same** as when clicked on the bar.
    /// Window card -> toggle that window; kept app / messaging app without a main window -> summon the main
    /// window if running, launch if not running, nothing while launching.
    /// Folder chips do nothing (the popup would anchor on a still-empty tile, the icon arrives half a second
    /// later); nothing if the entry isn't found (no longer on the bar).
    private func performCarrierClick(_ payload: DragPayload, projection: StripProjection) {
        guard let entryID = carriedStripEntryID(for: payload),
              let entry = projection.entries.first(where: { $0.id == entryID }) else { return }
        switch entry {
        case let .window(item):
            runtime.toggle(windowID: item.actionWindowID)
        case let .messagingApp(bid, main):
            if let main {
                runtime.toggle(windowID: main.actionWindowID)
            } else {
                launcherTap(bid, hasRealWindow: projection.hasRealWindow(bundleID: bid))
            }
        case let .keptApp(bid):
            launcherTap(bid, hasRealWindow: false)   // a kept placeholder only exists when there is no real window
        case .pinnedFolder, .shelf, .trash, .divider, .externalDropGhost:
            return   // the gap can't be dragged, so no in-flight payload can point at it
        }
    }

    /// Payload -> entry id of the card on the bar. `nil` = this payload doesn't belong to the taskbar (drawer
    /// icon / folder chip).
    /// **Shared by two places**: a mid-flight click must find it to act, and mid-flight hover must exempt it;
    /// both sides must use the same algorithm.
    /// Same as above, but first matches the card "converted into the taskbar". A converted payload's source
    /// **stays `.drawer`**
    /// (`convertDrawerToStrip` deliberately doesn't flip source), and the static version returns nil for
    /// `.drawer`,
    /// so on landing the hover exemption fails: the pointer is right on the card that just reappeared and
    /// quiet mode grows it to 1.10 on the spot,
    /// which is the previously fixed "landing jitter" in the form it takes on this path (2026-08-20).
    func carriedStripEntryID(for payload: DragPayload) -> String? {
        if payload.source == .drawer, let cid = dragController.convertedChipID { return cid }
        return Self.stripEntryID(for: payload)
    }

    static func stripEntryID(for payload: DragPayload) -> String? {
        switch payload.source {
        case .strip: return payload.id                       // window card = chip token; kept placeholder = "app-<bid>"
        case .messaging: return "msg-app-\(payload.bundleID)"
        case .drawer, .folder: return nil
        }
    }

    /// The two tap paths of `LauncherChip` on the bar (`onTap: reopen` / `onLaunch`), plus its own "nothing
    /// while launching" gate.
    private func launcherTap(_ bid: String, hasRealWindow: Bool) {
        guard !runtime.launchingBundleIDs.contains(bid) else { return }
        if runningApplicationStore.isRunning(bid) {
            Self.messagingFallbackTap(bundleID: bid, hasRealWindow: hasRealWindow)
        } else {
            _ = runtime.beginLaunch(bid)
        }
    }

    /// Which slot the floating copy should fly back to on release (screen coordinates). **Written on every
    /// cursor update, including nil**:
    /// the drawer side writes its own copy too, kept apart by the owner tag; without writing nil, after a
    /// drawer icon converts into the taskbar,
    /// the stale anchor left by the drawer would make the icon fly into the already closed drawer (see
    /// `DragController.setLandingAnchor`).
    ///
    /// In-bar reorder / message-zone reorder can give an exact landing: making room happens live during the
    /// drag, so at release
    /// this card's frame **is** its final slot. The converted-into-taskbar branch gives nil: release
    /// unfreezes the bar width,
    /// the whole bar recenters, and the landing would still drift mid-flight.
    private func updateLandingAnchor() {
        guard ownsActiveDrag else { return }
        let anchor: CGRect? = {
            // `carriedPayload`: keeps reporting mid-flight too, so `DragController` can correct course once
            // the slot settles.
            guard let p = dragController.carriedPayload, stripRootScreenRect != .zero else { return nil }
            // Converted into the taskbar: the anchor is the card on the bar (`convertedChipID` covers both
            // real window cards and
            // the `app-<bid>` placeholder materialized by `keepPlacement`; both report into `chipFrames`).
            // **Before 2026-08-20 this returned nil, so a drawer drag into the taskbar had no flight home at
            // all**, and the icon teleported from the cursor
            // to the slot. The reason then was "release unfreezes the bar width, the whole bar recenters, the
            // landing drifts mid-flight",
            // but that drift no longer exists: the bar width is no longer clamped (since close-up on
            // drag-out, the bar width follows the rendered content at all times).
            // Matches `convertedChipID` rather than `isConvertedToStrip`: the latter reads `conversion`,
            // and `conversion` is cleared in `teardown`, so mid-flight the anchor would be lost and course
            // couldn't be corrected.
            if let cid = dragController.convertedChipID {
                return chipFrames[cid].map(stripFrameToScreen)
            }
            switch p.source {
            case .strip:  return chipFrames[p.id].map(stripFrameToScreen)
            case .folder: return folderChipFrames[p.id].map(stripFrameToScreen)
            case .messaging: return messagingChipFrames[p.bundleID].map(stripFrameToScreen)
            case .drawer: return nil   // not converted yet -> the landing is in the drawer, written by the drawer side
            }
        }()
        dragController.setLandingAnchor(anchor, owner: .strip)
    }

    /// Captures one carrier bitmap. **It draws exactly what `stripEntryContent` draws**: rendering the slot
    /// and rendering the carrier are
    /// the same function with the same arguments, only "hover" and "entrance animation" passed as false. So
    /// "carrier matches slot"
    /// holds by construction, not through a hand-maintained mapping table (this repo has already let such
    /// tables slip twice:
    /// `ChipView.scale` silently rendering at the medium tier, and the message zone having no name bubble at
    /// all).
    ///
    /// Environment objects must be re-injected here: `ChipView` has five `@EnvironmentObject`s and crashes if
    /// one is missing.
    private func carrierSnapshot(for entry: StripEntry, projection: StripProjection) -> CarrierSnapshot? {
        ChipSnapshotter.snapshot(
            of: stripEntryContent(entry, projection: projection, hovered: false, entrance: false)
                .environmentObject(runtime)
                .environmentObject(drawerStore)
                .environmentObject(messagingStore)
                .environmentObject(keptAppStore)
                .environmentObject(runningApplicationStore)
                .environmentObject(appMembershipController)
                .environmentObject(settingsStore)
                .environmentObject(badgeStore)
                .environmentObject(pinnedFolderStore)
                .environmentObject(folderCoverStore),
            screenPoint: CGPoint(x: stripRootScreenRect.midX, y: stripRootScreenRect.midY)
        )
    }

    /// The slot's pose **right now**: hover scale-up (quiet mode bottom-anchored 1.10 / folder chip
    /// bottom-anchored 1.12) × press 0.93 (center).
    /// Only when the carrier's first frame is laid out by it does it overlap the slot pixel for pixel;
    /// derivation and values in `DragCarrierGeometry.pickUpPose`.
    /// The hover scale factor is computed with the **same**
    /// `ChipPillMetrics.quietHoverScale(forCardWidth:scale:)` that renders the card,
    /// with the measured frame width as card width (so the cap rule for wide titled cards matches).
    private func pickUpPose(for entry: StripEntry, slot: CGRect?) -> DragCarrierGeometry.PickUpPose {
        let hovered = hoveredEntryID == entry.id
        let height = slot?.height ?? ChipPillMetrics.chipHeight * dockScale
        switch entry {
        case .window, .messagingApp, .keptApp:
            let width = slot?.width ?? ChipPillMetrics.cardWidth * dockScale
            let hoverScale: CGFloat? = hoverStyle.showsQuietHoverFeedback(isHovering: hovered)
                ? ChipPillMetrics.quietHoverScale(forCardWidth: width, scale: dockScale)
                : nil
            return DragCarrierGeometry.pickUpPose(
                chipHeight: height,
                pressedScale: ChipPressSwitches.pressDownEnabled ? ChipPressDecision.pressedScale : nil,
                hoverScale: hoverScale)
        case .pinnedFolder:
            // Folder chips use the bottom-anchored 1.12 scale-up in both modes and have no press feedback
            // (Taskbar Size Tiers project rule).
            return DragCarrierGeometry.pickUpPose(chipHeight: height, pressedScale: nil,
                                                  hoverScale: hovered ? PinnedFolderChip.hoverScale : nil)
        case .shelf, .trash, .divider, .externalDropGhost:
            return .resting
        }
    }

    /// Prepares the candidate (bitmap + slot frame) for `DragController` at press-down. Not prepared if the
    /// frame isn't measured yet;
    /// drag start then falls back to the "stay over the card and wait two display frames" path.
    private func prepareDragCandidate(_ entry: StripEntry, id: String, slot: CGRect?,
                                      projection: StripProjection) {
        guard let slot, stripRootScreenRect != .zero else { return }
        dragController.prepareCandidate(payloadID: id,
                                        sourceScreenRect: stripFrameToScreen(slot),
                                        snapshot: carrierSnapshot(for: entry, projection: projection))
    }

    /// Screen coordinates (bottom-left) -> "strip"-space point (top-left, y-down).
    func stripPoint(from global: CGPoint) -> CGPoint? {
        guard stripRootScreenRect != .zero else { return nil }
        return CGPoint(x: global.x - stripRootScreenRect.minX,
                       y: stripRootScreenRect.maxY - global.y)
    }

    /// Landing of a whole drawer block: **x only, always yields an answer**. Criteria and rationale (and why
    /// a full-frame `contains` can't be used)
    /// are in the pure type `StripBlockLanding`. In short, the conversion box deliberately extends 16pt above
    /// the bar's top edge,
    /// where a full-frame hit always fails, so the first landing would degrade to the end 100% of the time.
    func blockTarget(atX x: CGFloat, excluding block: Set<String>) -> (id: String, after: Bool)? {
        StripBlockLanding.target(pointerX: x,
                                 frames: chipFrames.filter { !block.contains($0.key) })
    }

    /// A payload whose drag started on the bar (window card / placeholder / message chip / folder chip)
    /// enters or leaves this bar's box -> tell the controller:
    /// enter = restore make-room (`.strip` also hands over the claim; cross-display window drag ③④: the empty
    /// slot opens here, reorder lands here, the landing anchor is reported from here);
    /// clearly out = the empty slot closes up and the bar shortens (2026-09-03, matching the native Dock).
    /// Same box as drawer conversion
    /// (`StripPointerBox`). Runs before the ownership gate: handover and "leaving" must both be decidable by
    /// the bar that doesn't hold the claim.
    private func updateStripPresence() {
        let dc = dragController
        guard let p = dc.draggingPayload, p.source != .drawer, dc.conversion == nil,
              stripRootScreenRect != .zero else { return }
        // The claim in a cross-display window drag (③④) goes by **the display the pointer is on**, not the
        // bar's box (2026-09-03: dragged to display B it lands on
        // bar B, dragged to display A it lands on bar A; previously it only handed over once inside the other
        // bar's box, and a release on empty space of display B flew back to A).
        // The claim decides which bar opens the empty slot, who reports the landing anchor and whether
        // release moves the window; the box only governs the empty slot closing / reopening.
        if p.source == .strip, let displayUUID,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(dc.globalLocation) }),
           DisplayIdentity.uuidString(for: screen) == displayUUID {
            dc.claimStripSurface(stripSurfaceID, displayUUID: displayUUID)
        }
        let box = StripPointerBox.classify(pointer: dc.globalLocation, stripRect: stripRootScreenRect,
                                           rightReach: metrics.capsuleGap + metrics.capsuleWidth,
                                           profile: .stripPresence)
        if box.enter {
            dc.noteStripEntered(surfaceID: stripSurfaceID, displayUUID: displayUUID)
        } else if box.clearlyOut {
            dc.noteStripLeft(surfaceID: stripSurfaceID)
        }
    }

    /// Entering/leaving the taskbar area drives convert/revert (hysteresis against boundary jitter).
    /// unstash path: enter -> convertDrawerToStrip + stage the landing; leave -> cancelExternalBlock +
    /// revertDrawerToStrip.
    /// keepPlacement path: with no real window, lands using the existing app fallback / kept placeholder;
    /// never modifies kept.
    func updateDrawerToStripConvert(projection: StripProjection) {
        let dc = dragController
        guard let p = dc.draggingPayload, p.source == .drawer, p.canExternalDrop,
              stripRootScreenRect != .zero else { return }
        let bid = p.bundleID
        let g = dc.globalLocation
        let r = stripRootScreenRect
        // The reason the right tolerance extends to the capsule's outer edge is at `StripPointerBox` (for
        // drawer-sourced payloads the capsule has no other meaning:
        // their only drop zone is the taskbar panel, so merging it in doesn't conflict with stashing).
        let box = StripPointerBox.classify(pointer: g, stripRect: r,
                                           rightReach: metrics.capsuleGap + metrics.capsuleWidth,
                                           profile: .drawerConversion)
        let enter = box.enter, clearlyOut = box.clearlyOut
        if HoverTrace.isEnabled {
            HoverTrace.drawerToStrip(x: g.x, y: g.y, strip: r, enter: enter, clearlyOut: clearlyOut,
                                     mode: "\(currentDrawerDragOutMode(bid, projection: projection))",
                                     converted: dc.isConvertedToStrip)
        }
        if !dc.isConvertedToStrip {
            guard enter else { return }
            let mode = currentDrawerDragOutMode(bid, projection: projection)
            // reject stays in the drawer; releaseToMessaging is handled by updateDrawerToMessagingRelease by
            // message-zone range.
            guard mode == .unstash || mode == .keepPlacement else { return }
            // This group's window cards aren't in the live zone yet, so the hit target is searched among
            // **existing** cards only (an empty exclude set is enough).
            let target = stripPoint(from: g).flatMap { blockTarget(atX: $0.x, excluding: []) }
            dc.claimStripSurface(stripSurfaceID)   // the converting bar now has exclusive write-back until landing / conversion undo
            dc.convertDrawerToStrip()
            stripOrderStore.stageExternalBlock(bundleID: bid, relativeTo: target?.id, after: target?.after ?? false)
            HoverTrace.drawerToStripStage(bundleID: bid, target: target?.id, after: target?.after ?? false)
        } else if clearlyOut {
            stripOrderStore.cancelExternalBlock()
            dc.revertDrawerToStrip()
        }
    }

    // MARK: - Message-zone drag (in-zone reorder + release/rollback of drawer messaging apps, global mouse driven)

    /// bundleID of the message-zone chip being dragged (nil = none). After drag start it is hidden in place
    /// via opacity and the layout slot is kept
    /// (the empty slot is the landing feedback). During the stash preview the payload source flips to .drawer
    /// and this becomes nil automatically: the chip has left the zone by then.
    private var draggingMessagingBundleID: String? {
        guard ownsActiveDrag else { return nil }
        if let p = dragController.hiddenSlotPayload, p.source == .messaging { return p.bundleID }
        return nil
    }

    /// bundleIDs of the chips currently visible in the message zone (in-zone display order). Feeds reorder
    /// traversal + cleanup on disappearance mid-drag.
    /// Message-zone range ("strip" space): the union of existing message chip frames; when the zone is empty
    /// it degrades to a short segment at the bar head
    /// (after release the message zone materializes at the bar head). Used for the release decision of drawer
    /// messaging apps, not "left the drawer body" (review P1-3).
    private func messagingReleaseZone(messagingIDs: [String]) -> CGRect? {
        let frames = messagingIDs.compactMap { messagingChipFrames[$0] }
        if let first = frames.first {
            return frames.dropFirst().reduce(first) { $0.union($1) }
        }
        guard stripRootScreenRect != .zero else { return nil }
        return CGRect(x: 0, y: 0, width: 56, height: stripRootScreenRect.height)
    }

    /// Reorder within the message zone: hits other message chip frames (outset 6pt to cover the gaps between
    /// tiles), landing by left/right half.
    /// Traverses in in-zone display order and takes the leftmost (dict order is undefined, and adjacent
    /// frames overlap after the outset, same as the drawer). No reorder while over a drop zone
    /// (capsule/drawer).
    private func updateMessagingReorder(messagingIDs: [String]) {
        let dc = dragController
        guard let p = dc.draggingPayload, p.source == .messaging,
              !dc.isOverDropZone,
              let pt = stripPoint(from: dc.globalLocation) else { return }
        for bid in messagingIDs where bid != p.bundleID {
            guard let f = messagingChipFrames[bid], f.insetBy(dx: -6, dy: -6).contains(pt) else { continue }
            messagingStore.reorder(draggedID: p.bundleID, relativeTo: bid, after: pt.x > f.midX)
            return
        }
    }

    /// A **running messaging app** in the drawer dragged into the message-zone range -> temporarily released
    /// back to the message zone; leaving the range (or entering the capsule/drawer drop zone) ->
    /// rolled back into the drawer. Enter 8pt / leave 24pt hysteresis against boundary jitter. After release
    /// the payload source is .messaging and in-zone reorder takes over precise placement;
    /// release lands it (endDrag decision in DragConversionPlan.endAction). Desktop / folder zone / live zone
    /// never trigger a release.
    private func updateDrawerToMessagingRelease(projection: StripProjection) {
        let dc = dragController
        if dc.isReleasedToMessaging {
            guard let pt = stripPoint(from: dc.globalLocation),
                  let zone = messagingReleaseZone(messagingIDs: projection.messagingIDs),
                  zone.insetBy(dx: -24, dy: -24).contains(pt),
                  !dc.isOverDropZone else {
                dc.revertDrawerToMessaging()
                return
            }
            return
        }
        // This path used to have no log at all, so "dragging there does nothing" couldn't be diagnosed
        // (compare: the unstash path
        // logs `d2s` every tick, which found the cause in one go last round). Each guard logs where it stops.
        guard let p = dc.draggingPayload, p.source == .drawer, p.canExternalDrop else { return }
        // Logged for messaging members only: logging ordinary apps every tick would flood the log (they
        // should go through unstash anyway, which has `d2s`).
        let isMessagingMember = messagingStore.contains(p.bundleID)
        func trace(_ stop: String, pt: CGPoint? = nil, zone: CGRect? = nil,
                   fallback: Bool = false, mode: String = "-", inZone: Bool = false) {
            HoverTrace.drawerToMessaging(
                bid: p.bundleID, x: pt?.x ?? -1, y: pt?.y ?? -1, zone: zone,
                fallback: fallback, mode: mode,
                inSnapshot: projection.snapshotBundleIDs.contains(p.bundleID),
                running: runningApplicationStore.isRunning(p.bundleID),
                inZone: inZone, released: false, stop: stop)
        }
        guard !dc.isConvertedToStrip else {
            if isMessagingMember { trace("convertedToStrip") }
            return
        }
        let mode = currentDrawerDragOutMode(p.bundleID, projection: projection)
        guard mode == .releaseToMessaging else {
            if isMessagingMember { trace("mode", mode: "\(mode)") }
            return
        }
        guard let pt = stripPoint(from: dc.globalLocation) else { return trace("noStripRect", mode: "\(mode)") }
        let fallback = projection.messagingIDs.compactMap { messagingChipFrames[$0] }.isEmpty
        guard let zone = messagingReleaseZone(messagingIDs: projection.messagingIDs) else {
            return trace("noZone", pt: pt, mode: "\(mode)")
        }
        let inZone = zone.insetBy(dx: -8, dy: -8).contains(pt)
        guard inZone else {
            return trace("outsideZone", pt: pt, zone: zone, fallback: fallback, mode: "\(mode)")
        }
        HoverTrace.drawerToMessaging(
            bid: p.bundleID, x: pt.x, y: pt.y, zone: zone, fallback: fallback, mode: "\(mode)",
            inSnapshot: projection.snapshotBundleIDs.contains(p.bundleID),
            running: runningApplicationStore.isRunning(p.bundleID),
            inZone: true, released: true, stop: "ok")
        // After release into this bar's message zone, this bar has exclusive write-back until landing /
        // release undo (`revertDrawerToMessaging` lets go).
        // Same statement as in `updateDrawerToStripConvert`: under ③④ both strips run this, and without a
        // claim the other bar
        // would judge "released but not in zone" by its own message zone every tick -> undo, the two flipping
        // each other, with the release landing decided by subscription order.
        dc.claimStripSurface(stripSurfaceID)
        dc.convertDrawerToMessaging()
    }

    /// After release back to the message zone, switches the carrier from the small drawer icon to **the
    /// message-zone icon**, same as the convert-into-taskbar path.
    ///
    /// Symptom when this step is missing: a 30.8pt small drawer icon is carried the whole way, and at the
    /// release handoff a 44pt message-zone icon pops up on the bar
    /// with no transition in between: small to large abruptly, a harsh size change (2026-08-20, WeChat).
    ///
    /// **Can't switch in the same pass as `convertDrawerToMessaging()`**: at that moment the chip isn't
    /// materialized in the projection yet (the one in hand is the previous frame's),
    /// so like `syncConvertedCarrier` it is driven from two places (pointer + `messagingIDs` change).
    private func syncReleasedMessagingCarrier(projection: StripProjection) {
        let dc = dragController
        let entry: StripEntry? = {
            guard dc.isReleasedToMessaging, let p = dc.draggingPayload, p.source == .messaging else { return nil }
            return projection.messaging.first { $0.id == "msg-app-\(p.bundleID)" }
        }()
        guard entry?.id != carriedMessagingChipID else { return }
        carriedMessagingChipID = entry?.id
        // entry back to nil = rolled back into the drawer; pass nil so the carrier switches back to the
        // drag-start drawer image.
        dc.setCarrierSnapshot(entry.flatMap { carrierSnapshot(for: $0, projection: projection) },
                              reanchor: true)
    }

    /// Continuous whole-block reorder after conversion: acts only once this group's window cards are all in
    /// the live zone (materialized); the initial landing is done by the staging inside sync.
    /// The keepPlacement path has no window cards and reorders a single-element block with the placeholder id
    /// "app-\(bid)".
    private func updateStripBlockReorder(projection: StripProjection) {
        let dc = dragController
        guard dc.isConvertedToStrip, let p = dc.draggingPayload, p.source == .drawer else { return }
        let ids = projection.liveChipIDs(bundleID: p.bundleID)
        let blockIDs = ids.isEmpty ? ["app-\(p.bundleID)"] : ids
        guard !blockIDs.isEmpty, blockIDs.allSatisfy(projection.liveOrderIDs.contains) else {
            HoverTrace.stripBlockReorder(target: nil, after: false, why: "notMaterialized")
            return
        }
        guard let pt = stripPoint(from: dc.globalLocation) else {
            HoverTrace.stripBlockReorder(target: nil, after: false, why: "noStripRect")
            return
        }
        guard let target = blockTarget(atX: pt.x, excluding: Set(blockIDs)) else {
            HoverTrace.stripBlockReorder(target: nil, after: false, why: "liveZoneEmpty")
            return
        }
        HoverTrace.stripBlockReorder(target: target.id, after: target.after, why: "ok")
        stripOrderStore.reorderBlock(ids: blockIDs, relativeTo: target.id, after: target.after)
    }

    /// Wraps a chip with in-app drag-reorder for the **live zone only** (route A, self-drawn drag).
    /// Pinned messaging chips don't participate (no gesture -> can't land in that zone, drags stay within
    /// their zone).
    ///
    /// Native-Dock feel: while dragging, the in-place chip is hidden (`opacity 0`) so its slot
    /// becomes the landing **gap**; what you carry is the self-rendered `floatingDragCopy` (fully
    /// ours -> zero ghosting on release, unlike the old system `.onDrag` image that faded in place). Pointer
    /// over a
    /// target's left/right half → land left/right. A plain tap (< minimumDistance) still falls
    /// through to the chip's `onTapGesture`; right-click still opens the menu; horizontal scroll
    /// is wheel/trackpad so it never fights this click-drag.
    @ViewBuilder
    private func chipWithReorder(_ entry: StripEntry, projection: StripProjection) -> some View {
        switch entry {
        case let .window(item):
            stripEntryView(entry, projection: projection)
                .opacity(projection.draggingID == item.id ? 0 : 1)
                // Frame in the shared `"strip"` space via a **background** GeometryReader: doesn't
                // affect layout and doesn't steal clicks (an overlay with a hittable Color.clear
                // intercepts taps, the original slice-3 bug). Feeds both the floating copy's
                // position and the left/right-half landing decision.
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ChipFramePreferenceKey.self,
                                               value: [item.id: geo.frame(in: .named("strip"))])
                    }
                )
                // simultaneousGesture so the chip's own onTapGesture / contextMenu stay intact.
                // minimumDistance: 8 → a click never starts a drag (no misfire).
                // Drag start is handed to DragController (carrier panel + monitors own tracking / landing /
                // teardown throughout); this gesture only
                // **starts the drag once** (computes grabOffset, takes the starting point in screen
                // coordinates). Since 2026-08-19 in-bar reorder is also pointer-driven
                // (`updateLiveReorder`, same as message zone / drawer / converted block): a drag re-grabbed
                // during the flight home has no gesture.
                // onEnded is an idempotent fallback besides the monitor's mouseUp.
                // **Prepared at press-down** (`DragController.prepareCandidate`): at mouse-down this card's
                // bitmap is already
                // attached to the carrier layer to prewarm the texture, so the drag-start pass can "light up
                // + hide card" in one frame. Withdrawn if released without a drag.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                        .onChanged { _ in
                            prepareDragCandidate(entry, id: item.id, slot: chipFrames[item.id], projection: projection)
                        }
                        .onEnded { _ in dragController.clearCandidate(payloadID: item.id) }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .named("strip"))
                        .onChanged { value in
                            if dragController.draggingPayload == nil {
                                let slot = chipFrames[item.id]
                                let grab: CGSize = slot.map {
                                    CGSize(width: $0.midX - value.startLocation.x,
                                           height: $0.midY - value.startLocation.y)
                                } ?? .zero
                                let payload = DragPayload(source: .strip, id: item.id,
                                                          bundleID: item.bundleIdentifier ?? "",
                                                          item: item, visualKind: .stripChip,
                                                          canExternalDrop: DragController.canStash(item))
                                dragController.beginDrag(payload: payload, stripSurfaceID: stripSurfaceID,
                                                         startScreenLocation: NSEvent.mouseLocation,
                                                         grabOffset: grab,
                                                         sourceScreenRect: slot.map(stripFrameToScreen) ?? .zero,
                                                         pose: pickUpPose(for: entry, slot: slot),
                                                         snapshot: carrierSnapshot(for: entry, projection: projection))
                            }
                            // In-bar reorder is **not here**: `updateLiveReorder` (pointer-driven) does it
                            // for all cases;
                            // a drag re-grabbed during the flight home doesn't have this gesture (see
                            // `DragController.regrabLanding`).
                        }
                        .onEnded { _ in dragController.endDrag() }
                )
        case let .messagingApp(bid, _):
            // Message-zone chips are draggable: in-zone reorder + drag into the drawer to stash (2026-07-11).
            // Frames are reported into the **separate**
            // MessagingChipFramePreferenceKey (never mixed into chipFrames, same isolation reason as folder
            // chips).
            // The gesture **only starts the drag once**: a reorder moves this chip and SwiftUI then cancels
            // the gesture -> in-zone reorder is driven by
            // updateMessagingReorder() from the global mouse (same lesson as the drawer, review P1-4).
            stripEntryView(entry, projection: projection)
                .opacity(draggingMessagingBundleID == bid ? 0 : 1)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: MessagingChipFramePreferenceKey.self,
                                               value: [bid: geo.frame(in: .named("strip"))])
                    }
                )
                // **Prepared at press-down** (`DragController.prepareCandidate`): at mouse-down this card's
                // bitmap is already
                // attached to the carrier layer to prewarm the texture, so the drag-start pass can "light up
                // + hide card" in one frame. Withdrawn if released without a drag.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                        .onChanged { _ in
                            prepareDragCandidate(entry, id: bid, slot: messagingChipFrames[bid], projection: projection)
                        }
                        .onEnded { _ in dragController.clearCandidate(payloadID: bid) }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .named("strip"))
                        .onChanged { value in
                            guard dragController.draggingPayload == nil else { return }
                            let slot = messagingChipFrames[bid]
                            let grab: CGSize = slot.map {
                                CGSize(width: $0.midX - value.startLocation.x,
                                       height: $0.midY - value.startLocation.y)
                            } ?? .zero
                            let payload = DragPayload(source: .messaging, id: bid,
                                                      bundleID: bid, item: nil,
                                                      visualKind: .messagingIcon,
                                                      canExternalDrop: true)
                            dragController.beginDrag(payload: payload, stripSurfaceID: stripSurfaceID,
                                                     startScreenLocation: NSEvent.mouseLocation,
                                                     grabOffset: grab,
                                                     sourceScreenRect: slot.map(stripFrameToScreen) ?? .zero,
                                                     pose: pickUpPose(for: entry, slot: slot),
                                                     snapshot: carrierSnapshot(for: entry, projection: projection))
                        }
                        .onEnded { _ in dragController.endDrag() }
                )
        case let .keptApp(bid):
            // Kept-app placeholders are draggable: mirrors the .window card's drag reorder + can be dragged
            // into the drawer (canExternalDrop=true).
            let chipID = "app-\(bid)"
            stripEntryView(entry, projection: projection)
                .opacity(projection.draggingID == chipID ? 0 : 1)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ChipFramePreferenceKey.self,
                                               value: [chipID: geo.frame(in: .named("strip"))])
                    }
                )
                // **Prepared at press-down** (`DragController.prepareCandidate`): at mouse-down this card's
                // bitmap is already
                // attached to the carrier layer to prewarm the texture, so the drag-start pass can "light up
                // + hide card" in one frame. Withdrawn if released without a drag.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                        .onChanged { _ in
                            prepareDragCandidate(entry, id: chipID, slot: chipFrames[chipID], projection: projection)
                        }
                        .onEnded { _ in dragController.clearCandidate(payloadID: chipID) }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .named("strip"))
                        .onChanged { value in
                            if dragController.draggingPayload == nil {
                                let slot = chipFrames[chipID]
                                let grab: CGSize = slot.map {
                                    CGSize(width: $0.midX - value.startLocation.x,
                                           height: $0.midY - value.startLocation.y)
                                } ?? .zero
                                let payload = DragPayload(source: .strip, id: chipID,
                                                          bundleID: bid, item: nil,
                                                          visualKind: .keptAppIcon,
                                                          canExternalDrop: true)
                                dragController.beginDrag(payload: payload, stripSurfaceID: stripSurfaceID,
                                                         startScreenLocation: NSEvent.mouseLocation,
                                                         grabOffset: grab,
                                                         sourceScreenRect: slot.map(stripFrameToScreen) ?? .zero,
                                                         pose: pickUpPose(for: entry, slot: slot),
                                                         snapshot: carrierSnapshot(for: entry, projection: projection))
                            }
                            // In-bar reorder: see `updateLiveReorder` (pointer-driven, same as the .window
                            // branch).
                        }
                        .onEnded { _ in dragController.endDrag() }
                )
        case let .pinnedFolder(path):
            // Folder chips: in-zone drag reorder + drag out to remove + drag back to the window zone to open
            // (feedback of 2026-07-06 implemented).
            // Frames are reported into the **separate** FolderChipFramePreferenceKey (popup anchor + external
            // pin routing + this zone's reorder
            // hit-testing), never mixed into the chipFrames of live reorder (review P1). The gesture mirrors
            // the .window card: drag start is handed to
            // DragController (.folder source, isolated from strip/drawer stash semantics); in-zone reorder and
            // FolderChipDropGeometry are pointer-driven; the final remove/open is triggered by the fallback
            // teardown of DragController.endDrag.
            stripEntryView(entry, projection: projection)
                .opacity(draggingFolderPath == path ? 0 : 1)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: FolderChipFramePreferenceKey.self,
                                               value: [entry.id: geo.frame(in: .named("strip"))])
                    }
                )
                // **Prepared at press-down** (`DragController.prepareCandidate`): at mouse-down this card's
                // bitmap is already
                // attached to the carrier layer to prewarm the texture, so the drag-start pass can "light up
                // + hide card" in one frame. Withdrawn if released without a drag.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("strip"))
                        .onChanged { _ in
                            prepareDragCandidate(entry, id: path, slot: folderChipFrames[entry.id], projection: projection)
                        }
                        .onEnded { _ in dragController.clearCandidate(payloadID: path) }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .named("strip"))
                        .onChanged { value in
                            if dragController.draggingPayload == nil {
                                let slot = folderChipFrames[entry.id]
                                let grab: CGSize = slot.map {
                                    CGSize(width: $0.midX - value.startLocation.x,
                                           height: $0.midY - value.startLocation.y)
                                } ?? .zero
                                let payload = DragPayload(source: .folder, id: path,
                                                          bundleID: "", item: nil,
                                                          visualKind: .folderChip,
                                                          canExternalDrop: false)
                                dragController.beginDrag(payload: payload, stripSurfaceID: stripSurfaceID,
                                                         startScreenLocation: NSEvent.mouseLocation,
                                                         grabOffset: grab,
                                                         sourceScreenRect: slot.map(stripFrameToScreen) ?? .zero,
                                                         pose: pickUpPose(for: entry, slot: slot),
                                                         snapshot: carrierSnapshot(for: entry, projection: projection))
                            }
                            // In-zone reorder + landing classification are both pointer-driven
                            // (`updateFolderReorder` / `updateFolderDragZone`
                            // in `.onReceive(pointerMoves)`): a re-grabbed drag doesn't have this gesture.
                        }
                        .onEnded { _ in dragController.endDrag() }
                )
        case .shelf:
            // The shelf is fixed at the head position and can't be dragged. Its frame goes through the
            // separate ShelfFramePreferenceKey (review: no sentinel mixing).
            stripEntryView(entry, projection: projection)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ShelfFramePreferenceKey.self,
                                               value: geo.frame(in: .named("strip")))
                    }
                )
        case .trash:
            stripEntryView(entry, projection: projection)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: TrashFramePreferenceKey.self,
                                           value: geo.frame(in: .named("strip")))
                })
        case .divider:
            stripEntryView(entry, projection: projection)
        case .externalDropGhost:
            // Make-room gap: **deliberately bypasses `stripEntryView`**. That function is the only reporting
            // outlet for hover frames,
            // and the gap must not report a hover frame (no bubble), let alone `ChipFramePreferenceKey`:
            // `chipFrames` is the input of the landing decision `StripBlockLanding` itself, and a gap in
            // there would
            // anchor on itself: the computed landing points at the gap and jitters whenever the pointer
            // moves. It only takes up one card's width here.
            //
            // ⚠️ **The fill must be something that really draws, not `Color.clear`** (measured over five
            // rounds, 2026-09-08).
            // A fully transparent view doesn't take part in the `.onDrop` hit region, and `.contentShape`
            // can't rescue it: once the gap opens
            // under the cursor, the cursor falls into the hole -> `dropExited` -> gap cleared -> the card
            // returns under the cursor ->
            // `dropEntered`, an infinite loop at about 30 times/s, showing as the plus badge on the cursor
            // and the bar edge flickering together.
            // Quantified (enter/exit count in one drag): 77 -> `.contentShape` on the gap **69, no effect** ->
            // `.contentShape` on the layer carrying `onDrop` **56, no effect** -> switching to the almost
            // invisible
            // but really drawn color below **10**. `.contentShape` stays to pin the hit shape to the full
            // rectangle,
            // but it does nothing on its own; what works is "this view really draws something".
            Color.black.opacity(0.001)
                .frame(width: ChipPillMetrics.cardWidth * dockScale,
                       height: ChipPillMetrics.chipHeight * dockScale)
                .contentShape(Rectangle())
        }
    }

    /// Hover hit frames are reported here in **one place** (`StripHoverFramePreferenceKey`), so none of the
    /// four zones can be missed;
    /// the old `ChipView.onWindowTitleTooltipEvent` trap of "one call site omits it and it still compiles"
    /// can't recur on this path. Dividers report too: one occupies its 5pt, and with the pointer on it nobody
    /// owns the bubble,
    /// so a wide gap naturally "shows nothing" and the cards on either side don't contend across it.
    @ViewBuilder
    private func stripEntryView(_ entry: StripEntry, projection: StripProjection) -> some View {
        stripEntryContent(entry, projection: projection,
                          hovered: hoveredEntryID == entry.id, entrance: true)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: StripHoverFramePreferenceKey.self,
                                           value: [entry.id: geo.frame(in: .named("strip"))])
                }
            )
    }

    /// The single render funnel for the four zones. **Carrier bitmaps come from here too**
    /// (`carrierSnapshot(for:projection:)`),
    /// so "the carrier must draw the same view as the slot" holds by construction, with no separate mapping
    /// table to maintain.
    ///
    /// - Parameters:
    ///   - hovered: whether the pointer is on this card. This used to read `hoveredEntryID` here; it is now
    ///     passed in explicitly
    ///     so the snapshot path can pass `false` (the carrier isn't hit-testable and must draw the non-hover
    ///     state).
    ///   - entrance: whether to run the entrance animation (`stripEntrance`). **Snapshots must pass `false`**:
    ///     that modifier's `@State` starts at `opacity 0 / offset 8` and only flips on `onAppear`,
    ///     while the snapshot is taken synchronously, so it would capture a semi-transparent image 8pt too
    ///     high.
    @ViewBuilder
    private func stripEntryContent(_ entry: StripEntry, projection: StripProjection,
                                   hovered: Bool, entrance: Bool) -> some View {
        switch entry {
        case let .window(item):
            // Badges follow the app (2026-08-23): `badgesByBundleID` is already scoped by messaging app
            // identity;
            // this only picks "that app's leftmost card".
            let windowBadge: String? = item.bundleIdentifier.flatMap { bid in
                projection.badgeEntryIDByBundle[bid] == item.id ? badgeStore.badgesByBundleID[bid] : nil
            }
            ChipView(item: item,
                     labelTitle: projection.labelTitleByChipID[item.id] ?? item.title,
                     scale: dockScale,
                     hoverStyle: hoverStyle,
                     isHovered: hovered,
                     // Only app-* fallback cards (resident Finder / kept fallback) stand for the whole app;
                     // ordinary window cards don't list.
                     showsWindowListInMenu: item.isAppLevelFallback,
                     showRunningDot: true,
                     pulseNonce: chipPulseNonces[item.id] ?? 0,
                     badgeText: windowBadge,
                     slotHidden: projection.draggingID == item.id)
        case .divider:
            Rectangle()
                .fill(fork.plateInk(theme.zoneDivider).color)   // fork: white on a dark bar
                // The width is a hairline, always 1pt unscaled; only the height follows the tier.
                .frame(width: 1, height: Style.dividerHeight * dockScale)
                .padding(.horizontal, 2 * dockScale)
        case let .pinnedFolder(path):
            let index = 1 + (pinnedFolderStore.folderPaths.firstIndex(of: path) ?? 0)
            let delay = Double(min(index, 6)) * 0.018
            PinnedFolderChip(
                path: path,
                cover: folderCoverStore.covers[path],
                sortOrder: pinnedFolderStore.sortOrder(for: path),
                onTap: { folderPrimaryTap(path) },
                onPreview: { folderShowPreview(path) },
                onOpenInFinder: { openFolderInFinder(path) },
                onAddFolder: onAddFolder,
                onRemove: { pinnedFolderStore.remove(path) },
                onSetSortOrder: { pinnedFolderStore.setSortOrder($0, for: path) },
                isDropTarget: externalDropTarget == .moveInto(path: path),
                scale: dockScale,
                hoverStyle: hoverStyle,
                isHovered: hovered
            )
            .stripEntrance(id: entrance ? entry.id : nil, delay: delay,
                           animatedEntryIDs: $animatedEntryIDs)
        case .trash:
            trashChip(hovered: hovered)
                .stripEntrance(id: entrance ? entry.id : nil, delay: 0,
                               animatedEntryIDs: $animatedEntryIDs)
        case .shelf:
            ShelfChip(
                itemCount: shelfStore.itemPaths.count,
                isDropTargeted: externalDropTarget == .stash,
                scale: dockScale,
                hoverStyle: hoverStyle,
                isHovered: hovered,
                onTap: { shelfChipTapped() },
                onClear: { shelfStore.clear() },
                onAddFolder: onAddFolder
            )
            .stripEntrance(id: entrance ? entry.id : nil, delay: 0,
                           animatedEntryIDs: $animatedEntryIDs)
        case let .messagingApp(bid, main):
            // The unread badge is drawn by the chip itself (`badgeText:`), no longer stacked on here through
            // a wrapping ZStack.
            // Stacked outside, it sat **outside** the chip's scale: on hover scale-up / press shrink the red
            // dot did not move
            // (measured 2026-08-17: 16×15pt in both frames). See `ChipBadgeView`.
            let badge = badgeStore.badgesByBundleID[bid]
            Group {
                if let main {
                    // Running with a main window -> the app chip is the main-window card: standard toggle +
                    // full window menu. iconOnly keeps the message zone's
                    // fixed-width icon row; the running dot marks it as the app entry.
                    // The message-zone one is always `iconOnly` and shows no text, so the raw title is fine
                    // as the label (`.help` still uses `fullTitle`).
                    ChipView(item: main, labelTitle: main.title,
                             scale: dockScale, hoverStyle: hoverStyle,
                             isHovered: hovered,
                             // The message-zone icon always stands for the whole app (even with the main
                             // window open), so list all windows.
                             showsWindowListInMenu: true,
                             iconOnly: true, showRunningDot: true,
                             badgeText: badge,
                             slotHidden: draggingMessagingBundleID == bid)
                } else {
                    // Two states without a main window: running (window closed / resident) -> click reopens
                    // the main window; not running (no running dot under the icon) -> click launches.
                    // Under the unified model messaging apps also have the "Keep in Dock" checkbox (alongside
                    // "Unmark"), decided by the pure projection.
                    let running = runningApplicationStore.isRunning(bid)
                    LauncherChip(bundleID: bid,
                                 isRunning: running,
                                 isHidden: running && projection.hiddenBundleIDs.contains(bid),
                                 finderHasRealWindow: false,   // Finder can't enter the message zone

                                 isLaunching: runtime.launchingBundleIDs.contains(bid),
                                 scale: dockScale,
                                 hoverStyle: hoverStyle,
                                 hoverInput: .resolved(hovered),
                                 windowEntriesProvider: {
                                     WindowListMenuPlan.entries(
                                         snapshot: runtime.snapshot,
                                         bundleID: bid,
                                         fallbackTitle: AppDisplayNameResolver.displayName(for: bid)
                                     )
                                 },
                                 onActivateWindow: { runtime.activate(windowID: $0) },
                                 membershipItems: LauncherMembershipItem.items(
                                    surface: .strip,
                                    bundleID: bid,
                                    isKept: keptAppStore.contains(bid),
                                    isMessaging: true,
                                    controller: appMembershipController
                                 ),
                                 badgeText: badge,
                                 slotHidden: draggingMessagingBundleID == bid,
                                 onTap: running
                                    ? { Self.messagingFallbackTap(bundleID: bid,
                                                                  hasRealWindow: projection.hasRealWindow(bundleID: bid)) }
                                    : nil,
                                 onLaunch: { runtime.beginLaunch(bid) })
                }
            }
        case let .keptApp(bid):
            let isRunning = runningApplicationStore.isRunning(bid)
            let hasRealWindow = projection.hasRealWindow(bundleID: bid)
            let reopen: (() -> Void)? = isRunning && !hasRealWindow
                ? { Self.reopenMainWindow(bundleID: bid) }
                : nil
            LauncherChip(
                bundleID: bid,
                isRunning: isRunning,
                isHidden: runningApplicationStore.isHidden(bid),
                // fork: Finder reaches here only as the single icon of its windows on another display
                // (`ForkForeignWindowCollapse`); it has windows, so a click activates it, not opens home.
                finderHasRealWindow: projection.hasRealWindow(bundleID: bid),

                isLaunching: runtime.launchingBundleIDs.contains(bid),
                scale: dockScale,
                hoverStyle: hoverStyle,
                hoverInput: .resolved(hovered),
                windowEntriesProvider: {
                    WindowListMenuPlan.entries(
                        snapshot: runtime.snapshot,
                        bundleID: bid,
                        fallbackTitle: AppDisplayNameResolver.displayName(for: bid)
                    )
                },
                onActivateWindow: { runtime.activate(windowID: $0) },
                membershipItems: keptAppMembershipItems(bundleID: bid),
                forkSuppressRunningDot: projection.collapsedIconBundleIDs.contains(bid),   // fork
                badgeText: projection.badgeEntryIDByBundle[bid] == entry.id
                    ? badgeStore.badgesByBundleID[bid] : nil,
                slotHidden: projection.draggingID == "app-\(bid)",
                onTap: reopen,
                onLaunch: { runtime.beginLaunch(bid) }
            )
        case .externalDropGhost:
            // Unreachable: the gap branch of `chipWithReorder` bypasses `stripEntryView` (reason there),
            // and the carrier snapshot never captures something undraggable. Left empty to avoid adding a
            // `default` to this switch.
            EmptyView()
        }
    }

}

// MARK: - Visual Constants (hand-tune these)

private enum Style {
    // Shape: the corner radius shares one definition with the other 4 panels (this enum is private, other
    // files can't read it).
    static let cornerRadius: CGFloat   = DockShape.panelCornerRadius

    // Content layout
    static let chipContentInset: CGFloat = 20  // horizontal padding inside blur; > cornerRadius avoids corner-clip
    static let edgeFadeWidth: CGFloat    = 16  // scroll edge fade-out width (pt)
    // The real definition is `ChipPillMetrics.chipSpacing` (the bubble's neighborhood decision also needs the
    // center spacing, and this enum is
    // private, other files can't read it). Changing it requires changing
    // `StripContextMenuZone.defaultMinimumGapWidth` in step,
    // reason in the comment there.
    static let chipSpacing: CGFloat      = ChipPillMetrics.chipSpacing
    static let dividerHeight: CGFloat    = 20  // zone divider height (pt)

    // The stroke's "strong top, weak bottom" highlight is now officially handled by
    // DockThemeTokens.panelRimTop / panelRimBottom
    // (the two constants formerly here were unreferenced dead code; what was actually drawn was a uniform
    // white 0.15 ring).
}
