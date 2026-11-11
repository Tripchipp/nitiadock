import Foundation

/// Taskbar drag reordering, route A (keep order stable within a session): the **display-order state layer**,
/// covering only the main taskbar's **live window zone** (live zone). Holds an ordered list of chip ids;
/// every render reconciles it via `reconciled(current:)` with the chips currently alive (existing keep their
/// order, new windows go to the end, really closed ones are dropped); dragging changes order via `move`.
///
/// Boundary: the messaging pinned zone's order belongs to `MessagingAppStore`;
/// this store **covers the live zone only and never crosses over**.
/// The ordering primitives are in `StripOrdering`
/// (`UI/ReadModel/StripItem.swift`); this class is only their stateful shell.
///
/// Persistence has two layers and does **not** restore layout across closes the way the Dock does:
/// - **Same boot cycle** (`stripLiveOrder` + `stripLiveOrderBootTime`): exact chip order, keyed by
///   `tabgrp-*` stable seat tokens + `app-*` of kept apps. If the boot time
///   changed (machine restarted, cgWindowIDs reshuffled/reused) the whole
///   record is rejected: **no chip id is ever carried across boots**.
/// - **Across machine restarts** (`stripKeptAppOrderV1`):
///   stores only bundleID ranks of ordinary kept apps. It is not
///   a "reorder once on cold start" mode but a **standing placement rule** fed to `StripOrdering.reconcile`:
///   cards with no position memory land by rank, late windows included (see `stableKeptRanks` for why).
///
/// Messaging zone and drawer order still belong to their own order
/// stores; this class covers the live zone only and never crosses over.
@MainActor
final class StripOrderStore: ObservableObject {
    @Published private(set) var liveOrder: [String] = []
    @Published private(set) var stableKeptAppOrder: [String] = []

    private let orderKey = "stripLiveOrder"
    private let bootKey = "stripLiveOrderBootTime"
    private let stableKeptOrderKey = "stripKeptAppOrderV1"
    /// Boot time of this boot (seconds). Constant within a boot cycle, so cached once.
    private let bootTime: Int

    /// Position-memory stickiness (slice ①). When a chip id **briefly disappears** from the current snapshot
    /// (an occasional missed AX read in Safari, tab group anchor migration, etc.), it is not removed from
    /// the remembered order at once: the disappearance time is recorded, and within grace it still counts as
    /// present and keeps its rank, but the display layer does not render it (`reconciled` filters by the
    /// real current). Only if it has not returned after grace is it dropped. A card that blinks out thus
    /// returns to its slot instead of being treated as new and thrown to the right of its same-app siblings.
    private var absentSince: [String: Date] = [:]
    private static let rankRetentionGrace: TimeInterval = 5.0

    /// Sticky id→appKey memory. Once a window disappears its appKeyOf mapping is
    /// lost, and a placeholder app-* would jump to the tail for lack of siblings.
    /// Every sync merges the passed-in appKeyOf; eviction happens at the end of sync,
    /// after liveOrder is updated, keeping only keys in current ∪ liveOrder. Ids in
    /// grace are still in liveOrder, so their keys are not dropped by mistake.
    private var stickyAppKeys: [String: String] = [:]

    /// **External block stash** for the exact landing of a drag from drawer back to taskbar. In the
    /// promotion frame the window cards are not in the live zone yet (`drawerStore.remove` only puts
    /// them back next round), so no card id is available. Only `bundleID + target` is recorded; card
    /// ids are resolved in the next `sync` via `appKeyOf` and placed with `movingBlock`, and the
    /// resolved ids are written back to `boundIDs` so undo can remove exactly those.
    private var externalBlock: (bundleID: String, target: String?, after: Bool, boundIDs: [String])?

    private let defaults: UserDefaults
    private let now: () -> Date
    private let keptIDsProvider: () -> Set<String>
    private let stableKeptOrderProvider: () -> [String]
    private let inventoryLog: WindowInventoryAnomalyLog
    private var lastProjectionSample: InventoryOrderProjectionSample?

