import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// System drag-and-drop endpoint for external files dragged into the taskbar. Routing geometry = the pure
/// function `StripDropRouting.route`; this delegate only publishes the target to the view for highlighting
/// during hover, and after release gathers the URLs asynchronously and commits on the main thread. The mount
/// point must be at the same level as the "strip" coordinateSpace (same coordinate origin, settled in
/// review).
///
/// **App bundles and ordinary files are separated right here**: `.app` only goes through
/// `onCommitApplications`, so `onCommit` (`handleExternalDrop`) can never receive an app. That is the second
/// reason this file exists, and one of the two gates against the bug "dragging an app onto a folder cell
/// moves it out of Applications".
struct StripFileDropDelegate: DropDelegate {
    /// nil = the shelf was turned off by the user (not "frame not measured yet", which still passes `.zero`).
    let shelfFrame: CGRect?
    let trashFrame: CGRect?
    let folderFrames: [String: CGRect]
    let orderedPaths: [String]
    var headSlack: CGFloat = StripDropRouting.defaultHeadSlack
    /// dropEntered = hover session starts; dropUpdated = movement during the session; performDrop/dropExited
    /// = session ends. The view side builds "highlight can only be lit by dropEntered + a drop-end watchdog"
    /// on this (see externalDropHover*).
    let onHoverBegan: (StripDropRouting.Target) -> Void
    let onHoverMoved: (StripDropRouting.Target) -> Void
    /// Parameter = "is this branch a landing". Only `performDrop` passes `true` (the gap is kept for the
    /// landing handoff).
    let onHoverEnded: (Bool) -> Void
    let onCommit: (StripDropRouting.Target, [URL]) -> Void
    /// The dragged-in app bundles + landing x ("strip" space). See `handleExternalApplicationDrop`.
    let onCommitApplications: ([URL], CGPoint) -> Void
    /// The make-room gap during hover: (bundleID, landing point) when an app is being dragged, otherwise
    /// `nil` (close the gap). The view side folds it into an anchor and gates on change: **this is called
    /// every ~50ms**.
    let onGhostMoved: (String?, CGPoint) -> Void
    /// Temporary diagnostics: the index where the gap is inserted right now (nil = no gap), the frozen bar
    /// width, and the bar's actual screen rect. The last two verify "did the width freeze actually take
    /// effect". Delete once the "plus-sign flicker" is understood.
    let currentGhostIndex: () -> Int?
    let currentFrozenWidth: () -> CGFloat?
    let currentStripRect: () -> CGRect

    /// The target the latest hover callback resolved, read by `StripDropBadgeOverlay` right after it
    /// forwards the same callback. Main thread only. An orphan `dropUpdated` after a drop can leave it
    /// set: harmless, since only a `.copy` answer is rewritten and the next `dropEntered` overwrites it.
    static var hoveredTarget: StripDropRouting.Target?

    /// Target during hover (decides highlight and cursor). Apps are always `.keepApp`.
    private func route(_ info: DropInfo) -> StripDropRouting.Target {
        route(info, isApplicationDrag: DragPasteboardInspector.containsApplication())
    }

    /// Target for the non-app half: in a mixed drag, apps are kept and the rest still follow file semantics,
    /// so it is computed separately.
    private func fileRoute(_ info: DropInfo) -> StripDropRouting.Target {
        route(info, isApplicationDrag: false)
    }

