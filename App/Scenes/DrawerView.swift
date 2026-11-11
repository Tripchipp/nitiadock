import AppKit
import os
import SwiftUI

/// Drawer = **app view**: one icon per bundleID, order supplied by [[DrawerOrderStore]] and remembered
/// permanently (reworked 2026-06-21). The two zones are still split by "running or not":
/// - Running zone: apps placed in the drawer whose process is running (bright icon + dot). Click = app-level
///   show/hide (`LauncherChip.handleTap`).
/// - Launch zone: apps that are not running but have a permanent kept / messaging identity (dim icon, click
///   to launch).
///
/// DrawerStore records only placement; KeptAppStore decides whether an app stays visible after it quits.
/// Ordering always uses the full placement set, so hidden members return to their place on the next launch.
///
/// The two are **no longer fully orthogonal** (2026-08-06): landing a **drag in** also turns kept on.
/// Otherwise an ordinary app dragged into the drawer would vanish from it on quit, against the mental model
/// "in the drawer = I want it to stay there". **Dragging back to the taskbar** still never touches kept.
/// Conversion preview and rollback never touch kept either; it is written only at the moment `endDrag()`
/// lands. Criterion and full semantics: `DragConversionPlan.enablesKeptOnDrop`.
struct DrawerView: View {
    /// Max height of the drawer content area (anchor above the capsule -> usable top of the screen, computed
    /// by PanelCoordinator when it opens the drawer). Content beyond it scrolls internally and never fits by
    /// pushing the bottom edge down (prevents overlap with the capsule/taskbar below).
    let maxContentHeight: CGFloat
    /// Whether the backing uses native Liquid Glass. **Passed explicitly, no default** (like `scale` /
    /// `hoverStyle`): every panel is an independent hosting root view, and omitting it gives the plainly
    /// visible inconsistency of "this panel is glass, the one beside it is still frosted".
    let usesLiquidGlass: Bool
    /// Whether this drawer panel is open right now. **Passed explicitly, no default**: under ③④ each screen
    /// has its own drawer view, and a closed one keeps a stale `drawerRootScreenRect`. Without this check it
    /// would use the old position to judge a conversion in another screen's drawer as "dragged out" and
    /// revoke it: two views flip the conversion state back and forth and mutate `@Published` during layout,
    /// which crashed on a real machine on 2026-09-02. **Every callback in this view driven by the drag
    /// controller must check it first** (convert / revoke, reorder, landing anchor, clicks mid-flight): a
    /// closed drawer view lives until the next open, and without the check it writes stale positions into the
    /// shared controller. An icon dragged out of a secondary-screen drawer once flew to land in the main
    /// screen's drawer because of this (the second incident that day).
    let isDrawerOpen: () -> Bool
    /// Called after clicking an app icon performs "show" or "launch". Injected by PanelCoordinator to close
    /// the drawer. "Minimize (frontmost -> hide)" does not trigger it: the drawer stays open. Context menu
    /// and drag operations do not trigger it either.
    var onPrimaryAction: () -> Void = {}

    @EnvironmentObject var runtime: AppRuntime
    @EnvironmentObject var drawerStore: DrawerStore
    @EnvironmentObject var messagingStore: MessagingAppStore
    @EnvironmentObject var drawerOrderStore: DrawerOrderStore
    @EnvironmentObject var dragController: DragController
    @EnvironmentObject var keptAppStore: KeptAppStore
    @EnvironmentObject var runningApplicationStore: RunningApplicationStore
    @EnvironmentObject var appMembershipController: AppMembershipController

    private let theme = DockThemeTokens.standard

    /// Positions of drawer icons in the `"drawer"` coordinate space, feeding the drag-start grab offset and
    /// same-zone landing hit tests.
    @State private var drawerFrames: [String: CGRect] = [:]

    /// Screen frame of the drawer root view (bottom-left), for "is the cursor over the drawer body" and
    /// screen -> `"drawer"` space conversion.
    @State private var drawerRootScreenRect: CGRect = .zero

    /// Natural grid height (measured). Above maxContentHeight it scrolls internally.
    @State private var contentHeight: CGFloat = 0