    /// Whether the diagnostic payload should be built. Callers ask before creating an
    /// `InventoryOrderProjectionSample`: the payload contains the whole appKey dictionary,
    /// so building it with logging off is wasted work (same pattern as `AppTracker`).
    var isInventoryLogEnabled: Bool { inventoryLog.isEnabled }

    init(defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         keptIDsProvider: @escaping () -> Set<String> = { [] },
         stableKeptOrderProvider: (() -> [String])? = nil,
         bootTimeProvider: () -> Int = StripOrderStore.bootTimeSeconds,
         inventoryLog: WindowInventoryAnomalyLog = WindowInventoryAnomalyLog()) {
        self.defaults = defaults
        self.now = now
        self.keptIDsProvider = keptIDsProvider
        self.stableKeptOrderProvider = stableKeptOrderProvider ?? { Array(keptIDsProvider()).sorted() }
        self.inventoryLog = inventoryLog
        bootTime = bootTimeProvider()

        let eligibleOrder = self.stableKeptOrderProvider()
        let eligible = Set(eligibleOrder)
        if defaults.object(forKey: stableKeptOrderKey) != nil {
            let stored = defaults.stringArray(forKey: stableKeptOrderKey) ?? []
            var cleaned = Self.cleanedStableOrder(stored, eligible: eligible)
            let known = Set(cleaned)
            cleaned.append(contentsOf: eligibleOrder.filter { !known.contains($0) })
            stableKeptAppOrder = cleaned
            if cleaned != stored { defaults.set(cleaned, forKey: stableKeptOrderKey) }
        } else {
            let legacyApps = (defaults.stringArray(forKey: orderKey) ?? []).compactMap { id -> String? in
                guard id.hasPrefix("app-") else { return nil }
                return String(id.dropFirst(4))
            }
            stableKeptAppOrder = Self.cleanedStableOrder(legacyApps + eligibleOrder, eligible: eligible)
            defaults.set(stableKeptAppOrder, forKey: stableKeptOrderKey)
        }

        // Trust the exact chip order only when the record is from the **same boot cycle**
        // (cgWindowIDs are reshuffled/reused across restarts). No chip id is carried across
        // boots; the bundleID ranks of `stableKeptAppOrder` order them in reconcile.
        if defaults.object(forKey: bootKey) != nil,
           defaults.integer(forKey: bootKey) == bootTime,
           let saved = defaults.stringArray(forKey: orderKey) {
            liveOrder = saved
        }
    }

    /// Cross-restart ranks (appKey → rank). Fed to `StripOrdering` so kept-app cards **with no
    /// memory** land by rank. Not a "one-off cold start mode": at boot the taskbar comes up
    /// before most apps (AppTracker still has four catch-up scans), and late windows must follow
    /// the same rule, or those apps would never get a rank and could only land at the end.
    private var stableKeptRanks: [String: Int] {
        let eligible = Set(stableKeptOrderProvider())
        var ranks: [String: Int] = [:]
        for appKey in stableKeptAppOrder where eligible.contains(appKey) {
            ranks[appKey] = ranks.count
        }
        return ranks
    }

