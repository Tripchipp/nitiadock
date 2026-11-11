import Foundation

/// Single mutation boundary for app membership conversions.
///
/// Drawer membership is placement; kept membership means an entry survives app
/// exit. Kept, drawer, and messaging identity may all coexist. Finder joins kept
/// and drawer like any other app (2026-08-20) but is still barred from the
/// messaging zone (see `FinderTaskbarPolicy`).
@MainActor
final class AppMembershipController: ObservableObject {
    private let keptAppStore: KeptAppStore
    private let drawerStore: DrawerStore
    private let messagingStore: MessagingAppStore

    init(
        keptAppStore: KeptAppStore,
        drawerStore: DrawerStore,
        messagingStore: MessagingAppStore
    ) {
        self.keptAppStore = keptAppStore
        self.drawerStore = drawerStore
        self.messagingStore = messagingStore
    }

    /// Native check-menu toggle. It never changes placement. Kept may coexist with
    /// messaging identity under the unified model.
    func setKept(_ bundleID: String, enabled: Bool) {
        guard keptAppStore.canKeep(bundleID) else { return }
        if enabled {
            keptAppStore.add(bundleID)
        } else {
            keptAppStore.remove(bundleID)
        }
    }

    /// Placement-only move: this API never touches kept.
    ///
    /// Auto-enabling kept on stash is a **drag-landing** policy, not a placement-API one:
    /// `DragController.endDrag()` calls `applyDragLanding` below for it. So do not restate
    /// it here, and note this method has no production caller today (menus offer no drawer
    /// placement action; drag is the only way in).
    func moveToDrawer(_ bundleID: String) {
        guard !bundleID.isEmpty else { return }
        drawerStore.add(bundleID)
    }

    /// Sets kept after a drag lands (2026-08-06). The rule itself is still the pure decision
    /// `DragConversionPlan.enablesKeptOnDrop`; this only brings "the one place that writes kept from outside
    /// the controller" inside the single mutation boundary (2026-09-05). **Re-enabled on every drag-in**, not
    /// a one-time seed, unlike the first-time kept in `markMessaging`; see the drag-and-drawer rule. Called
    /// only after `endDrag()` has landed and the drawer has its final membership.
    func applyDragLanding(bundleID: String, originSource: DragSource) {
        guard DragConversionPlan.enablesKeptOnDrop(originSource: originSource,
                                                   endedInDrawer: drawerStore.contains(bundleID)) else { return }
        keptAppStore.add(bundleID)
    }

    /// "Pin to messaging zone": mark + set kept on first join (kept by default). Does not change the drawer;
    /// position only changes by dragging.
    func markMessaging(_ bundleID: String) {
        guard FinderTaskbarPolicy.canMarkMessaging(bundleID) else { return }
        if messagingStore.mark(bundleID) {
            keptAppStore.add(bundleID)
        }
    }

    /// Auto-tier registration: seed kept for each newly auto-detected messaging app
    /// (first registration only, so a later user un-check is not reopened). Does not
    /// change drawer placement.
    func autoRegisterMessaging(runningBundleIDs: Set<String>,
                               mainWindowIdentifiableBundleIDs: Set<String>) {
        let added = messagingStore.autoRegister(
            runningBundleIDs: runningBundleIDs,
            mainWindowIdentifiableBundleIDs: mainWindowIdentifiableBundleIDs
        )
        for bundleID in added {
            keptAppStore.add(bundleID)
        }
    }

    /// Unchecking "Pin to messaging zone": only clears the messaging identity and records the opt-out; kept
    /// and drawer stay unchanged.
    func unmarkMessaging(_ bundleID: String) {
        messagingStore.unmark(bundleID)
    }

    /// Startup repair. The only illegal membership left is Finder in the messaging
    /// zone. Since 2026-08-20 Finder may be kept and may sit in the drawer, and this
    /// runs on every launch, so clearing drawer placement here would wipe the user's
    /// own stash. Kept and messaging deliberately coexist, so there is no
    /// kept/messaging reconciliation.
    func reconcileInvalidMemberships() {
        let finder = FinderTaskbarPolicy.bundleID
        if messagingStore.contains(finder) {
            messagingStore.unmark(finder)
        }
    }
}

/// Defensive, side-effect-free projections used by the strip, drawer, and capsule.
enum AppMembershipProjection {
    /// Full placement list. Hidden members remain here so their drawer order is
    /// stable when a later launch makes them visible again.
    static func drawerMembers(drawerIDs: [String]) -> [String] {
        filteredUnique(drawerIDs, excluding: [])
    }

    /// Core drawer visibility rule: placement is durable, but a chip is rendered
    /// only while the app runs or kept keeps it reachable. Messaging identity is no
    /// longer an independent retention condition: kept alone decides.
    static func visibleDrawerIDs(
        drawerIDs: [String],
        keptIDs: [String],
        runningIDs: Set<String>
    ) -> [String] {
        let retained = Set(keptIDs).union(runningIDs)
        return filteredUnique(drawerIDs, excluding: []).filter { retained.contains($0) }
    }

    /// Messaging-zone visibility: a messaging app not stashed in the drawer, shown
    /// only while running or kept. Order-preserving, deduped.
    static func visibleMessagingIDs(
        messagingIDs: [String],
        drawerIDs: [String],
        keptIDs: [String],
        runningIDs: Set<String>
    ) -> [String] {
        let retained = Set(keptIDs).union(runningIDs)
        return filteredUnique(messagingIDs, excluding: Set(drawerIDs)).filter { retained.contains($0) }
    }

    /// Badge read scope (decoupled from the messaging zone since 2026-08-23): **identity** ∩ running −
    /// drawer. Icons in the drawer draw no badge and have no card on the bar, so there is nowhere to draw it;
    /// dropping them saves an AX trip. Output is in lexicographic order so `BadgeStore`'s "re-walk only on
    /// change" comparison is stable.
    static func badgeEligibleIDs(
        isMessagingApp: (String) -> Bool,
        drawerIDs: [String],
        runningIDs: Set<String>
    ) -> [String] {
        let drawer = Set(drawerIDs)
        return runningIDs
            .filter { !$0.isEmpty && !drawer.contains($0) && isMessagingApp($0) }
            .sorted()
    }

    static func drawerPreview(
        drawerIDs: [String],
        keptIDs: [String],
        runningIDs: Set<String>,
        limit: Int = 9
    ) -> [String] {
        Array(visibleDrawerIDs(
            drawerIDs: drawerIDs,
            keptIDs: keptIDs,
            runningIDs: runningIDs
        ).prefix(max(0, limit)))
    }

    private static func filteredUnique(_ bundleIDs: [String], excluding excluded: Set<String>) -> [String] {
        var seen = Set<String>()
        return bundleIDs.filter { bundleID in
            !bundleID.isEmpty && !excluded.contains(bundleID) && seen.insert(bundleID).inserted
        }
    }
}