    private let columns = Array(repeating: GridItem(.fixed(44 * 0.7), spacing: 8), count: 5)

    // MARK: - Members and zones (all at bundleID level)

    /// The full placement set feeds the ordering layer; never trim it to the currently visible items.
    private var allMembers: [String] {
        AppMembershipProjection.drawerMembers(drawerIDs: drawerStore.bundleIDs)
    }

    private var displayOrder: [String] { drawerOrderStore.reconciled(members: allMembers) }

    /// The single visibility funnel: running, or has a permanent kept / messaging identity. Input is in
    /// display order, so a hidden placement that reappears returns to its original relative position.
    private var visibleMembers: [String] {
        AppMembershipProjection.visibleDrawerIDs(
            drawerIDs: displayOrder,
            keptIDs: keptAppStore.bundleIDs,
            runningIDs: runningApplicationStore.runningBundleIDs
        )
    }

    /// Apps with a real window (used for the launch gate).
    private var windowBackedIDs: Set<String> {
        Set(StripItem.items(from: runtime.snapshot).filter { !$0.isAppLevelFallback }.compactMap(\.bundleIdentifier))
    }

    /// Window-appearance gate (2026-06-18): just launched, process up but no real window yet, counts as still
    /// launching -> stays in the launch zone and bounces.
    private func isLaunchingWithoutWindow(_ id: String) -> Bool {
        runtime.launchingBundleIDs.contains(id) && !windowBackedIDs.contains(id)
    }

    /// Only the Finder cell reads a real value: `windowBackedIDs` rescans the snapshot every time, and this
    /// value is used only by the Finder branch of `performDefaultTap`, so it is not worth paying for on every
    /// cell. A constant `false` for non-Finder is intentional.
    private func finderHasRealWindow(_ id: String) -> Bool {
        guard FinderTaskbarPolicy.isFinder(id) else { return false }
        return windowBackedIDs.contains(id)
    }

    /// Running state comes from RunningApplicationStore (the NSWorkspace process projection), the same
    /// criterion as the taskbar pinned dot.
    private func isRunning(_ id: String) -> Bool { runningApplicationStore.isRunning(id) }

    /// Hidden uses the same criterion: hidden only when every process of the bundle is hidden.
    private func isHiddenInSnapshot(_ id: String) -> Bool { runningApplicationStore.isHidden(id) }

    /// Running zone = in the drawer + running + not in the launch gate.
    private var runningZoneIDs: [String] {
        visibleMembers.filter { isRunning($0) && !isLaunchingWithoutWindow($0) }
    }

    /// Launch zone = visible items that are kept / messaging and not running (or still in the launch gate).
    private var launchZoneIDs: [String] {
        visibleMembers.filter { !isRunning($0) || isLaunchingWithoutWindow($0) }
    }

    // MARK: - Body