    /// Display order = the remembered order reconciled with the currently
    /// alive chip ids (does not mutate state, safe to read in body).
    /// `appKeyOf` (chip id → owning app key) puts a new window next to
    /// its same-app siblings rather than at the far right of the taskbar.
    /// Sticky appKeys are merged non-destructively here:
    /// passed-in values win, remembered ones are the fallback.
    ///
    /// **Pure read, never writes `absentSince`** (no side effects during body evaluation): this
    /// frame's absent anchors are computed by `absentRankAnchors` from `liveOrder` + read-only
    /// `absentSince` + the current time, the same computation `sync` uses. Rendering happens before
    /// `sync` stamps, so an entry that just went absent still has nil `absentSince`;
    /// `absentRankAnchors` lets it take part in positioning as an in-grace anchor. Otherwise a new
    /// `app-*`/`tabgrp-*` from quit/reopen is appended at the tail on the first frame and pulled back
    /// by the spring = a shadow slide. Anchors only position a new id next to its same-app siblings
    /// and are filtered from the visible output afterwards (the user sees only the real current).
    func reconciled(current: [String], appKeyOf: [String: String] = [:],
                    headPreferred: Set<String> = []) -> [String] {
        var merged = stickyAppKeys
        merged.merge(appKeyOf) { _, new in new }
        let currentSet = Set(current)
        let anchors = absentRankAnchors(current: currentSet, now: now())
        let effectiveCurrent = current + anchors
        backfillPlaceholderAppKeys(&merged, ids: effectiveCurrent)
        let ordered = StripOrdering.reconcile(
            remembered: liveOrder,
            current: effectiveCurrent,
            appKeyOf: merged,
            headPreferredKeys: headPreferred,
            stableKeptRanks: stableKeptRanks
        )
        let anchorSet = Set(anchors)
        return ordered.filter { !anchorSet.contains($0) }
    }

    /// Absent rank anchors (**shared** by the `reconciled` render path and the `sync` side-effect
    /// path): old entries in `liveOrder` that are not in `current` this frame but should still hold
    /// their position. **The full set comes from `liveOrder`, not `absentSince.keys`**: the first
    /// render happens before `sync` stamps, so a just-absent entry still has nil `absentSince` and
    /// must count as an in-grace anchor with elapsed=0; stamped entries still within grace remain
    /// anchors; past grace they no longer are. **Pure read**, never writes `absentSince`.
    private func absentRankAnchors(current: Set<String>, now: Date) -> [String] {
        liveOrder.filter { id in
            guard !current.contains(id) else { return false }
            guard let t = absentSince[id] else { return true }   // just went absent (sync has not stamped yet) → elapsed=0
            return now.timeIntervalSince(t) <= Self.rankRetentionGrace
        }
    }

    /// An `app-*` placeholder id carries its bundleID; when the mapping is missing it is derived from the id
    /// (`app-com.foo` → `com.foo`), so first-frame "same-app sibling" positioning does not come up empty.
    /// Kept quit (`tabgrp-*` → `app-*`) and reopen (`app-*` → `tabgrp-*`) both rely on the placeholder and
    /// the real window sharing one app key on the first frame. Existing mappings are not overwritten.
    private func backfillPlaceholderAppKeys(_ map: inout [String: String], ids: [String]) {
        for id in ids where id.hasPrefix("app-") && map[id] == nil {
            map[id] = String(id.dropFirst(4))
        }
    }

