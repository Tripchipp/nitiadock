import AppKit
import Carbon
import OSLog

final class FinderTrashClient: FinderTrashClienting {
    private let stateQueue = DispatchQueue(label: "com.tungsten.edge.trash-state", qos: .utility)
    /// Dedicated and serial: an interactive empty blocks here until Finder's own dialog closes
    /// (up to 600s), which must never hold a thread of the shared user-action queue.
    private let commandQueue = DispatchQueue(label: "com.tungsten.edge.trash-command", qos: .userInitiated)
    /// Listing and reveal for the popup: off `stateQueue` so a slow listing never delays the icon's
    /// count reads, off `commandQueue` so it never queues behind an interactive empty.
    private let listQueue = DispatchQueue(label: "com.tungsten.edge.trash-list", qos: .userInitiated)
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private static let logger = Logger(subsystem: "no.thilip.nitiadock", category: "FinderTrash")

    private func currentGeneration() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    func cancelPending() {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
    }

    func permission(ask: Bool, completion: @escaping @MainActor (FinderAutomationStatus) -> Void) {
        let gen = currentGeneration()
        stateQueue.async { [self] in
            guard currentGeneration() == gen else {
                DispatchQueue.main.async { completion(.unavailable) }
                return
            }
            let raw = FinderAutomationPermission.status(askUserIfNeeded: ask)
            Self.logger.info("Trash authorization check ask=\(ask) status=\(raw)")
            DispatchQueue.main.async { completion(FinderAutomationStatus(osStatus: raw)) }
        }
    }