    private func route(_ info: DropInfo, isApplicationDrag: Bool) -> StripDropRouting.Target {
        StripDropRouting.route(location: info.location,
                               isApplicationDrag: isApplicationDrag,
                               isTrashItemDrag: DragPasteboardInspector.containsOnlyTrashItems(),
                               shelfFrame: shelfFrame,
                               trashFrame: trashFrame,
                               folderFrames: folderFrames,
                               orderedPaths: orderedPaths,
                               headSlack: headSlack)
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.fileURL])
    }

    func dropEntered(info: DropInfo) {
        let target = route(info)
        Self.hoveredTarget = target
        trace("entered", info, target: target)
        onHoverBegan(target)
        onGhostMoved(DragPasteboardInspector.applicationBundleID(), info.location)
    }

    /// Stays `.copy` over the Trash too: the badge-free answer is `StripDropBadgeOverlay`'s.
    func dropUpdated(info: DropInfo) -> DropProposal? {
        let target = route(info)
        Self.hoveredTarget = target
        trace("updated", info, target: target)
        onHoverMoved(target)
        onGhostMoved(DragPasteboardInspector.applicationBundleID(), info.location)
        return DropProposal(operation: target == .none ? .forbidden : .copy)
    }

    func dropExited(info: DropInfo) {
        Self.hoveredTarget = nil
        trace("exited", info, target: route(info))
        onHoverEnded(false)   // no landing to hand off -> close the gap right away
    }

    /// Temporary diagnostics (2026-09-08 "the plus sign keeps flickering"). Delete together with
    /// `HoverTrace.externalDrop` once understood.
    private func trace(_ phase: String, _ info: DropInfo, target: StripDropRouting.Target) {
        guard HoverTrace.isEnabled else { return }
        HoverTrace.externalDrop(phase: phase,
                                x: info.location.x,
                                isApp: DragPasteboardInspector.containsApplication(),
                                target: "\(target)",
                                fileTarget: "\(fileRoute(info))",
                                operation: target == .none ? "forbidden" : "copy",
                                ghostIndex: currentGhostIndex(),
                                frozenWidth: currentFrozenWidth(),
                                stripRect: currentStripRect())
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = route(info)
        let fileTarget = fileRoute(info)
        let location = info.location
        Self.hoveredTarget = nil
        trace("perform", info, target: target)
        // The highlight goes out on landing and is cleared synchronously (the system may still send a stray
        // dropUpdated afterwards, which the gate ignores). Passes true: the gap must stay until the real icon
        // enters the projection, and is closed by `keepDroppedApplications` (plus a fallback Timer).
        onHoverEnded(true)
        guard target != .none else { return false }
        let providers = info.itemProviders(for: [UTType.fileURL])
        guard !providers.isEmpty else { return false }

        // Gather all URLs asynchronously, keep provider order, and commit once on the main thread.
        let group = DispatchGroup()
        let box = ResultBox(count: providers.count)
        for (index, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                box.set(url, at: index)
                group.leave()
            }
        }
        group.notify(queue: .main) {
            // Second gate for Trash items (the first is the hover route): filtered before the app
            // split, so a Trash `.app` cannot reach the keep path either.
            let urls = box.urls.compactMap { $0 }.filter { !DragPasteboardInspector.isInsideTrash($0) }
            guard !urls.isEmpty else { return }
            // At landing, app identity is checked again against the **real URLs** (hover reads the drag
            // pasteboard, only to decide highlight and cursor). The split is hard: `onCommit` never receives
            // an app.
            let applications = urls.filter(DragPasteboardInspector.isApplication)
            let files = urls.filter { !DragPasteboardInspector.isApplication($0) }
            if !applications.isEmpty {
                onCommitApplications(applications, location)
            }
            if !files.isEmpty, fileTarget != .none {
                onCommit(fileTarget, files)
            }
        }
        return true
    }

    /// Drag pasteboard quick lookup: answers "is this drag an app" **synchronously** during hover.
    ///
    /// It must be synchronous: when `dropUpdated` returns `.forbidden` the system never calls `performDrop`,
    /// and an app's landing area covers the whole bar (including the window zone, which is `.none` for
    /// files). Fetching URLs asynchronously with `itemProviders` would mean "drag from Finder straight to the
    /// window zone and release" is rejected before the URL arrives. `NSPasteboard(name: .drag)` is
    /// synchronously readable by the target process during a drag session, which fills exactly this gap.
    ///
    /// `dropUpdated` arrives every ~50ms, so the result is cached by `changeCount`: one disk read per drag
    /// session.
    enum DragPasteboardInspector {
        private struct Session {
            let changeCount: Int
            /// Every dragged URL is inside a Trash: the whole drop is refused.
            let containsOnlyTrashItems: Bool
            let containsApplication: Bool
            /// id of the first app bundle. **Parsing Info.plist is a disk read**, so it is done once per drag
            /// session: `dropUpdated` fires every ~50ms, and a disk read each time would drag down the main
            /// thread.
            let applicationBundleID: String?
        }
        private static var session: Session?

        /// Whether the drag pasteboard holds an app bundle. Unreadable (empty pasteboard / not a file drag)
        /// is always false: the existing file semantics are kept, and the real URLs are checked again at
        /// landing. Called on the main thread only (DropDelegate callbacks are all on the main thread), so
        /// the cache takes no lock.
        static func containsApplication() -> Bool {
            currentSession().containsApplication
        }

        /// Who the make-room gap is shown for. `nil` = not an app drag, or the bundle is broken and its id
        /// cannot be read -> no gap.
        static func applicationBundleID() -> String? {
            currentSession().applicationBundleID
        }

        static func containsOnlyTrashItems() -> Bool {
            currentSession().containsOnlyTrashItems
        }

        /// Path components only: nothing inside the Trash is read.
        static func isInsideTrash(_ url: URL) -> Bool {
            TrashPath.isInsideTrash(url, homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        }

        private static var volumeAnswer: (changeCount: Int, path: String, staysOnVolume: Bool)?

        /// Whether dropping the dragged files into `path` moves them (same volume) instead of
        /// copying them (`FileMover` copies across volumes and keeps the source). Decided from the
        /// first dragged file and cached per drag and folder, because it is asked on every mouse move.
        static func movesWithinVolume(into path: String) -> Bool {
            let pasteboard = NSPasteboard(name: .drag)
            let changeCount = pasteboard.changeCount
            if let volumeAnswer, volumeAnswer.changeCount == changeCount, volumeAnswer.path == path {
                return volumeAnswer.staysOnVolume
            }
            func volume(_ url: URL) -> URL? {
                (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume?.standardizedFileURL
            }
            let dragged = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
            let source = dragged.first { !isInsideTrash($0) }.flatMap(volume)
            let destination = volume(URL(fileURLWithPath: path, isDirectory: true))
            let answer = source != nil && source == destination
            volumeAnswer = (changeCount, path, answer)
            return answer
        }

        private static func currentSession() -> Session {
            let pasteboard = NSPasteboard(name: .drag)
            let changeCount = pasteboard.changeCount
            if let session, session.changeCount == changeCount { return session }
            let dragged = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
            // Trash items are filtered before the app check: a mixed drag keeps only the rest.
            let urls = dragged.filter { !isInsideTrash($0) }
            let apps = urls.filter(isApplication)
            let next = Session(
                changeCount: changeCount,
                containsOnlyTrashItems: !dragged.isEmpty && urls.isEmpty,
                containsApplication: !apps.isEmpty,
                applicationBundleID: apps.first.flatMap { Bundle(url: $0)?.bundleIdentifier }
            )
            session = next
            return next
        }

        /// Whether it is an app bundle. Asks UTType first (it recognizes bundles with changed case / no
        /// extension) and falls back to the extension when that cannot be read. `.app` is itself a directory,
        /// so `isDirectoryKey` **cannot** be used for this.
        static func isApplication(_ url: URL) -> Bool {
            if let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType {
                return type.conforms(to: .application)
            }
            return url.pathExtension.lowercased() == "app"
        }
    }

    /// The loadObject callback runs on a background thread; writes by index under a lock, preserving order.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var urls: [URL?]
        init(count: Int) { urls = Array(repeating: nil, count: count) }
        func set(_ url: URL?, at index: Int) {
            lock.lock(); defer { lock.unlock() }
            urls[index] = url
        }
    }
}

