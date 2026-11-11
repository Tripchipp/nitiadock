import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// One slot in the strip: a concrete window chip, an app-level leading entry,
/// a pinned folder/shelf entry, or a zone divider.
enum StripEntry: Identifiable, Hashable {
    case window(StripItem)
    /// Constant app-icon chip for a pinned messaging app. Carries the main window's
    /// StripItem when it exists (the chip then *is* that window: toggle + full window
    /// menu); when the main window is gone, tap sends a reopen (Dock-icon-click
    /// equivalent) so the app recreates it, verified to work for WeChat even with
    /// other chat windows visible.
    case messagingApp(bundleID: String, mainWindow: StripItem?)
    /// "Keep in Dock" apps: window cards as usual while running; after quit they collapse to a single app
    /// icon in place. The id is always "app-\(bid)", the same string as the windowless fallback token of
    /// AppTracker rebuildSnapshot(); that is what keeps the live order continuous across the quit <->
    /// placeholder switch.
    case keptApp(bundleID: String)
    /// One cell of the pinned folder zone (right of the messaging zone, left of the window zone). The path is
    /// the identity.
    case pinnedFolder(path: String)
    /// Shelf: the staging cell fixed at the head of the folder zone (not draggable, always present; it also
    /// guarantees the folder zone is never empty, so "drag a directory in to pin it" has a drop zone before
    /// any folder has been pinned).
    case shelf
    case trash
    /// Visual separator between zones. At most two now (messaging|folders, folders|windows), so the id must
    /// be unique.
    case divider(id: String)
    /// The **gap** opened during hover when an app is dragged from Finder onto the bar (one card wide, draws
    /// nothing).
    ///
    /// Render-only: not in `liveOrderIDs` / `appKeyByChipID` (the order layer would keep an absence anchor
    /// for a remembered phantom id), not reported to `ChipFramePreferenceKey` (`chipFrames` is the input of
    /// the landing resolver `StripBlockLanding` itself; a gap in there would anchor on itself and jitter on
    /// every pointer move), no hover frame, no menu, no gestures. Injected in `makeProjection` **after** the
    /// order layer and the multi-display filter (same rule as the multi-display filter).
    ///
    /// No translucent icon copy is drawn: during a system drag macOS already draws the app's icon under the
    /// cursor, so another one would make two; the native Dock is likewise "system drag image + gap".
    case externalDropGhost(bundleID: String)

    var id: String {
        switch self {
        case let .window(item): return item.id
        // Stable id regardless of main-window presence, so the chip doesn't churn
        // when the main window opens/closes.
        case let .messagingApp(bid, _): return "msg-app-\(bid)"
        case let .keptApp(bid): return "app-\(bid)"
        case let .pinnedFolder(path): return "folder-\(path)"
        case .shelf: return "shelf"
        case .trash: return "trash"
        case let .divider(id): return id
        case let .externalDropGhost(bid): return "extghost-\(bid)"
        }
    }
}

struct StripProjection {
    let snapshotItems: [StripItem]
    let snapshotBundleIDs: Set<String>
    let hiddenBundleIDs: Set<String>
    let messaging: [StripEntry]
    let liveNatural: [StripEntry]
    let liveOrderIDs: [String]
    let appKeyByChipID: [String: String]
    /// Final label shown on each window card (app-name suffix and the group's common segment removed, issue
    /// #41). Computed from **the cards actually shown on this bar**, so it can only come from the projection
    /// layer, not from `StripItem`.
    let labelTitleByChipID: [String: String]
    let entries: [StripEntry]
    let layoutKeys: [StripLayoutKey]
    let messagingIDs: [String]
    let draggingID: String?
    /// Entry id of each app's **leftmost** card in the regular zone: the unread badge is drawn only on that
    /// one (one unread count must not become three red dots). Messaging zone members are not here: their
    /// badge is drawn on the zone's icon.
    let badgeEntryIDByBundle: [String: String]
    /// fork: entries that follow a window card of the same app (`ForkSameAppGap`); they get the
    /// "between an app's windows" gap in front of them.
    var sameAppFollowerIDs: Set<String> = []
    /// fork: apps shown on this bar only as the one icon of their windows on another display
    /// (`ForkForeignWindowCollapse`). Their icon carries no running dot here.
    var collapsedIconBundleIDs: Set<String> = []

    func hasRealWindow(bundleID: String) -> Bool {
        snapshotItems.contains {
            $0.bundleIdentifier == bundleID && !$0.isAppLevelFallback
        }
    }