    /// Converges the remembered order with the current live set (drop really closed ones, insert
    /// new windows next to same-app siblings), keeping the manually arranged relative order.
    /// **Call as a side effect of a snapshot change, never during body evaluation.** `appKeyOf`
    /// must come from the same source as in `reconciled`, or the persisted order and the display
    /// order disagree and a new window jumps from its sibling back to the end on the next frame.
    func sync(
        current: [String],
        appKeyOf: [String: String] = [:],
        headPreferred: Set<String> = [],
        projectionSample: InventoryOrderProjectionSample? = nil
    ) {
        let now = self.now()
        if let projectionSample, projectionSample != lastProjectionSample {
            inventoryLog.record(.orderProjectionChanged(
                projectionSample.payload(previousLiveIDs: lastProjectionSample?.currentLiveIDs ?? [])
            ))
            lastProjectionSample = projectionSample
        }
        syncStableKeptMembership()
        // Merge appKeyOf into the sticky memory
        stickyAppKeys.merge(appKeyOf) { _, new in new }

        let currentSet = Set(current)

        // Returning ids: clear the absence stamp.
        for id in current { absentSince.removeValue(forKey: id) }
        // Ids that just vanished from the remembered order: stamp them absent
        // (only ids already on record). **Stamping happens in sync only.**
        for id in liveOrder where !currentSet.contains(id) && absentSince[id] == nil {
            absentSince[id] = now
        }
        // Absent ids within grace count as "still present" → keep rank;
        // expired ones are no longer kept → left for reconcile to drop.
        // Reuses the same anchor helper as reconciled → pre-sync render and post-sync visible order agree.
        // Stamping is done by now, so every anchor has an absentSince
        // (the helper's nil branch only applies on the render path).
        let anchors = absentRankAnchors(current: currentSet, now: now)
        let effectiveCurrent = current + anchors
        backfillPlaceholderAppKeys(&stickyAppKeys, ids: effectiveCurrent)
        let expiredMemory = absentSince.filter {
            now.timeIntervalSince($0.value) > Self.rankRetentionGrace
        }
        let reconcileResult = StripOrdering.reconcileWithTrace(
            remembered: liveOrder,
            current: effectiveCurrent,
            appKeyOf: stickyAppKeys,
            headPreferredKeys: headPreferred,
            stableKeptRanks: stableKeptRanks
        )
        var next = reconcileResult.order
        absentSince = absentSince.filter { now.timeIntervalSince($0.value) <= Self.rankRetentionGrace }
        // Consume the external block stash: once all window cards of the dragged app are in current
        // (reconcile has put them in next), resolve the group via appKeyOf and land the whole block
        // at the stashed target, **in a single publish**: no flash-in at the tail, no relocation by
        // reconcile rules. app-* fallback cards are excluded. The keepPlacement path has no window
        // cards; fall back to the placeholder id "app-\(bundleID)" as a single-element block.
        if var ext = externalBlock {
            var blockIDs = next.filter { stickyAppKeys[$0] == ext.bundleID && !$0.hasPrefix("app-") }
            if blockIDs.isEmpty {
                let placeholderID = "app-\(ext.bundleID)"
                if next.contains(placeholderID) { blockIDs = [placeholderID] }
            }
            if !blockIDs.isEmpty {
                next = StripOrdering.movingBlock(next, move: blockIDs, relativeTo: ext.target, after: ext.after)
                ext.boundIDs = blockIDs
                externalBlock = ext
            }
        }
        for (chipID, since) in expiredMemory {
            inventoryLog.record(.orderMemoryDropped(InventoryOrderMemoryDroppedPayload(
                chipID: chipID,
                appKey: stickyAppKeys[chipID],
                previousIndex: liveOrder.firstIndex(of: chipID) ?? -1,
                absentForMs: max(0, Int((now.timeIntervalSince(since) * 1_000).rounded()))
            )))
        }
        let currentSetForLog = Set(current)
        let visibleNextForLog = next.filter(currentSetForLog.contains)
        for placement in reconcileResult.placements where currentSetForLog.contains(placement.chipID) {
            inventoryLog.record(.orderChipPlaced(InventoryOrderChipPlacedPayload(
                chipID: placement.chipID,
                appKey: stickyAppKeys[placement.chipID],
                index: visibleNextForLog.firstIndex(of: placement.chipID) ?? placement.index,
                reason: placement.reason.rawValue
            )))
        }
        if next != liveOrder {
            liveOrder = next
            updateStableKeptOrder(from: liveOrder)
            persistLiveOrder()
        } else {
            updateStableKeptOrder(from: liveOrder)
        }

        // Evict sticky appKeys: keep only keys in current ∪ liveOrder (ids in grace are still in liveOrder).
        let aliveKeys = currentSet.union(Set(liveOrder))
        stickyAppKeys = stickyAppKeys.filter { aliveKeys.contains($0.key) }
    }

    // MARK: - External block landing (drawer back to taskbar, exact landing)

    /// Promotion into the taskbar: stashes "land this app's window cards as a block to
    /// the left/right of `target` (`target==nil` = end)", consumed by the next `sync`.
    func stageExternalBlock(bundleID: String, relativeTo target: String?, after: Bool) {
        externalBlock = (bundleID, target, after, [])
    }

    /// Continued reordering (after the window cards materialized and the stash was consumed):
    /// moves this group of ids as a block to `targetID`. Publishes only on change.
    func reorderBlock(ids: [String], relativeTo targetID: String, after: Bool) {
        let next = StripOrdering.movingBlock(liveOrder, move: ids, relativeTo: targetID, after: after)
        if next != liveOrder { liveOrder = next; updateStableKeptOrder(from: next); persistLiveOrder() }
    }