/// Removes the cursor badge over the Trash chip; everything else about the drop stays SwiftUI's.
///
/// SwiftUI's `.onDrop` only offers `.copy` (badge) / `.move` / `.forbidden`, and its real AppKit
/// destination is a private subview spanning the strip. `NSWindow`'s dragging methods are never
/// called during a session, so neither the window nor a parent view can rewrite the answer. AppKit
/// hands the drag to the topmost registered view instead, so this view sits **over** that subview
/// with the same frame (`.overlay` right after `.onDrop`), forwards every dragging message to it
/// unchanged, and rewrites only the returned operation. SwiftUI therefore sees exactly the session it
/// saw before (one enter, updates, one exit or perform), so highlight, ghost, frozen width and the
/// watchdog are untouched. A view covering only the Trash chip would split that into exit/enter pairs.
struct StripDropBadgeOverlay: NSViewRepresentable {
    func makeNSView(context: Context) -> ForwardingView { ForwardingView() }
    func updateNSView(_ nsView: ForwardingView, context: Context) {}

    final class ForwardingView: NSView {
        private weak var destination: NSView?

        /// Observes drags only; clicks, hover and scrolling go to the content below.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveDestination()
            // SwiftUI may insert its destination view later in the same pass.
            DispatchQueue.main.async { [weak self] in self?.resolveDestination() }
        }

