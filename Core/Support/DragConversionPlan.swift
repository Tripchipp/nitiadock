import Foundation

/// Drag source: selects the drop zone, the landing action and the carrier drawing.
/// `.folder` = pinned folder chip (reorder within the zone + drag out to remove + drag
/// back to the window zone to open), **fully isolated from strip/drawer stash semantics**:
/// not in drawerStore, not in the drop zone (canExternalDrop=false), no convert/revert;
/// DockStripView only provides landing geometry, and the final commit
/// is triggered by the mouseUp/poll fallback path of `endDrag()`.
/// `.messaging` = messaging zone app chip (reorder within the zone + drag into the drawer to stash): same
/// drop zone as `.strip` (capsule + the open drawer body); the rest of the taskbar is not a landing for it.
/// Defined in this file (not DragController.swift): the test target compiles local source
/// files, so the pure decision layer must compile without DragController's AppKit dependencies.
enum DragSource { case strip, drawer, folder, messaging }

/// Behavior mode when a drawer icon is dragged to the taskbar (pure decision, DockStripView feeds the facts).
enum DrawerDragOutMode: Equatable {
    case reject             // messaging app not running -> not accepted (stays in the drawer)
    case releaseToMessaging // running messaging app -> temporarily released back to the messaging zone only once inside its range
    case unstash            // has a real window -> existing exact placement path
    case keepPlacement      // app fallback / kept placeholder -> app-level placement, never modifies kept
}

/// Pure decision layer for cross-panel drag conversion (review 2026-07-11 P2-6). No
/// geometry, stores or panels come in: the caller feeds current facts and this only
/// answers "what to do"; executing and rolling back the conversion is in `DragController`.
enum DragConversionPlan {

    /// Drawer drag-out mode. The messaging check must come **before** the real-window check:
    /// a running messaging app has a main window and would otherwise fall into unstash.
    ///
    /// **The messaging member branch decides "will it actually appear in the messaging
    /// zone once released"**, so it must share its source with the zone's own visibility
    /// rule (`AppMembershipProjection.visibleMessagingIDs` = running ∪ kept).
    /// It used to check `isInSnapshot` (the window list), which is **another source of
    /// truth**: with WeChat's main window closed the process is running, the icon has a
    /// running dot and the messaging zone still shows it, but the window list does not contain
    /// it. Hence "the running dot is lit yet it cannot be dragged back to the messaging zone"
    /// (measured 2026-08-20, log evidence `mode=reject in window list=False running=True`).
    static func drawerDragOutMode(bundleID: String,
                                  isMessagingMember: Bool,
                                  isInSnapshot: Bool,
                                  isRunningProcess: Bool,
                                  hasRealWindow: Bool,
                                  isKept: Bool) -> DrawerDragOutMode {
        guard !bundleID.isEmpty else { return .reject }
        if isMessagingMember {
            // Reject only when neither holds: releasing it then really would make it vanish.
            return (isRunningProcess || isKept) ? .releaseToMessaging : .reject
        }
        if hasRealWindow { return .unstash }
        // app-* fallback while running, or a kept placeholder while stopped.
        return isInSnapshot || isKept ? .keepPlacement : .reject
    }

    /// Release action for `endDrag` (`.messaging` / `.drawer`
    /// sources; `.strip`/`.folder` do not come through here).
    enum EndAction: Equatable {
        case none
        /// Messaging zone chip dropped in the drop zone (capsule / open drawer) -> stash via drawer.add.
        case stashMessagingChip
        /// Drawer icon already converted into the taskbar -> tell the ordering layer to commit.
        case commitDrawerToStrip
        /// Drawer icon not converted, dropped on the taskbar, not a
        /// messaging member -> downgrade to removal (drawer.remove).
        case fallbackUnstash
    }

    /// Release decision. A messaging member's drawer icon **never** takes the downgrade unstash:
    /// its only way back to the taskbar is the temporary release inside the messaging zone range
    /// (drawerToMessaging); released anywhere else it stays in the drawer (review P1-3).
    /// A payload already released to the messaging zone has source `.messaging`: outside the
    /// drop zone -> `.none` (drawer.remove already happened, the release is the landing);
    /// inside the drop zone -> stash (equivalent to a rollback, drawer.add is idempotent).
    static func endAction(source: DragSource,
                          isConvertedToStrip: Bool,
                          isOverDropZone: Bool,
                          isMessagingMember: Bool) -> EndAction {
        switch source {
        case .strip, .folder:
            return .none
        case .messaging:
            return isOverDropZone ? .stashMessagingChip : .none
        case .drawer:
            if isConvertedToStrip { return .commitDrawerToStrip }
            guard isOverDropZone, !isMessagingMember else { return .none }
            return .fallbackUnstash
        }
    }

    /// Whether to turn on "Keep in Dock" for this app after the drag lands (decided 2026-08-06).
    ///
    /// **Inbound only**: turned on only when this drag brought it into the drawer from outside;
    /// dragging from the drawer back to the taskbar never turns it off (the user may have checked
    /// Keep themselves, and turning it off would erase a setting unrelated to the drawer).
    ///
    /// **Every drag-in turns it on again**, not a one-time seed. If the user unchecks it
    /// and drags the app in again, it is checked again. This is the intended semantics:
    /// dragging into the drawer is an explicit action that each time restates "I want it
    /// to live here". **Do not compare it to `AppMembershipController.markMessaging`**:
    /// that one gets true one-time seeding from the first return value of
    /// `MessagingAppStore.mark`; here we deliberately keep no equivalent history of
    /// "who was auto-checked before" (permanent data for an edge case is not worth it).
    /// A case in `DragControllerConversionTests` locks this behavior; do not fix it as a bug.
    ///
    /// Called only after `endDrag()` lands. The conversion preview (`convert*`) and rollback (`revert*` /
    /// `cancelDrag`) phases **never touch kept**, so that symmetric placement transaction is unchanged.
    ///
    /// - Parameter originSource: Source **at drag start**. Do not pass `draggingPayload.source`: converting
    ///   into the drawer body flips it to `.drawer`, which collides with reordering inside the drawer.
    /// - Parameter endedInDrawer: Whether it is still in the drawer after landing (read from `DrawerStore`).
    static func enablesKeptOnDrop(originSource: DragSource, endedInDrawer: Bool) -> Bool {
        guard endedInDrawer else { return false }
        return originSource == .strip || originSource == .messaging
    }
}