    var body: some View {
        // Bottom alignment: as the drawer panel grows upward, the content's bottom edge stays pinned to the
        // anchor (above the capsule) and only reveals upward, unlike top alignment, where the bottom edge
        // first drops below the anchor (pressing on the capsule) and then rises back (2026-06-21: lift
        // avoidance should expand straight up).
        ZStack(alignment: .bottomLeading) {
            DockPanelBackdrop(theme: theme,
                              cornerRadius: DockShape.panelCornerRadius,
                              usesLiquidGlass: usesLiquidGlass)

            // Content taller than the available height scrolls internally (capped, bottom edge not pushed
            // down); otherwise it hugs the content.
            Group {
                if contentHeight > maxContentHeight + 0.5 {
                    ScrollView(.vertical, showsIndicators: false) { gridStack }
                        .frame(height: maxContentHeight)
                } else {
                    gridStack
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DockShape.panelCornerRadius, style: .continuous))
        }
        .dockPanelRim(cornerRadius: DockShape.panelCornerRadius,
                      style: theme.panelRimStyle,
                      lineWidth: theme.panelRimLineWidth,
                      usesLiquidGlass: usesLiquidGlass)
        // Screen frame of the drawer root view (converted via AppKit, avoiding the .global / y-flip /
        // shadowPadding pitfalls; second review P1-3). Attached to the same view as the `"drawer"` namespace,
        // so it can both test "is the cursor in the drawer" and map screen coordinates back to drawer space
        // to hit cells. **When the drawer panel itself moves, the landing anchor must be re-reported too.**
        // On release `teardown` clears `conversion`, the taskbar width unfreezes and the whole bar recenters
        // narrower; the capsule is right-aligned to the taskbar and the drawer to the capsule, so **the whole
        // drawer panel slides left over 0.22s** while cell frames in `"drawer"` space do not move at all:
        // only this screen rect changes. Without this hook the return flight keeps heading for the position
        // from **before** the panel moved (to the right) and only on landing finds the cell is already to the
        // left, which is the reported "drifts to the right of the target first, then goes to the target". The
        // correction mechanism was built for exactly this; it just was not being fed here.
        .background(ScreenRectReader { rect in
            guard rect != drawerRootScreenRect else { return }
            drawerRootScreenRect = rect
            updateLandingAnchor()
        })
        .coordinateSpace(name: "drawer")
        // **Opening the drawer has no entrance animation** (2026-09-04: taskbar animation takes priority, the
        // drawer area may be reworked). The earlier "panel fade-in + content 0.96->1 scale + staggered card
        // reveal" recomputed the whole drawer from its pre-entrance state on every open, and the main-thread
        // stall landed at the start of the fade (still 22-40ms after view tree reuse), so the animation
        // itself caused the dropped frames. The shadow extent (radius+|y|) must be <=
        // shadowPadding(20), or the bottom is hard-clipped at the transparent edge (same as the popups).
        // Values are in DockThemeTokens.popupShadow (one set each for light/dark).
        .dockShadow(theme.popupShadow)
        .padding(PanelCoordinator.shadowPadding)
        // Re-report the landing anchor when cell frames change (same reason as the taskbar side: after
        // release the pointer sends no events while the grid is still reflowing).
        .onPreferenceChange(DrawerChipFramePreferenceKey.self) { frames in
            drawerFrames = frames
            updateLandingAnchor()
        }
        .onPreferenceChange(DrawerContentHeightKey.self) { contentHeight = $0 }
        // The dragged icon's app disappears from the members mid-drag (external removal etc.) -> cancel the
        // drag so the empty slot does not get stuck. Exception: conversion into the taskbar (drawer dragged
        // back to the taskbar, exact landing) removes it from the drawer **on purpose**; that is not an
        // abnormal disappearance and does not cancel.
        .onChange(of: visibleMembers) { members in
            if let p = dragController.draggingPayload, p.source == .drawer,
               !dragController.isConvertedToStrip, !members.contains(p.id) {
                dragController.cancelDrag()
            }
        }
        // A taskbar card dragged into the drawer follows the cursor to compute its running-zone landing; a
        // drag inside the drawer follows the cursor to reorder. Both are driven by the global mouse position
        // and do not publish inside body (onChange + dedup, second review P2-6). `onReceive` rather than
        // `onChange(of: globalLocation)`, for the same reason as `DockStripView`: once that value is
        // `@Published`, every mouse move invalidates and recomputes the whole panel.
        .onReceive(dragController.pointerMoves) { _ in
            updateStripDropPreview(); updateDrawerReorder(); updateLandingAnchor()
        }
        .onChange(of: dragController.draggingPayload?.id) { id in
            if id == nil { convertedCarrierID = nil }   // drag ended: the next time the same app comes in, the image must be swapped again
            // `onChange` runs inside SwiftUI's layout / commit pass, and changing `DragController`'s
            // `@Published` here (convert / revoke) makes AppKit throw in `_postWindowNeedsUpdateConstraints`
            // (2026-09-02 crash). Defer the check to the next run loop turn.
            DispatchQueue.main.async { updateStripDropPreview() }
        }
        // Clicking a drawer icon during the return flight = clicking that cell: run the cell's own default
        // left-click behavior (the same static logic).
        .onReceive(dragController.carrierClicks) { payload in
            // Only the open drawer view dispatches (one view per screen; if all dispatched, a running app
            // would show / hide twice = net zero).
            guard isDrawerOpen(), payload.source == .drawer, !runtime.launchingBundleIDs.contains(payload.id) else { return }
            LauncherChip.performDefaultTap(
                bundleID: payload.id,
                isRunning: isRunning(payload.id),
                finderHasRealWindow: finderHasRealWindow(payload.id),
                launch: { if runtime.beginLaunch(payload.id) { onPrimaryAction() } },
                onOpen: onPrimaryAction)
        }
    }