    /// Landing: clears only the stash tracking; `boundIDs` stay in `liveOrder` (already regular members).
    func commitExternalBlock() { externalBlock = nil }

    /// Undo promotion: removes `boundIDs` from `liveOrder`, clears their `absentSince` (or the
    /// 5s rank stickiness would revive them as phantom ranks), and clears the stash. **Must be
    /// called before the `drawerStore.add` in `revertDrawerToStrip` triggers sync.**
    func cancelExternalBlock() {
        guard let ext = externalBlock else { return }
        let ids = Set(ext.boundIDs)
        if !ids.isEmpty {
            let next = liveOrder.filter { !ids.contains($0) }
            for id in ids { absentSince.removeValue(forKey: id) }
            if next != liveOrder { liveOrder = next; updateStableKeptOrder(from: next); persistLiveOrder() }
        }
        externalBlock = nil
    }

    /// Drag placement: lands `draggedID` to the left/right of `targetID`. Reconciles first to
    /// fix the current display order, then inserts; does not publish if the order is unchanged
    /// (`dropUpdated` fires at high frequency during a drag; this blocks needless churn).
    func reorder(draggedID: String, relativeTo targetID: String, after: Bool, current: [String]) {
        let base = StripOrdering.reconcile(remembered: liveOrder, current: current, appKeyOf: stickyAppKeys)
        let next = StripOrdering.reordering(base, move: draggedID, relativeTo: targetID, after: after)
        if next != liveOrder { liveOrder = next; updateStableKeptOrder(from: next); persistLiveOrder() }
    }

    /// Persists the current order: `tabgrp-*` + kept `app-*` + this boot's time.
    private func persistLiveOrder() {
        defaults.set(StripOrdering.persistableLiveOrder(liveOrder, keptIDs: keptIDsProvider()), forKey: orderKey)
        defaults.set(bootTime, forKey: bootKey)
    }

    private func syncStableKeptMembership() {
        let eligibleOrder = stableKeptOrderProvider()
        let eligible = Set(eligibleOrder)
        var next = stableKeptAppOrder.filter(eligible.contains)
        let known = Set(next)
        next.append(contentsOf: eligibleOrder.filter { !known.contains($0) })
        guard next != stableKeptAppOrder else { return }
        stableKeptAppOrder = next
        defaults.set(next, forKey: stableKeptOrderKey)
    }

    /// Reorder only the visible members in the full stable list. Hidden drawer members keep
    /// their slots, matching the drawer/messaging order-store contract.
    private func updateStableKeptOrder(from chipOrder: [String]) {
        syncStableKeptMembership()
        let eligible = Set(stableKeptOrderProvider())
        var seen = Set<String>()
        let visible = chipOrder.compactMap { id -> String? in
            guard let appKey = stickyAppKeys[id], eligible.contains(appKey), seen.insert(appKey).inserted else {
                return nil
            }
            return appKey
        }
        guard !visible.isEmpty else { return }
        let visibleSet = Set(visible)
        let slots = stableKeptAppOrder.indices.filter { visibleSet.contains(stableKeptAppOrder[$0]) }
        guard slots.count == visible.count else { return }
        var next = stableKeptAppOrder
        for (slot, appKey) in zip(slots, visible) { next[slot] = appKey }
        guard next != stableKeptAppOrder else { return }
        stableKeptAppOrder = next
        defaults.set(next, forKey: stableKeptOrderKey)
    }

    private static func cleanedStableOrder(_ values: [String], eligible: Set<String>) -> [String] {
        var seen = Set<String>()
        return values.filter { eligible.contains($0) && seen.insert($0).inserted }
    }

    /// Seconds of `kern.boottime`; 0 if unreadable (= trust no record, a safe degradation).
    private nonisolated static func bootTimeSeconds() -> Int {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        return sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 ? Int(tv.tv_sec) : 0
    }
}
