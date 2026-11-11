import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// DockStripView · Projection building: one StripProjection per body evaluation (performance rule), label
// dedup, appKey.
// Split out of DockStripView.swift as an extension on 2026-09-05, moved without changes.
extension DockStripView {
    /// Pinned messaging zone (leftmost, in store order) + live window zone, in **natural**
    /// snapshot order. Messaging apps show only while running (quit → chip gone; the future
    /// drawer's pending-launch zone takes over the not-running role). Drawer membership hides a messaging
    /// app from the strip without clearing its messaging flag.
    ///
    /// Plan B: each messaging app pins exactly ONE app-level chip. Its main window
    /// (title matches the app name) is absorbed into that chip; pop-out windows
    /// (chat windows etc.) flow through the live zone as normal window chips so the
    /// pinned zone keeps a stable width (muscle memory).
    ///
    /// Split out so the live zone can be reordered by `stripOrderStore` (taskbar drag reorder,
    /// route A) while the pinned messaging zone keeps its own `MessagingAppStore` order,
    /// the two zones never cross (drags stay within their zone).
    func makeProjection() -> StripProjection {
        // This is the only snapshot-to-strip conversion in one body evaluation. Everything below,
        // including drag callbacks captured by that body, consumes the same immutable projection.
        // The Trash chip stands in for Finder's Trash window, so that window gets no card of its own.
        let stripSnapshot = settingsStore.showTrash
            ? TrashWindowAbsorption.removing(
                TrashWindowAbsorption.absorbedWindowIDs(in: runtime.snapshot, trashTitles: TrashWindowLookup.liveTitles),
                from: runtime.snapshot)
            : runtime.snapshot
        let snapshotItems = StripItem.items(from: stripSnapshot)
        let snapshotBundleIDs = Set(snapshotItems.compactMap(\.bundleIdentifier))
        let hiddenBundleIDs = Set(snapshotItems.compactMap { item in
            item.status == "hidden" ? item.bundleIdentifier : nil
        })
        let keptIDs = keptAppStore.bundleIDs
        let runningIDs = runningApplicationStore.runningBundleIDs
        // Unified model: message zone visible = (messaging − drawer) ∩ (running ∪ kept). Messaging identity
        // no longer keeps itself alive;
        // kept decides whether it stays after quit (the first mark also adds kept, so the default look is
        // unchanged); the drawer exception still hides it (the drawer has higher priority).
        let msg = AppMembershipProjection.visibleMessagingIDs(
            messagingIDs: messagingStore.bundleIDs,
            drawerIDs: drawerStore.bundleIDs,
            keptIDs: keptIDs,
            runningIDs: runningIDs
        )
        let msgSet = Set(msg)
        // Finder's app-level entry (the card shown with no windows) only appears when "Keep in Dock" is
        // checked (2026-08-20).
        // The tracking layer still always follows Finder, so after unchecking, opening a window brings the
        // window card back instantly.
        let showsFinderEntry = FinderTaskbarPolicy.showsAppLevelEntry(
            isKept: keptAppStore.contains(FinderTaskbarPolicy.bundleID)
        )
        let items = snapshotItems.filter { item in
            let bid = item.bundleIdentifier ?? ""
            if drawerStore.contains(bid) { return false }
            if item.isAppLevelFallback, FinderTaskbarPolicy.isFinder(bid), !showsFinderEntry { return false }
            // fork: an app that went back to being a background (accessory) app keeps no icon.
            if !ForkFallbackVisibility.shows(isAppLevelFallback: item.isAppLevelFallback,
                                             bundleID: item.bundleIdentifier,
                                             runningRegularBundleIDs: runningIDs) { return false }
            return true
        }

        var messaging: [StripEntry] = []
        var absorbedWindowIDs = Set<String>()
        for bid in msg {
            let appWindows = items.filter { $0.bundleIdentifier == bid && !$0.isAppLevelFallback }
            // The three rules for identifying the main window live in the pure `MessagingMainWindowDecision`
            // (title match -> unique after exclusion -> unidentified);
            // this only feeds in the window facts.
            let mainID = MessagingMainWindowDecision.mainWindowID(
                bundleID: bid,
                windows: appWindows.map {
                    .init(id: $0.id, title: $0.title,
                          isMinimized: $0.status == WindowStatus.minimized.rawValue,
                          area: ($0.bounds?.width ?? 0) * ($0.bounds?.height ?? 0))
                },
                titleMatchesAppName: { AppDisplayNameResolver.titleMatchesAppName($0, bundleID: bid) }
            )
            let main = appWindows.first { $0.id == mainID }
            if let main { absorbedWindowIDs.insert(main.id) }
            if main == nil || appWindows.count > 1 {
                MessagingZoneDiagnostics.record(bundleID: bid, windows: appWindows, mainID: main?.id)
            }
            messaging.append(.messagingApp(bundleID: bid, mainWindow: main))
        }

        // Live zone: real windows (including kept app windows) + kept app placeholders
        var liveNatural: [StripEntry] = []
        for item in items {
            guard !msgSet.contains(item.bundleIdentifier ?? "") else {
                if item.isAppLevelFallback { continue }     // app chip replaces the app-* fallback
                if absorbedWindowIDs.contains(item.id) { continue }
                liveNatural.append(.window(item))
                continue
            }
            liveNatural.append(.window(item))
        }

        // Kept app placeholders (D1 two sources):
        // a. Unrunning: not in snapshot → inject placeholder
        // b. Running but only isAppLevelFallback → replace the fallback .window with .keptApp
        // Placeholders are inserted at the **head** of liveNatural (in kept store order): in normal operation
        // the order is decided by the memory layer,
        // and array position only affects where "new ids with no memory" land, i.e. placeholders land at the
        // head of the live zone after a cross-machine restart (boottime loses the record).
        let snapshotByBundle = Dictionary(grouping: snapshotItems, by: { $0.bundleIdentifier ?? "" })
        var keptPlaceholders: [StripEntry] = []
        for bid in keptIDs {
            guard !drawerStore.contains(bid),
                  !msgSet.contains(bid) else { continue }
            // Finder deliberately stays on the `.window` fallback card path: it carries its own menu
            // (recently used folders /
            // new window) and "click opens the home folder", all of which a .keptApp LauncherChip would lose.
            // For Finder, kept is only the visibility gate above.
            if FinderTaskbarPolicy.isFinder(bid) { continue }
            let appItems = snapshotByBundle[bid] ?? []
            let hasRealWindow = appItems.contains { !$0.isAppLevelFallback }
            if hasRealWindow { continue }  // Real windows render normally, no placeholder
            if !appItems.isEmpty {
                // Source b: replace fallback .window with .keptApp (same id "app-\(bid)")
                liveNatural.removeAll { entry in
                    if case let .window(item) = entry, item.bundleIdentifier == bid, item.isAppLevelFallback {
                        return true
                    }
                    return false
                }
            }
            // Both sources inject .keptApp with id "app-\(bid)"
            keptPlaceholders.append(.keptApp(bundleID: bid))
        }
        let projectedLive = keptPlaceholders + liveNatural
        let liveOrderIDs = projectedLive.map(\.id)
        let appKeys = Self.appKeys(of: projectedLive)
        let order = stripOrderStore.reconciled(
            current: liveOrderIDs,
            appKeyOf: appKeys,
            headPreferred: Set(messagingStore.bundleIDs)
        )
        let byID = Dictionary(projectedLive.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let orderedLive = order.compactMap { byID[$0] }
        if HoverTrace.isEnabled, dragController.carriedPayload != nil {
            HoverTrace.liveOrder(orderedLive.map(\.id))
        }
        // Multi-display ④: per-display filtering happens **only here, only after the order layer**. The
        // `liveOrderIDs` fed to `reconciled` above and
        // what `reconcileLiveOrder` feeds to `sync` are both the full set, identical on every display, so the
        // shared order layer doesn't mark other displays' cards
        // absent (evicted from memory after 5s) and drag reorder isn't truncated mid-frame. Launcher kinds
        // (kept placeholders, `app-*` fallback cards,
        // message zone, folders, shelf) are on every display; ownership unknown / its display unplugged ->
        // main display only.
        let displayFilter: StripDisplayFilter = {
            guard settingsStore.taskbarScreenPlacement == .allScreensPerDisplay, let displayUUID else {
                return .unfiltered
            }
            let table = displayTopologyStore.table
            return StripDisplayFilter(scope: displayUUID, connectedUUIDs: table.connectedUUIDs,
                                      primaryUUID: table.primaryUUID)
        }()
        // Under ④ the window card being dragged / flying home is drawn on the bar that **claimed** it (when
        // the pointer hovers bar B, B takes over, B opens an empty slot and
        // A closes up), regardless of the ownership key, which only changes after release once the window has
        // been moved.
        let carriedStripID = dragController.carriedPayload.flatMap { $0.source == .strip ? $0.id : nil }
        let claimedStrip = dragController.activeStripSurfaceID
        // fork: windows on another display become one app icon on this bar (after the order layer, like
        // the display filter). `collapsedIconBundleIDs` marks the injected icons so the filter below
        // lets them through on this bar whatever the app's "home" display is.
        let collapseFilter: StripDisplayFilter? = {
            guard settingsStore.collapseForeignWindows,
                  settingsStore.taskbarScreenPlacement.showsOnEveryDisplay,
                  let displayUUID else { return nil }
            let table = displayTopologyStore.table
            return StripDisplayFilter(scope: displayUUID, connectedUUIDs: table.connectedUUIDs,
                                      primaryUUID: table.primaryUUID)
        }()
        var collapsedIconBundleIDs: Set<String> = []
        let displayedLive: [StripEntry] = {
            guard let collapseFilter else { return orderedLive }
            let items = orderedLive.map { entry -> ForkForeignWindowCollapse.Item in
                if case let .window(item) = entry, !item.isAppLevelFallback {
                    return .init(bundleID: item.bundleIdentifier, displayUUID: item.displayUUID,
                                 isRealWindow: true, isExempt: msgSet.contains(item.bundleIdentifier ?? ""))
                }
                return .init(bundleID: nil, displayUUID: nil, isRealWindow: false, isExempt: false)
            }
            let outcomes = ForkForeignWindowCollapse.outcomes(
                for: items, isLocal: { collapseFilter.shows(.window(displayUUID: $0)) })
            var next: [StripEntry] = []
            for (entry, outcome) in zip(orderedLive, outcomes) {
                switch outcome {
                case .keep: next.append(entry)
                case .drop: continue
                case .icon:
                    guard case let .window(item) = entry, let bid = item.bundleIdentifier else { continue }
                    collapsedIconBundleIDs.insert(bid)
                    next.append(.keptApp(bundleID: bid))
                }
            }
            // A kept placeholder exists only for apps without real windows and the icon only for apps
            // with them, so ids cannot clash today; SwiftUI's ForEach would misbehave if they ever did.
            var seenIDs = Set<String>()
            return next.filter { seenIDs.insert($0.id).inserted }
        }()
        // Entries with a running dot but no window (app-level fallback cards, kept apps that are running but
        // only have a placeholder) land on the main display only;
        // non-running placeholders are pure launchers and are on every display (2026-09-02: a dot = on one
        // bar only).
        let renderedLive = displayedLive.filter { entry in
            if case let .keptApp(bid) = entry, collapsedIconBundleIDs.contains(bid) { return true }   // fork
            let subject: StripDisplayFilter.Subject
            switch entry {
            case let .window(item):
                subject = item.isAppLevelFallback
                    ? .runningWithoutWindow(displayUUID: runtime.noWindowHomeByBundle[item.bundleIdentifier ?? ""]
                                                         ?? item.displayUUID)
                    : .window(displayUUID: item.displayUUID)
            case let .keptApp(bid):
                subject = runningIDs.contains(bid)
                    ? .runningWithoutWindow(displayUUID: runtime.noWindowHomeByBundle[bid]
                                                         ?? snapshotByBundle[bid]?.first?.displayUUID)
                    : .launcher
            default:
                return true
            }
            // The card being dragged / flying home is drawn by claim (launcher kinds are on every display, no
            // change needed).
            if displayFilter.scope != nil, subject != .launcher, entry.id == carriedStripID, let claimedStrip {
                return claimedStrip == stripSurfaceID
            }
            return displayFilter.shows(subject)
        }
        // Card labels: the segment shared by one app's cards doesn't help tell them apart, so it is removed
        // (issue #41).
        //
        // **Grouped by "the cards actually shown on this bar"**, hence computed after `renderedLive` is
        // settled: under ④ each display
        // shows only its own windows and the common segment differs per display; computing over the full set
        // would strip the only distinguishing information from a display's single remaining card.
        // It also **must come before the "close up on drag-out" removal**: dragging a card away would make
        // the remaining cards recompute the common segment, labels would grow on the spot,
        // and the text would jump mid-drag.
        let labelTitleByChipID = Self.labelTitles(for: renderedLive)
        // Make-room gap (hover preview when dragging an app in from Finder). **The injection point must be
        // here**: the order layer
        // (`stripOrderStore.reconciled`) and multi-display filtering have both run, so the gap can't get into
        // `liveOrderIDs`
        // or `appKeys`; once the order layer remembers this ghost id, it keeps reserving a spot for it via
        // the 5s absence anchor after it is gone.
        // Same rule as multi-display filtering: only touch the render array after the order layer.
        let liveWithGhost: [StripEntry] = {
            guard let ghost = externalDropGhost else { return renderedLive }
            // The index was computed from last frame's card frames, and this frame the live zone may already
            // have one card fewer (app quit / display filter change),
            // so it must be clamped: an out-of-range `insert(at:)` crashes outright.
            let index = min(max(ghost.insertIndex, 0), renderedLive.count)
            var next = renderedLive
            next.insert(.externalDropGhost(bundleID: ghost.bundleID), at: index)
            return next
        }()
        let folderEntries = (settingsStore.showShelf ? [StripEntry.shelf] : [])
            + pinnedFolderStore.folderPaths.map { StripEntry.pinnedFolder(path: $0) }
        // Close up on drag-out (2026-09-03): the card whose drag started on the bar has left the bar ->
        // removed from rendering (not made transparent),
        // the HStack closes up with a spring and the panel shortens (`PanelCoordinator` subscribes to
        // `stripSlotCollapsed`). **Removed from the render array only**:
        // `liveOrderIDs` / `messagingIDs`, which feed the order layer and in-zone decisions, stay the full
        // set; a differing subset would make the order layer mark it absent
        // (rank lost after the 5s grace), and the message zone's "member disappeared -> cancel drag" listener
        // must not be tripped by it either. Only the claiming bar removes it.
        let collapsedEntryID: String? = {
            guard ownsActiveDrag, dragController.stripSlotCollapsed,
                  let p = dragController.hiddenSlotPayload else { return nil }
            if p.source == .folder { return StripEntry.pinnedFolder(path: p.id).id }
            return Self.stripEntryID(for: p)
        }()
        var zones = [messaging, folderEntries, liveWithGhost, settingsStore.showTrash ? [.trash] : []]
            .map { zone in zone.filter { $0.id != collapsedEntryID } }
            .filter { !$0.isEmpty }
        var entries: [StripEntry] = []
        if !zones.isEmpty {
            entries = zones.removeFirst()
            for (index, zone) in zones.enumerated() {
                let dividerID = zone.first?.id == "trash" ? "zone-divider-trash" : "zone-divider-\(index)"
                entries.append(.divider(id: dividerID))
                entries += zone
            }
        }
        let messagingIDs = messaging.compactMap { entry -> String? in
            guard case let .messagingApp(bundleID, _) = entry else { return nil }
            return bundleID
        }
        // Badge placement: in the regular zone, each app's leftmost window card / placeholder card in display
        // order. Message-zone members are skipped:
        // their red dot is on the icon in the zone, and a standalone chat window's card must not draw another.
        var badgeEntryIDByBundle: [String: String] = [:]
        for entry in entries {
            switch entry {
            case let .window(item):
                guard let bid = item.bundleIdentifier, !msgSet.contains(bid) else { continue }
                if badgeEntryIDByBundle[bid] == nil { badgeEntryIDByBundle[bid] = item.id }
            case let .keptApp(bid):
                guard !msgSet.contains(bid) else { continue }
                if badgeEntryIDByBundle[bid] == nil { badgeEntryIDByBundle[bid] = entry.id }
            default:
                continue
            }
        }
        let draggingID: String?
        // `carriedPayload` rather than `draggingPayload`: after release there is still a 0.26s flight home,
        // during which the original position must stay empty, otherwise the card reappears while the carrier
        // is still flying.
        // **Only the dragging strip gets the empty slot** (under multi-display ③④ the same card on other
        // displays shows normally and moves with the shared order layer;
        // 2026-09-02: the corresponding icon disappeared on the other display).
        if !ownsActiveDrag {
            draggingID = nil
        } else if let payload = dragController.hiddenSlotPayload,
           payload.source == .strip,
           liveOrderIDs.contains(payload.id) {
            draggingID = payload.id
        } else if let converted = dragController.convertedChipID,
                  liveOrderIDs.contains(converted) {
            // **Match by chip id, not by representative card**: the `keepPlacement` path materializes a
            // `.keptApp` placeholder or
            // an app-level fallback card, neither of which can be a `StripItem` representative card, so
            // following the representative card would never make room (double image).
            draggingID = converted
        } else if let bid = dragController.convertedDrawerBundleID,
                  let materialized = entries.lazy.compactMap({ entry -> String? in
                      switch entry {
                      case let .window(item): return item.bundleIdentifier == bid ? item.id : nil
                      case let .keptApp(id): return id == bid ? entry.id : nil
                      default: return nil
                      }
                  }).first(where: { liveOrderIDs.contains($0) }) {
            // At the moment of conversion `convertedChipID` is still nil: it is written in
            // `syncConvertedCarrier`, **after** this render pass.
            // Matching only on it, the freshly materialized card is first inserted into the bar at opacity
            // 1.0 and hidden only on the next pass; SwiftUI fades the insertion in and
            // the hiding out, which shows as "a very faint icon sliding from the end to the landing spot"
            // (2026-09-04; only exposed once the icon cache was fixed and
            // reappearing got faster). Derive the card to hide directly from the conversion state (same rule
            // as `liveEntryIDs(bundleID:).first`,
            // guaranteeing it is the same card as the `convertedChipID` written afterwards), effective in the
            // same pass as the insertion.
            draggingID = materialized
        } else {
            draggingID = nil
        }
        return StripProjection(
            snapshotItems: snapshotItems,
            snapshotBundleIDs: snapshotBundleIDs,
            hiddenBundleIDs: hiddenBundleIDs,
            messaging: messaging,
            liveNatural: projectedLive,
            liveOrderIDs: liveOrderIDs,
            appKeyByChipID: appKeys,
            labelTitleByChipID: labelTitleByChipID,
            entries: entries,
            layoutKeys: entries.map(StripLayoutKey.init),
            messagingIDs: messagingIDs,
            draggingID: draggingID,
            badgeEntryIDByBundle: badgeEntryIDByBundle,
            sameAppFollowerIDs: ForkSameAppGap.followerIDs(in: entries.map { entry in   // fork
                if case let .window(item) = entry, !item.isAppLevelFallback {
                    return .init(id: entry.id, windowBundleID: item.bundleIdentifier)
                }
                return .init(id: entry.id, windowBundleID: nil)
            }),
            collapsedIconBundleIDs: collapsedIconBundleIDs   // fork
        )
    }

    /// The label finally shown on each window card: first drop the trailing app name, then the common segment
    /// shared by one app's cards.
    ///
    /// Both steps must stay: under ④ a bar may have only one card left for an app (`showsTitle` is still true
    /// and the title still shows),
    /// with no sibling to compare a common segment against, so only the app-name step takes effect.
    private static func labelTitles(for entries: [StripEntry]) -> [String: String] {
        var itemsByApp: [String: [(id: String, title: String)]] = [:]
        for case let .window(item) in entries {
            let appName = item.bundleIdentifier.map(AppDisplayNameResolver.displayName(for:)) ?? item.appID
            let resolved = WindowDisplayTitle.resolve(rawTitle: item.title, fallbackName: appName)
            let withoutApp = WindowDisplayTitle.trimmingAppNameSuffix(resolved, appName: appName)
            itemsByApp[item.bundleIdentifier ?? item.appID, default: []].append((item.id, withoutApp))
        }

        var labels: [String: String] = [:]
        for (_, group) in itemsByApp {
            let trimmed = StripSharedAffixTrim.trimmingSharedAffixes(group.map(\.title))
            for (entry, label) in zip(group, trimmed) { labels[entry.id] = label }
        }
        return labels
    }

    /// **`onChange` closures must use this, not the `projection` captured by the closure.**
    ///
    /// When the old-style `onChange(of:perform:)` fires it runs the closure installed on the **previous
    /// frame**, whose projection
    /// is therefore always one generation behind. Usually harmless (the next change catches up), but fatal at
    /// the moment of drawer conversion
    /// (measured 2026-08-18: 12 cards already rendered, `sync` still received 11, without the placeholder
    /// that had just appeared):
    ///
    /// 1. in `sync`, `next.contains("app-<bid>")` is false -> **the staged landing is never consumed**;
    /// 2. the remembered order `liveOrder` therefore never has this id -> the `movingBlock` of later
    ///    `reorderBlock` calls
    ///    can't find the id to move and **returns unchanged every time** (the five `ok` in the log were all
    ///    no-ops);
    /// 3. rendering can only fall back to the stable kept rank from `reconciled`, pinning it at a fixed
    ///    position unrelated to the cursor.
    ///
    /// That is the reported "hard to trigger pushing the other icons aside". Rebuilding a projection here is
    /// an acceptable cost:
    /// it only fires when the set of live-zone cards really changed, not per frame and certainly not per
    /// mouse move.
    /// (The "one projection per body" project rule covers the **render path**; this is a side-effect path.)
    func freshProjection() -> StripProjection { makeProjection() }

    /// The render path (`reconciled`) and the side-effect path (`sync`) **must be fed the same appKeyOf**,
    /// otherwise the persisted remembered order
    /// diverges from the display order. Extracted into one function so the two paths can't drift apart.
    static func appKeys(of liveNatural: [StripEntry]) -> [String: String] {
        Dictionary(liveNatural.map { entry -> (String, String) in
            switch entry {
            case let .window(item): return (entry.id, item.bundleIdentifier ?? item.appID)
            case let .keptApp(bid): return (entry.id, bid)
            default: return (entry.id, entry.id)
            }
        }, uniquingKeysWith: { first, _ in first })
    }
}