    func count(completion: @escaping @MainActor (FinderTrashOutcome) -> Void) {
        let gen = currentGeneration()
        stateQueue.async { [self] in
            guard currentGeneration() == gen else {
                DispatchQueue.main.async { completion(.cancelled) }
                return
            }
            guard let trash = Self.trashObject() else {
                DispatchQueue.main.async { completion(.failed(-1700)) }
                return
            }
            let event = Self.event(eventClass: FinderTrashEvent.core, id: FinderTrashEvent.count)
            event.setParam(trash, forKeyword: keyDirectObject)
            event.setParam(NSAppleEventDescriptor(typeCode: FinderTrashEvent.itemClass),
                           forKeyword: keyAEObjectClass)
            let outcome = Self.send(event, options: FinderTrashEvent.countOptions, timeout: 5, isCount: true)
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    func empty(interactive: Bool, completion: @escaping @MainActor (FinderTrashOutcome) -> Void) {
        let gen = currentGeneration()
        commandQueue.async { [self] in
            guard currentGeneration() == gen else {
                DispatchQueue.main.async { completion(.cancelled) }
                return
            }
            let event = Self.event(eventClass: FinderTrashEvent.finder, id: FinderTrashEvent.empty)
            let options = interactive ? FinderTrashEvent.emptyInteractiveOptions : FinderTrashEvent.emptyOptions
            let outcome = Self.send(event, options: options, timeout: interactive ? 600 : 30, isCount: false)
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    func activateFinder(completion: @escaping @MainActor () -> Void) {
        let gen = currentGeneration()
        commandQueue.async { [self] in
            if currentGeneration() == gen {
                let event = Self.event(eventClass: 0x6d697363, id: 0x61637476)
                _ = Self.send(event, options: FinderTrashEvent.countOptions, timeout: 5, isCount: false)
            }
            DispatchQueue.main.async { completion() }
        }
    }

    /// Never activates Finder: activation also raises Finder's last-used window over the current app.
    /// Bringing the Trash window forward on its own is the caller's job. Off the main thread: the
    /// LaunchServices lookup and the open request both block, and with Finder loaded the first open
    /// of a process kept the main thread from reaching the open call for ~1.9s (2026-09-15).
    func openTrash() {
        let gen = currentGeneration()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            guard currentGeneration() == gen else { return }
            let startedAt = Date()
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
            guard let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else {
                sendOpenEvent(generation: gen)
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.open([url], withApplicationAt: finderURL, configuration: configuration) { [self] _, error in
                Self.logger.info("open Trash issuedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) error=\(String(describing: error), privacy: .public)")
                guard let error else { return }
                Self.logger.error("open trash failed error=\(String(describing: error), privacy: .public)")
                sendOpenEvent(generation: gen)
            }
        }
    }

    /// `URL of every item of trash`, one round trip (a loaded Finder takes ~1s). nil = Finder did not
    /// answer or refused; an empty Trash is `[]`.
    func listItemURLs(completion: @escaping @MainActor ([String]?) -> Void) {
        let gen = currentGeneration()
        listQueue.async { [self] in
            guard currentGeneration() == gen,
                  let trash = Self.trashObject(),
                  let every = Self.everyItem(of: trash),
                  let urls = Self.propertySpecifier(FinderTrashEvent.urlProperty, of: every) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let event = Self.event(eventClass: FinderTrashEvent.core, id: FinderTrashEvent.getData)
            event.setParam(urls, forKeyword: keyDirectObject)
            let strings = Self.sendForStrings(event, timeout: 10)
            Self.logger.info("Trash list count=\(strings?.count ?? -1)")
            guard currentGeneration() == gen else { return }
            DispatchQueue.main.async { completion(strings) }
        }
    }

    /// Finder's `reveal`: selects the item in the Trash window without activating Finder, the only
    /// scriptable road to "put back" (the user presses ⌘⌫ there). Bringing that window forward is
    /// the caller's job, as with `openTrash`.
    func reveal(_ url: URL) {
        let gen = currentGeneration()
        listQueue.async { [self] in
            guard currentGeneration() == gen else { return }
            let event = Self.event(eventClass: FinderTrashEvent.miscellaneous, id: FinderTrashEvent.reveal)
            event.setParam(NSAppleEventDescriptor(fileURL: url), forKeyword: keyDirectObject)
            _ = Self.send(event, options: FinderTrashEvent.countOptions, timeout: 5, isCount: false)
        }
    }

    /// Fallback open through Finder's own `odoc` event, which does not activate Finder either.
    private func sendOpenEvent(generation gen: UInt64) {
        commandQueue.async { [self] in
            guard currentGeneration() == gen, let trash = Self.trashObject() else { return }
            let event = Self.event(eventClass: 0x61657674, id: 0x6f646f63)
            event.setParam(trash, forKeyword: keyDirectObject)
            _ = Self.send(event, options: FinderTrashEvent.countOptions, timeout: 5, isCount: false)
        }
    }

    private static func event(eventClass: UInt32, id: UInt32) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(eventClass: eventClass, eventID: id,
                              targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder"),
                              returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }

    /// `nil` when the coercion fails; this runs off the main thread, so it must never trap.
    private static func trashObject() -> NSAppleEventDescriptor? {
        propertySpecifier(FinderTrashEvent.trashProperty, of: .null())
    }

    private static func propertySpecifier(_ property: UInt32, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        objectSpecifier(desiredClass: typeProperty, form: OSType(formPropertyID),
                        data: NSAppleEventDescriptor(typeCode: property), container: container)
    }

    /// `every item of <container>`. The ordinal's bytes are the OSType in **native** order: that is
    /// what AppleScript itself sends (`AEDebugSends`); big-endian bytes make Finder answer -1728.
    private static func everyItem(of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        var ordinal = FinderTrashEvent.absoluteAll
        let data = Data(bytes: &ordinal, count: MemoryLayout<UInt32>.size)
        guard let all = NSAppleEventDescriptor(descriptorType: DescType(typeAbsoluteOrdinal), data: data) else { return nil }
        return objectSpecifier(desiredClass: FinderTrashEvent.itemClass, form: OSType(formAbsolutePosition),
                               data: all, container: container)
    }

    private static func objectSpecifier(desiredClass: UInt32, form: OSType, data: NSAppleEventDescriptor,
                                        container: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: desiredClass), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(data, forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return record.coerce(toDescriptorType: typeObjectSpecifier)
    }

    /// Reply → list of strings. Finder may answer a single item as a bare string, and an error
    /// number in the reply is a failure even though the send succeeded.
    private static func sendForStrings(_ event: NSAppleEventDescriptor, timeout: TimeInterval) -> [String]? {
        do {
            let reply = try event.sendEvent(options: FinderTrashEvent.countOptions, timeout: timeout)
            if let error = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value, error != 0 {
                logger.info("Trash list failed code=\(error)")
                return nil
            }
            guard let list = reply.paramDescriptor(forKeyword: keyDirectObject) else { return nil }
            guard list.descriptorType == DescType(typeAEList) else {
                return list.stringValue.map { [$0] } ?? []
            }
            guard list.numberOfItems > 0 else { return [] }
            return (1...list.numberOfItems).compactMap { list.atIndex($0)?.stringValue }
        } catch {
            logger.info("Trash list send failed code=\((error as NSError).code)")
            return nil
        }
    }

    private static func send(_ event: NSAppleEventDescriptor, options: NSAppleEventDescriptor.SendOptions,
                             timeout: TimeInterval, isCount: Bool) -> FinderTrashOutcome {
        do {
            let reply = try event.sendEvent(options: options, timeout: timeout)
            let error = reply.paramDescriptor(forKeyword: keyErrorNumber).map { Int($0.int32Value) }
            let integer = reply.paramDescriptor(forKeyword: keyDirectObject)?
                .coerce(toDescriptorType: typeSInt32).map { Int($0.int32Value) }
            let outcome = FinderTrashReply.parse(isCount: isCount, sendError: nil, replyError: error,
                                                integer: integer, hasReply: true)
            logger.info("Trash reply count=\(isCount) outcome=\(String(describing: outcome), privacy: .public)")
            return outcome
        } catch {
            let code = (error as NSError).code
            logger.info("Trash send failed count=\(isCount) code=\(code)")
            return FinderTrashReply.parse(isCount: isCount, sendError: code, replyError: nil,
                                         integer: nil, hasReply: false)
        }
    }
}