    /// The two-zone grid itself. `.background` measures the natural height for the scroll decision; each zone
    /// animates by its own ID list, so add/remove, wrapping and reorder are all smooth. A taskbar card
    /// dragged into the drawer is "converted to a member immediately" (see updateStripDropPreview), which is
    /// just one more id in the running zone, no placeholder cell needed.
    private var gridStack: some View {
        let runningIDs = runningZoneIDs
        let launchIDs = launchZoneIDs
        let hasRunningZone = !runningIDs.isEmpty
        return VStack(alignment: .leading, spacing: 0) {
            if runningIDs.isEmpty && launchIDs.isEmpty {
                emptyHint
            }
            if hasRunningZone {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(runningIDs.enumerated()), id: \.element) { index, id in 
                        drawerChip(id, index: index, zone: runningIDs, running: true) 
                    }
                }
                .animation(.easeInOut(duration: DrawerAnimation.duration), value: runningIDs)
            }
            if !launchIDs.isEmpty {
                if hasRunningZone {
                    Spacer().frame(height: 12)
                }
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(launchIDs.enumerated()), id: \.element) { index, id in 
                        drawerChip(id, index: index, zone: launchIDs, running: false) 
                    }
                }
                .animation(.easeInOut(duration: DrawerAnimation.duration), value: launchIDs)
            }
        }
        .padding(12)
        .background(GeometryReader { g in
            Color.clear.preference(key: DrawerContentHeightKey.self, value: g.size.height)
        })
    }

    /// Empty-drawer hint. Without it both zones are empty -> the `VStack` has zero children -> the content is
    /// only the 12pt padding, and the panel shrinks to a 24×24 frosted square: its purpose is unreadable and
    /// it is nearly unusable as a drop target.
    ///
    /// The width is hardcoded to 186pt = **the width of a full 5-column grid row** (`5 × 44×0.7 + 4 × 8`), so
    /// the first time an app is dragged in and the hint is replaced by the grid, the panel width does not
    /// jump. Colors must come from tokens (one set each for light/dark), never a literal opacity.
    ///
    /// No special case is needed during drag preview: as soon as a taskbar card enters the drawer body,
    /// `convertStripToDrawer` makes it a real member, `runningZoneIDs` becomes non-empty at once and the hint
    /// gives way to the grid.
    private var emptyHint: some View {
        Text("Drag apps here")
            .font(.system(size: 11))
            .foregroundStyle(theme.effectiveLabelInactive.color)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 5 * 44 * 0.7 + 4 * 8)
            .padding(.vertical, 10)
    }

    // MARK: - Single icon (with drag)

    /// `carriedPayload` rather than `draggingPayload`: after release there is still a return flight, and the
    /// cell must stay empty during it, otherwise the icon appears in the cell while the carrier is still
    /// flying toward it.
    private func isDragging(_ id: String) -> Bool {
        guard let p = dragController.hiddenSlotPayload else { return false }
        return p.source == .drawer && p.id == id
    }

    /// Which drawer cell (screen coordinates) the floating copy flies back to on release. The taskbar side
    /// writes its own copy too; the owner tag keeps them apart. A taskbar card stowed into the drawer (source
    /// already flipped to `.drawer`) also goes through here: the icon flies straight into the cell it landed
    /// in.
    private func updateLandingAnchor() {
        guard isDrawerOpen() else { return }   // a closed drawer neither reports an anchor nor clears the one the open drawer reported
        let anchor: CGRect? = {
            // `carriedPayload`: keep reporting mid-flight, so the offset can be corrected once the grid
            // reflow settles.
            guard let p = dragController.carriedPayload, p.source == .drawer,
                  !dragController.isConvertedToStrip,
                  drawerRootScreenRect != .zero,
                  let frame = drawerFrames[p.id] else { return nil }
            return drawerFrameToScreen(frame)
        }()
        dragController.setLandingAnchor(anchor, owner: .drawer)
    }

    private func membershipItems(for id: String) -> [LauncherMembershipItem] {
        LauncherMembershipItem.items(
            surface: .drawer,
            bundleID: id,
            isKept: keptAppStore.contains(id),
            isMessaging: messagingStore.contains(id),
            controller: appMembershipController
        )
    }

    /// `running` is passed per **zone** (running zone true / launch zone false), so appearance, click and
    /// menu all follow the zone currently shown. A launched process stays in the launch zone until a real
    /// window appears; the runtime's launch session drives the bounce directly. **What is drawn** in a drawer
    /// cell. The only reason it is split out: the carrier bitmap is produced from here (`ChipSnapshotter`),
    /// and rendering the cell and rendering the carrier must be the same code with the same parameters. The
    /// outer entrance animation / opacity set to 0 while dragging / gestures must not enter the snapshot, so
    /// they stay in `drawerChip`.
    private func drawerChipContent(_ id: String, running: Bool) -> some View {
        LauncherChip(bundleID: id,
                     isRunning: running,
                     isHidden: running ? isHiddenInSnapshot(id) : false,
                     finderHasRealWindow: finderHasRealWindow(id),
                     isLaunching: runtime.launchingBundleIDs.contains(id),
                     scale: 0.7,
                     // The drawer is intentionally unaffected by the "hover effect" setting (2026-08-02), but
                     // is **fixed to the quiet style** (2026-08-17 request: drawer icons scale up slightly on
                     // hover).
                     //
                     // `.standard` was originally used for "show the name on hover"; that reason went away on
                     // 2026-08-16: the name moved into the bubble above the icon, and this drawer call site
                     // **never wired the bubble callback**, so `.standard` here meant "do nothing" and drawer
                     // hover had zero feedback. `.quiet` is exactly the "no name, so give a slight scale-up"
                     // style, so the semantics match. The grid has 30.8pt cells with 8pt spacing; at 1.10
                     // each side grows only 1.5pt and cannot hit a neighbor.
                     hoverStyle: .quiet,
                     // The drawer panel has no bar-wide tracking area like the taskbar; each icon attaches
                     // its own `.onHover`. Cells are 30.8pt and the pointer stays inside far longer than a
                     // sweep across the bar, so missed cells are not a problem.
                     hoverInput: .selfTracked,
                     // Window blocks of drawer apps are hidden outside the taskbar entirely; this list is the
                     // only way to get them back. Clicking a window row does not trigger onPrimaryAction: the
                     // drawer stays open (same rule as the context menu "Open").
                     windowEntriesProvider: {
                         WindowListMenuPlan.entries(
                             snapshot: runtime.snapshot,
                             bundleID: id,
                             fallbackTitle: AppDisplayNameResolver.displayName(for: id)
                         )
                     },
                     onActivateWindow: { runtime.activate(windowID: $0) },
                     membershipItems: membershipItems(for: id),
                     slotHidden: isDragging(id),
                     hoverSuppressed: isHoverSuppressed(id),
                     onLaunch: { runtime.beginLaunch(id) },
                     onPrimaryAction: onPrimaryAction)
    }

    /// Whether this cell's hover feedback should be held: it is being carried (`.onHover` is still true while
    /// transparent), or it just landed and the pointer has not moved yet (`DragController.hoverHoldPayload`).
    /// The taskbar suppresses this at the source in its bar-wide tracking area; the drawer's `LauncherChip`s
    /// each attach `.onHover`, so it can only be suppressed per cell here.
    private func isHoverSuppressed(_ id: String) -> Bool {
        if let p = dragController.hoverHoldPayload, p.source == .drawer, p.id == id { return true }
        return isDragging(id)
    }

    /// A drawer cell's pose at drag start: the drawer is always the quiet style and the pointer is always on
    /// the cell (mouse-down happened on it), so it is the 1.10 bottom-anchored scale × 0.93 press, unless
    /// hover is being held. The factor comes from the same function that renders the cell.
    private func pickUpPose(for id: String, slot: CGRect?) -> DragCarrierGeometry.PickUpPose {
        let height = slot?.height ?? ChipPillMetrics.chipHeight * 0.7
        let width = slot?.width ?? ChipPillMetrics.cardWidth * 0.7
        let hoverScale: CGFloat? = isHoverSuppressed(id)
            ? nil
            : ChipPillMetrics.quietHoverScale(forCardWidth: width, scale: 0.7)
        return DragCarrierGeometry.pickUpPose(
            chipHeight: height,
            pressedScale: ChipPressSwitches.pressDownEnabled ? ChipPressDecision.pressedScale : nil,
            hoverScale: hoverScale)
    }

    /// Cell frame in screen coordinates; nil while the drawer root frame is not yet measured (drag start then
    /// falls back to "place under the pointer").
    private func slotScreenRect(_ id: String) -> CGRect? {
        guard drawerRootScreenRect != .zero, let slot = drawerFrames[id] else { return nil }
        return drawerFrameToScreen(slot)
    }

    /// Which drawer cell the floating copy flies back to on release / which cell the carrier takes over from
    /// at drag start: `"drawer"` space frame -> screen coordinates.
    private func drawerFrameToScreen(_ frame: CGRect) -> CGRect {
        CGRect(x: drawerRootScreenRect.minX + frame.minX,
               y: drawerRootScreenRect.maxY - frame.maxY,
               width: frame.width, height: frame.height)
    }

    @ViewBuilder
    private func drawerChip(_ id: String, index: Int, zone: [String], running: Bool) -> some View {
        drawerChipContent(id, running: running)
            .opacity(isDragging(id) ? 0 : 1)
            // Frame in `"drawer"` space, from a background GeometryReader (does not steal clicks), feeding
            // the grab offset and same-zone landing.
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: DrawerChipFramePreferenceKey.self,
                                           value: [id: geo.frame(in: .named("drawer"))])
                }
            )
            // This gesture **only starts the drag, once**: after getting "which card + grab offset" it hands
            // off to DragController. Reordering is **not done here**: the first reorder moves the dragged
            // icon within the grid, SwiftUI then cancels this gesture and onChanged stops firing -> "nudges
            // once, then stuck" (2026-06-22). Reordering is driven by updateDrawerReorder() from
            // DragController's global mouse position (see onChange(globalLocation)), unaffected by how icons
            // swap places. **Prepare on press** (`DragController.prepareCandidate`): at mouse-down this
            // cell's bitmap is attached to the carrier layer to prewarm the texture, so the drag-start turn
            // can "light up + hide the cell" in the same frame. Released without a drag, it is removed.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("drawer"))
                    .onChanged { _ in
                        guard let rect = slotScreenRect(id) else { return }
                        dragController.prepareCandidate(
                            payloadID: id,
                            sourceScreenRect: rect,
                            snapshot: ChipSnapshotter.snapshot(of: drawerChipContent(id, running: running),
                                                             screenPoint: CGPoint(x: drawerRootScreenRect.midX, y: drawerRootScreenRect.midY)))
                    }
                    .onEnded { _ in dragController.clearCandidate(payloadID: id) }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .named("drawer"))
                    .onChanged { value in
                        guard dragController.draggingPayload == nil else { return }
                        let slot = drawerFrames[id]
                        let grab: CGSize = slot.map {
                            CGSize(width: $0.midX - value.startLocation.x,
                                   height: $0.midY - value.startLocation.y)
                        } ?? .zero
                        let payload = DragPayload(source: .drawer, id: id, bundleID: id, item: nil,
                                                  visualKind: .drawerIcon, canExternalDrop: true)
                        dragController.beginDrag(
                            payload: payload,
                            startScreenLocation: NSEvent.mouseLocation,
                            grabOffset: grab,
                            sourceScreenRect: slotScreenRect(id) ?? .zero,
                            pose: pickUpPose(for: id, slot: slot),
                            snapshot: ChipSnapshotter.snapshot(of: drawerChipContent(id, running: running),
                                                             screenPoint: CGPoint(x: drawerRootScreenRect.midX, y: drawerRootScreenRect.midY)))
                    }
                    // Release fallback, aligned with the in-bar side: normally teardown relies on
                    // DragController's global monitor + polling; this is the second path for when the monitor
                    // misses mouseUp (in-bar drags always had it, the drawer side did not).
                    .onEnded { _ in dragController.endDrag() }
            )
    }

    /// Reorder inside the drawer: driven by DragController's global mouse position (replaces the per-icon
    /// gesture that gets cancelled). Maps screen coordinates back to `"drawer"` space and makes room after
    /// hitting a same-zone target. Reordering inside the drawer does not change the member count -> the
    /// drawer does not resize -> mapping with the live drawerRootScreenRect is enough.
    private func updateDrawerReorder() {
        guard isDrawerOpen(), let p = dragController.draggingPayload, p.source == .drawer,
              !dragController.isOverDropZone,            // cursor already over the taskbar = moving back, no reorder
              drawerRootScreenRect != .zero else { return }
        let pt = CGPoint(x: dragController.globalLocation.x - drawerRootScreenRect.minX,
                         y: drawerRootScreenRect.maxY - dragController.globalLocation.y)   // screen (bottom-left) -> drawer (top-left)
        let zone = runningZoneIDs.contains(p.id) ? runningZoneIDs : launchZoneIDs
        reorderTarget(at: pt, dragging: p.id, zone: zone)
    }

    /// Ordering inside the drawer: landing hits only within **the same zone** (second review ⑤: a cross-zone
    /// reorder would change order "silently" and only show once the state changes).
    private func reorderTarget(at point: CGPoint, dragging id: String, zone: [String]) {
        // Hit frames are expanded by a margin (covering the 8pt gap between cells) -> a larger, easier target
        // (2026-06-21 feedback: too small). Iterate in zone order: dict.first(where:) has no defined order,
        // and expanded neighbors overlap -> must take the leftmost in order.
        for tid in zone where tid != id {
            guard let f = drawerFrames[tid], f.insetBy(dx: -6, dy: -6).contains(point) else { continue }
            drawerOrderStore.reorder(draggedID: id, relativeTo: tid, after: point.x > f.midX)
            return
        }
    }

    // MARK: - Taskbar card enters the drawer body -> convert to in-drawer drag / restore on drag out

    /// A taskbar card dragged into the **open drawer body** -> converted to an in-drawer drag immediately
    /// (DragController.convertStripToDrawer: joins the drawer members, source becomes `.drawer`). From then
    /// on the card is an ordinary drawer member reordered by the global-mouse-driven `updateDrawerReorder`,
    /// **exactly the same path** as an in-drawer drag (2026-06-22: one unified feel). This bypasses the old
    /// "placeholder cell + repeated panel resize" mechanism entirely (the source of flicker/stutter).
    /// Bottom/side edges get a tolerance: the carrier has a grab offset from the mouse, which often sits near
    /// the drawer's bottom edge, and the tolerance keeps "entered the drawer body" stable at the edge.
    private func updateStripDropPreview() {
        let dc = dragController
        // Only an **open** drawer may convert / revoke (see `isDrawerOpen`).
        guard dc.draggingPayload != nil, drawerRootScreenRect != .zero, isDrawerOpen() else { return }
        let g = dc.globalLocation
        let r = drawerRootScreenRect
        // The enter threshold is loose (large tolerance, easy to enter); the revoke threshold sits further
        // out (hysteresis band, prevents convert/revoke flapping at the edge -> the drawer jittering in and
        // out).
        let enterBody = g.x >= r.minX - 8  && g.x <= r.maxX + 8  && g.y >= r.minY - 28
        let clearlyOut = g.x < r.minX - 20 || g.x > r.maxX + 20 || g.y < r.minY - 48
        if let p = dc.draggingPayload, p.canExternalDrop, enterBody {
            switch p.source {
            case .strip:     dc.convertStripToDrawer()      // enters the drawer body -> temporary conversion (pushing others aside = preview)
            case .messaging: dc.convertMessagingToDrawer()  // messaging chip gets the same stow preview feel
            case .drawer, .folder: break
            }
            syncConvertedCarrier()
        } else if clearlyOut {
            if dc.isConvertedFromStrip {
                dc.revertStripFromDrawer()          // dragged out of the drawer body -> revoke and restore (drawer shrinks back to its initial state)
            } else if dc.isConvertedFromMessaging {
                dc.revertMessagingFromDrawer()      // messaging chip dragged out -> restored to its place in the messaging zone
            }
            syncConvertedCarrier()
        }
    }

    /// As soon as a taskbar card / messaging chip enters the drawer body, the carrier switches to **the
    /// drawer cell's bitmap** (same as `drawerChipContent`, 0.7×, no badge) and the grab point is re-anchored
    /// to the pointer in proportion to the size; dragging out of the drawer body restores the drag-start
    /// image. The opposite direction (drawer icon converting into the taskbar) has long swapped the image
    /// (`DockStripView.syncConvertedCarrier`); this direction was missed: the carrier stayed a 40pt icon or
    /// even a 168pt title card, sitting over the drawer edge (2026-08-19 screenshot). It is pixel-identical
    /// only on the frame it lands in the cell: the bitmap must come from the same code that renders the cell.
    @State private var convertedCarrierID: String?
    private func syncConvertedCarrier() {
        let dc = dragController
        let converted = dc.isConvertedFromStrip || dc.isConvertedFromMessaging
        if converted, let p = dc.draggingPayload, p.source == .drawer {
            guard convertedCarrierID != p.id else { return }
            convertedCarrierID = p.id
            // In the turn right after it is added to the members, the two zone lists may not include it yet:
            // if it is not in the launch zone, decide by process state.
            let running = runningZoneIDs.contains(p.id) || (!launchZoneIDs.contains(p.id) && isRunning(p.id))
            dc.setCarrierSnapshot(
                ChipSnapshotter.snapshot(of: drawerChipContent(p.id, running: running),
                                         screenPoint: CGPoint(x: drawerRootScreenRect.midX, y: drawerRootScreenRect.midY)),
                reanchor: true)
        } else if !converted, convertedCarrierID != nil {
            convertedCarrierID = nil
            dc.setCarrierSnapshot(nil, reanchor: true)   // back to the drag-start image; a no-op inside if the drag has already ended
        }
    }
}