    func item(forID id: String) -> StripItem? {
        guard let entry = liveNatural.first(where: { $0.id == id }),
              case let .window(item) = entry else { return nil }
        return item
    }

    func liveChipIDs(bundleID: String) -> [String] {
        entries.compactMap { entry -> String? in
            guard case let .window(item) = entry,
                  item.bundleIdentifier == bundleID,
                  !item.isAppLevelFallback else { return nil }
            return item.id
        }
    }

    /// **All cards** of this app that occupy a position in the live zone, in display order, **including the
    /// app-level fallback card and the `.keptApp` placeholder**.
    ///
    /// Not the same measure as `liveChipIDs`, do not merge them: that one answers "which window card should
    /// the carrier draw", this one answers "which cards on the bar must make room". Fallback and placeholder
    /// cards cannot be drawn as a carrier, but they do occupy a cell. Earlier both questions shared the
    /// former measure, and the `keepPlacement` path never made room (double image, 2026-08-18).
    func liveEntryIDs(bundleID: String) -> [String] {
        entries.compactMap { entry -> String? in
            switch entry {
            case let .window(item):
                return item.bundleIdentifier == bundleID ? item.id : nil
            case let .keptApp(bid):
                return bid == bundleID ? entry.id : nil
            default:
                return nil
            }
        }
    }
}

// MARK: - Messaging zone diagnostics

/// Permanent abnormal-path diagnostic (like `[tabfold]`: zero output on the normal path of a single,
/// recognized window): when a messaging zone member has **no recognizable main window**, or has **more than
/// one real window** (then "which one was picked" is itself the question), log one line with each of the
/// app's windows (id + raw title), the main window picked and the spellings the name table recognizes at that
/// moment. Deduplicated by signature: the same set of windows + the same conclusion is logged once, and again
/// only when it changes. Uses `Logger`, not `print`: stdout of a build started with `open` is discarded,
/// while `log show --predicate 'category == "MessagingZone"'` can be read afterwards at any time (only notice
/// level and above is persisted).
///
/// Added 2026-08-23: with "WeChat has one card in the messaging zone and one in the regular zone" reported
/// and the debug console window half off-screen, three rounds of questions could not settle whether "the
/// title is not WeChat" or "the name table did not recognize WeChat"; this line answers it on the spot.
enum MessagingZoneDiagnostics {
    private static let logger = Logger(subsystem: "no.thilip.nitiadock", category: "MessagingZone")
    private static let lock = NSLock()
    private static var lastSignatureByBundle: [String: String] = [:]

    static func record(bundleID: String, windows: [StripItem], mainID: String?) {
        let described = windows.map { "\($0.id):\($0.title.isEmpty ? "<empty>" : $0.title)" }
        let signature = described.joined(separator: "|") + "→" + (mainID ?? "none")
        lock.lock()
        let unchanged = lastSignatureByBundle[bundleID] == signature
        if !unchanged { lastSignatureByBundle[bundleID] = signature }
        lock.unlock()
        guard !unchanged else { return }
        let known = AppDisplayNameResolver.knownAppNames(for: bundleID).sorted().joined(separator: ", ")
        // notice rather than info: info is not persisted by default, so `log show` cannot read it afterwards
        // (only `log stream` sees it live).
        logger.notice("[msgmain] bid=\(bundleID, privacy: .public) windows=[\(described.joined(separator: ", "), privacy: .public)] known=[\(known, privacy: .public)] main=\(mainID ?? "none", privacy: .public)")
    }
}

// MARK: - Layout Animation Key

struct StripLayoutKey: Equatable {
    let id: String
    let form: Form

    enum Form: Equatable { case zero, single, multi, launcher }

    init(_ entry: StripEntry) {
        id = entry.id
        switch entry {
        case let .window(item):
            if item.isAppLevelFallback { form = .zero }
            else if item.showsTitle    { form = .multi }
            else                        { form = .single }
        case .messagingApp:
            form = .launcher    // both states render as a fixed-size icon chip
        case .keptApp:
            form = .launcher    // fixed-size kept-app icon chip
        case .pinnedFolder:
            form = .launcher    // fixed-size folder chip
        case .shelf, .trash:
            form = .launcher    // fixed-size shelf chip
        case .divider:
            form = .launcher    // fixed-size separator, no animation form change
        case .externalDropGhost:
            form = .launcher    // one card wide, same shape as the kept placeholder
        }
    }
}
