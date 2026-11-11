import CoreGraphics
import Foundation

enum WindowDisplayTitle {
    static func resolve(rawTitle: String?, fallbackName: String) -> String {
        rawTitle.flatMap { title in
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title
        } ?? fallbackName
    }

    /// Card label: strips the trailing "separator + app name" from a window title (`local-dc02 - Google Chrome`
    /// -> `local-dc02`). The icon already shows which app it is, so the suffix is pure repetition, and it pushes
    /// the distinguishing first half past `WindowTitleTextMetrics.maximumWidth` (140pt) into truncation: in the
    /// issue #41 screenshot the two Chrome cards look like that, one showing only "local-dc02 - Google C…".
    ///
    /// **Applies only to the rendered label**: the `.help()` system tooltip still shows the full title,
    /// otherwise the app name of an icon-only card (which shows no text) would be visible nowhere.
    /// The window list in the menu (`WindowListMenuPlan`) deliberately skips this:
    /// menu rows have room and do not truncate.
    static func trimmingAppNameSuffix(_ title: String, appName: String) -> String {
        let app = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !app.isEmpty, title.hasSuffix(app), title != app else { return title }

        var head = Substring(title).dropLast(app.count)
        // Consume only one separator: `A - B - Chrome` minus its tail should be `A - B`, not `A`.
        guard let separator = separators.first(where: { head.hasSuffix($0) }) else { return title }
        head = head.dropLast(separator.count)

        let remainder = head.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only whitespace left = the title was just the app name, keep it as is.
        return remainder.isEmpty ? title : remainder
    }

    /// Trailing separators. Longer ones first, so ` - ` does not match first and eat half of the `–` / `—` cases.
    private static let separators = [" - ", " — ", " – ", " | ", " · ", "-", "—", "–", "|"]
}

struct StripItem: Hashable {
    let id: String
    let title: String
    let status: String
    let appID: String
    let bundleIdentifier: String?
    let sameAppCardCount: Int
    let showsTitle: Bool
    let isAppLevelFallback: Bool
    let canMinimize: Bool
    let canHide: Bool
    let canClose: Bool
    let isOnDesktop: Bool
    /// Current representative WindowServer id for this chip, if any. Live snapshot
    /// fact only: never persisted, never used as chip identity.
    let cgWindowID: CGWindowID?
    /// Current representative frame in screen coordinates, if available.
    let bounds: CGRect?
    /// Current representative process id.
    let pid: Int32
    /// Which display the representative window sits on (coarse key; nil = unknown). Live fact only.
    let displayUUID: String?
    /// Window the show/hide actions (toggle/activate/minimize/hide/newWindow) route to, and the key
    /// the optimistic-state overlay is read/written under. For a native tab group this is the focused (active)
    /// tab; for a plain window it equals `id`.
    let actionWindowID: String
    /// All real windows behind this chip. A single window -> `[id]`; a tab group -> every tab,
    /// so "Close Window" can close the whole group (decided 2026-06-14: close the whole group).
    let memberWindowIDs: [String]