// MARK: - Drawer drag-reorder preference

private struct DrawerChipFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Natural grid height (measured, feeds the "too tall, scroll internally" decision).
private struct DrawerContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Root view of the drawer host: `DrawerView` + its eight environment objects.
///
/// It exists only to give `PanelCoordinator` a **nameable** host type `NSHostingView<DrawerRootView>`: the
/// host is built once and each later open only swaps `rootView` (2026-09-04, the fix for dropped frames on
/// drawer open), while a `DrawerView(...).environmentObject(...)` chain yields an unnameable
/// `ModifiedContent<…>`.
struct DrawerRootView: View {
    let maxContentHeight: CGFloat
    let usesLiquidGlass: Bool
    let isDrawerOpen: () -> Bool
    let onPrimaryAction: () -> Void
    let runtime: AppRuntime
    let drawerStore: DrawerStore
    let messagingStore: MessagingAppStore
    let drawerOrderStore: DrawerOrderStore
    let dragController: DragController
    let keptAppStore: KeptAppStore
    let runningApplicationStore: RunningApplicationStore
    let appMembershipController: AppMembershipController

    var body: some View {
        DrawerView(maxContentHeight: maxContentHeight,
                   usesLiquidGlass: usesLiquidGlass,
                   isDrawerOpen: isDrawerOpen,
                   onPrimaryAction: onPrimaryAction)
            .environmentObject(runtime).environmentObject(drawerStore).environmentObject(messagingStore)
            .environmentObject(drawerOrderStore).environmentObject(dragController)
            .environmentObject(keptAppStore).environmentObject(runningApplicationStore)
            .environmentObject(appMembershipController)
    }
}