        override func layout() {
            super.layout()
            if destination?.window !== window { resolveDestination() }
        }

        /// Registered only while the SwiftUI destination is known, with its exact types: unregistered,
        /// AppKit targets SwiftUI directly and drops keep working (with the badge).
        private func resolveDestination() {
            let found = window == nil ? nil : Self.nearestDropDestination(from: self)
            destination = found
            let types = found?.registeredDraggedTypes ?? []
            if Set(types) != Set(registeredDraggedTypes) {
                unregisterDraggedTypes()
                if !types.isEmpty { registerForDraggedTypes(types) }
            }
        }

        /// The nearest registered view sharing an ancestor with `view`: the strip's only `.onDrop`.
        /// The ancestor itself counts too, in case a SwiftUI version handles drops in the hosting view.
        private static func nearestDropDestination(from view: NSView) -> NSView? {
            var ancestor = view.superview
            while let current = ancestor {
                if let found = firstRegistered(in: current, excluding: view) { return found }
                if !current.registeredDraggedTypes.isEmpty { return current }
                ancestor = current.superview
            }
            return nil
        }

        private static func firstRegistered(in root: NSView, excluding excluded: NSView) -> NSView? {
            for subview in root.subviews where subview !== excluded && !(subview is ForwardingView) {
                if !subview.registeredDraggedTypes.isEmpty { return subview }
                if let found = firstRegistered(in: subview, excluding: excluded) { return found }
            }
            return nil
        }

        private func liveDestination() -> NSView? {
            if destination?.window == nil { resolveDestination() }
            return destination
        }

        /// Read after forwarding: SwiftUI calls the delegate synchronously inside the forwarded call.
        private func answer(_ proposed: NSDragOperation, _ sender: NSDraggingInfo) -> NSDragOperation {
            let hovered = StripFileDropDelegate.hoveredTarget
            var staysOnVolume = false
            if case .moveInto(let path)? = hovered {
                staysOnVolume = StripFileDropDelegate.DragPasteboardInspector.movesWithinVolume(into: path)
            }
            let generic = StripDropRouting.usesGenericOperation(
                hoveredTarget: hovered,
                proposedIsCopy: proposed == .copy,
                sourceAllowsGeneric: sender.draggingSourceOperationMask.contains(.generic),
                moveIntoStaysOnVolume: staysOnVolume
            )
            return generic ? .generic : proposed
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard let destination = liveDestination() else { return [] }
            return answer(destination.draggingEntered(sender), sender)
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard let destination = liveDestination() else { return [] }
            return answer(destination.draggingUpdated(sender), sender)
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            destination?.draggingExited(sender)
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            destination?.prepareForDragOperation(sender) ?? false
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            destination?.performDragOperation(sender) ?? false
        }

        override func concludeDragOperation(_ sender: NSDraggingInfo?) {
            destination?.concludeDragOperation(sender)
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            destination?.draggingEnded(sender)
        }
    }
}