    /// Builds a chip from one or more window records. ≥2 records means a native tab group
    /// (same app + identical frame) collapsed into a single chip.
    init(members: [WindowRecord], sameAppCardCount: Int = 1) {
        // Stable SwiftUI identity = the group's stable token (`groupID`). It does not change with the active
        // tab's CGWindowID, nor with members coming and going (background tabs, minimized ones leaving AX),
        // so the merged card never changes identity, jumps or splits.
        // All members of a group share one groupID, so take the first; an app-* fallback card's groupID =
        // its own id (a group of one).
        let anchor = members.min { ($0.cgWindowID ?? .max) < ($1.cgWindowID ?? .max) } ?? members[0]
        let token = members[0].groupID
        // Display + action representative = the **visible** tab of the group. In a native tab group the
        // non-current tabs report to AX as `.minimized`; exactly one tab is on-screen. Prefer the
        // truly-focused tab (`.active`, only set while the app is frontmost), else the lone visible
        // (non-minimized) tab, else (whole group minimized/hidden) the stable anchor.
        //
        // Keying on visibility (min flag) rather than focus is what makes tab-switching feel instant:
        // switching tabs fires Deminiaturized for the new tab (min→false) promptly, whereas the
        // .active/focus flag lags. So the title follows the Deminiaturized notification, not focus.
        let representative = members.first { $0.status == .active }
            ?? members.first { $0.status != .minimized && $0.status != .hidden }
            ?? anchor

        self.id = token
        self.actionWindowID = representative.id.rawValue
        self.memberWindowIDs = members.map(\.id.rawValue)
        self.title = representative.title
        self.status = representative.status.rawValue
        self.appID = representative.appID.rawValue
        self.bundleIdentifier = representative.bundleIdentifier
        self.sameAppCardCount = sameAppCardCount
        self.showsTitle = sameAppCardCount >= 2
        self.isAppLevelFallback = token.hasPrefix("app-")
        self.canMinimize = self.isAppLevelFallback == false
        self.canHide = true
        self.canClose = self.isAppLevelFallback == false
        self.isOnDesktop = representative.isOnDesktop
        self.cgWindowID = representative.cgWindowID
        self.bounds = representative.bounds
        self.pid = representative.pid
        self.displayUUID = representative.displayUUID
    }

    init(record: WindowRecord, sameAppCardCount: Int = 1) {
        self.init(members: [record], sameAppCardCount: sameAppCardCount)
    }

    static func items(from snapshot: DockSnapshot) -> [StripItem] {
        let records = snapshot.orderedWindowIDs.compactMap { snapshot.windows[$0] }

        // Collapse native tab groups (same app + identical frame) into one slot, preserving
        // first-appearance order. Non-groupable records (app-* fallback, frameless) stay solo.
        var slots: [[WindowRecord]] = []
        var slotIndexByKey: [String: Int] = [:]
        for record in records {
            let key = tabGroupKey(for: record)
            if let key, let idx = slotIndexByKey[key] {
                slots[idx].append(record)
            } else {
                if let key { slotIndexByKey[key] = slots.count }
                slots.append([record])
            }
        }

        let countByApp = Dictionary(grouping: slots) { appGroupingKey(for: $0[0]) }
            .mapValues(\.count)

        return slots.map { members in
            StripItem(members: members, sameAppCardCount: countByApp[appGroupingKey(for: members[0])] ?? 1)
        }
    }

    private static func appGroupingKey(for record: WindowRecord) -> String {
        record.bundleIdentifier ?? record.appID.rawValue
    }

    /// Identity of the native tab group a record belongs to = the stable `groupID` token computed by the
    /// tracking layer.
    /// Tabs of one physical window share a token (once assigned it does not drift with the active tab's cgID
    /// or a background tab's frame) and are merged by it. An app-* fallback card's groupID = its own unique
    /// id, which never collides, so it stays separate and is never merged by mistake.
    /// Returns nil when the record does not take part in merging (a fallback card without a cgWindowID).
    private static func tabGroupKey(for record: WindowRecord) -> String? {
        guard record.cgWindowID != nil else { return nil }
        return record.groupID
    }
}

/// Taskbar drag reorder, route A (in-session order stability): pure ordering primitives.
///
/// Design: see the design decisions doc, "Taskbar drag reorder". This layer only applies stateless
/// transforms to a list of chip ids:
/// no UI, no persistence, no touching the window identity model. The stateful ordering layer
/// (`StripOrderStore`) and the drag gesture are wired in by later slices and reuse these primitives.
///
/// Key premise: **seat lifetime is already guaranteed upstream by `DockSnapshot`**. Minimized, hidden and
/// temporarily CG-missing windows stay in the snapshot (the seat is not released); only a real close removes
/// one. So here "not in the current list" equals "the seat has really ended"; this layer need not and
/// must not re-check whether the window exists.
enum StripOrdering {
    enum PlacementReason: String, Codable, Equatable {
        case sameAppSibling
        case headPreferred
        case stableKeptRank
        case tail
    }

    struct Placement: Equatable {
        let chipID: String
        let index: Int
        let reason: PlacementReason
    }

    struct ReconcileResult: Equatable {
        let order: [String]
        let placements: [Placement]
    }

    /// Reconciles the remembered display order with the chips currently alive and produces the new display order.
    ///
    /// - Remembered and still present -> keeps the remembered relative order (**the core of order
    ///   stability**: neighbours coming and going do not move already placed cards).
    /// - Newly appeared (present now, never remembered) -> inserted after the last existing chip of the same
    ///   app (stick to siblings: a tab torn out into its own window or Cmd+N lands right after the app's
    ///   existing chips instead of at the far right of the taskbar); appended at the end only when the app
    ///   has none (= a brand new app). An empty `appKeyOf` (the default) degrades to the old
    ///   "always append" behaviour.
    /// - Remembered but no longer present -> dropped (the seat has really ended, see the type comment).
    /// `headPreferredKeys`: a **new** window of one of these app keys with no sibling is inserted at the
    /// **head** of the live zone (not the end):
    /// a messaging app's pop-out window lands next to the message zone. Affects only new, unremembered ids;
    /// remembered ones keep their place.
    /// `stableKeptRanks`: cross-restart ranks of ordinary kept apps (appKey -> rank). A new id with no sibling
    /// that is not head-preferred, if its app is ranked, lands between the already ranked cards by rank
    /// instead of at the end.
    static func reconcile(remembered: [String], current: [String], appKeyOf: [String: String] = [:],
                          headPreferredKeys: Set<String> = [],
                          stableKeptRanks: [String: Int] = [:]) -> [String] {
        reconcileWithTrace(
            remembered: remembered,
            current: current,
            appKeyOf: appKeyOf,
            headPreferredKeys: headPreferredKeys,
            stableKeptRanks: stableKeptRanks
        ).order
    }

    static func reconcileWithTrace(
        remembered: [String],
        current: [String],
        appKeyOf: [String: String] = [:],
        headPreferredKeys: Set<String> = [],
        stableKeptRanks: [String: Int] = [:]
    ) -> ReconcileResult {
        let currentSet = Set(current)
        let rememberedSet = Set(remembered)
        // Remembered and still present: keep the remembered relative order
        var result = remembered.filter { currentSet.contains($0) }
        var placements: [Placement] = []
        func rank(_ id: String) -> Int? { appKeyOf[id].flatMap { stableKeptRanks[$0] } }
        // Newly appeared: (1) has a same-app sibling -> insert after it; (2) no sibling and the app is
        // head-preferred (messaging app pop-out) ->
        // insert at the head (after existing head-preferred ones, keeping their relative order); (3) no
        // sibling but a kept app in the cross-restart ranking
        // -> land between ranked cards by rank; (4) otherwise the end. Processed in `current` order, so
        // several new windows of one app
        // also keep their relative order.
        for id in current where !rememberedSet.contains(id) {
            let app = appKeyOf[id]
            if let app, let pos = result.lastIndex(where: { appKeyOf[$0] == app }) {
                result.insert(id, at: pos + 1)
                placements.append(Placement(chipID: id, index: pos + 1, reason: .sameAppSibling))
            } else if let app, headPreferredKeys.contains(app) {
                let headPos = result.lastIndex { appKeyOf[$0].map(headPreferredKeys.contains) ?? false }
                let index = headPos.map { $0 + 1 } ?? 0
                result.insert(id, at: index)
                placements.append(Placement(chipID: id, index: index, reason: .headPreferred))
            } else if let app, let myRank = stableKeptRanks[app] {
                let index = stableKeptInsertIndex(
                    in: result,
                    myRank: myRank,
                    rank: rank,
                    appKeyOf: appKeyOf,
                    headPreferredKeys: headPreferredKeys
                )
                result.insert(id, at: index)
                placements.append(Placement(chipID: id, index: index, reason: .stableKeptRank))
            } else {
                result.append(id)
                placements.append(Placement(chipID: id, index: result.count - 1, reason: .tail))
            }
        }
        return ReconcileResult(order: result, placements: placements)
    }

    /// Rank landing: after the last card whose rank is not behind mine; if there is none, before the first
    /// card ranked later;
    /// if no ranked card exists yet, after the head-preferred zone (= right of messaging pop-outs, left of
    /// ordinary transient windows).
    private static func stableKeptInsertIndex(
        in result: [String],
        myRank: Int,
        rank: (String) -> Int?,
        appKeyOf: [String: String],
        headPreferredKeys: Set<String>
    ) -> Int {
        if let pos = result.lastIndex(where: { rank($0).map { $0 <= myRank } ?? false }) {
            return pos + 1
        }
        if let pos = result.firstIndex(where: { rank($0).map { $0 > myRank } ?? false }) {
            return pos
        }
        let headEnd = result.lastIndex { appKeyOf[$0].map(headPreferredKeys.contains) ?? false }
        return headEnd.map { $0 + 1 } ?? 0
    }

    /// Applies one drag drop: moves `draggedID` to the left (`after == false`) or right (`after == true`)
    /// of `targetID`. If either id is missing from the sequence, or both are the same -> returned unchanged.
    static func reordering(_ order: [String], move draggedID: String, relativeTo targetID: String, after: Bool) -> [String] {
        guard draggedID != targetID, order.contains(draggedID), order.contains(targetID) else { return order }
        var result = order
        result.removeAll { $0 == draggedID }
        guard let t = result.firstIndex(of: targetID) else { return order }
        result.insert(draggedID, at: after ? t + 1 : t)
        return result
    }

    /// Block drop (drawer dragged back to the taskbar, exact landing): moves `ids` (keeping their given
    /// relative order) as a whole to the left (`after==false`) or right (`after==true`) of `targetID`;
    /// `targetID==nil` -> the block moves to the **end** (the append does not rely on
    /// reconcile's "new window sticks to siblings / end" rule, which is exactly what this feature overrides).
    /// Only ids **already in `order`** are moved (prevents duplicate
    /// insertion); `targetID` inside `ids` or not in `order` -> returned unchanged.
    static func movingBlock(_ order: [String], move ids: [String], relativeTo targetID: String?, after: Bool) -> [String] {
        let idSet = Set(ids)
        let block = ids.filter { order.contains($0) }
        guard !block.isEmpty else { return order }
        var result = order.filter { !idSet.contains($0) }
        if let targetID {
            guard !idSet.contains(targetID), let t = result.firstIndex(of: targetID) else { return order }
            result.insert(contentsOf: block, at: after ? t + 1 : t)
        } else {
            result.append(contentsOf: block)
        }
        return result
    }

    /// Replaces `oldID` with `newID`, **inheriting its position (rank)**. Used when an app-\* placeholder is
    /// upgraded to a real window, or a tab group anchor migrates because a member closed. `oldID` not in the
    /// sequence, or `newID` already in it (prevents duplicates) -> returned unchanged.
    static func substituting(_ order: [String], oldID: String, newID: String) -> [String] {
        guard order.contains(oldID), !order.contains(newID) else { return order }
        return order.map { $0 == oldID ? newID : $0 }
    }

    /// Persisted subset: keeps `tabgrp-*` (real window seat keys) + the `app-*` ids of kept apps (so the icon
    /// position survives a restart of that app).
    /// Ordinary app-* compatibility fallbacks are still not persisted. Since 2026-08-20 Finder is an ordinary
    /// kept app too: while kept,
    /// `app-com.apple.finder` is persisted as well (so it has position memory), and drops out once unchecked.
    /// Across reboots, `StripOrderStore`'s `kern.boottime` guard discards the whole file.
    static func persistableLiveOrder(_ order: [String], keptIDs: Set<String> = []) -> [String] {
        order.filter { id in
            if id.hasPrefix("tabgrp-") { return true }
            if id.hasPrefix("app-") {
                let bid = String(id.dropFirst(4))
                return keptIDs.contains(bid)
            }
            return false
        }
    }
}
