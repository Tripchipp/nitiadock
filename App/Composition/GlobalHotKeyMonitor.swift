import AppKit
import Carbon.HIToolbox

/// Global hotkey definition. keyCode + Carbon modifier bits are used for registration; `displayGlyphs` is
/// display only, fixed at recording time, with no reverse lookup from keyCode (see `HotKeyGlyphs` for why).
struct GlobalHotKeyShortcut: Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    /// Display glyphs (e.g. "⌥⇧⌘D"), shared by the menu group title and the settings window.
    let displayGlyphs: String
    let signature: OSType
    let id: UInt32

    var hotKeyID: EventHotKeyID { EventHotKeyID(signature: signature, id: id) }

    /// Default ⌥⇧⌘D: the system Dock's ⌥⌘D plus Shift, which frees the former ⌥⌘E for Safari
    /// / Finder. Four keys is a bit heavy, but this is a low-frequency mode switch; the
    /// combination still avoids VoiceOver's Control+Option and the bare Option / Option+Shift
    /// known to be broken on macOS 15 (FB15168205). Since 2026-08-24 users can rebind it;
    /// `HotKeyShortcutValidation` blocks the same traps at the recording entry point.
    static let edgeAutoHideMode = GlobalHotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_D),
        carbonModifiers: UInt32(optionKey | shiftKey | cmdKey),
        displayGlyphs: "⌥⇧⌘D",
        signature: 0x5467_4567, // 'TgEg'
        id: 1
    )

    // ⌥⌘D (the system Dock's own auto-hide shortcut) is **deliberately not defined here**: macOS
    // owns it, so registering it would steal it. An exact definition used to be kept for menu
    // display and key-press dedupe; both consumers went away when the system Dock show/hide command
    // was removed on 2026-08-01. The menu now only mentions ⌥⌘D as plain text in the group title.
    // The custom rebinding path also rejects this combination, via `HotKeyShortcutValidation`.
}

extension GlobalHotKeyShortcut {
    /// User-defined combination → definition used for registration. signature/id are **unchanged**: the
    /// hotkey's identity is "NitiaDock's always-shown toggle key" and the key combination is only a parameter
    /// of it. Callback matching and press dedupe both go by signature/id, so rebinding keeps the identity.
    init(stored: StoredHotKeyShortcut) {
        self.init(
            keyCode: stored.keyCode,
            carbonModifiers: stored.carbonModifiers,
            displayGlyphs: stored.glyphs,
            signature: Self.edgeAutoHideMode.signature,
            id: Self.edgeAutoHideMode.id
        )
    }
}

/// Hotkey event, already unpacked by the backend into plain values so unit tests can construct it.
enum HotKeyEvent: Equatable {
    case pressed(signature: OSType, id: UInt32)
    case released(signature: OSType, id: UInt32)
}

/// Injectable abstraction over the Carbon calls: unit tests use a fake to simulate
/// install/registration failures and event sequences. Contract: all methods are called
/// on the main thread only; onEvent returning true means the event was handled.
protocol HotKeyBackend: AnyObject {
    func installHandler(onEvent: @escaping (HotKeyEvent) -> Bool) -> OSStatus
    /// exclusive goes through the interface explicitly: exclusive registration (deterministic failure when
    /// someone else holds the combination) is behavior locked by tests, not an implementation detail.
    func register(keyCode: UInt32, modifiers: UInt32, hotKeyID: EventHotKeyID, exclusive: Bool) -> OSStatus
    func unregister()
    func removeHandler()
}

/// Lifecycle management for one global hotkey. Carbon RegisterEventHotKey is used instead
/// of an NSEvent global key monitor: it is notified only when the registered combination
/// is hit and never sees other keys; dispatch is system-level and does not depend on this
/// app being frontmost. Hard constraint: onPressed may only do a lightweight state toggle.
/// It must not synchronously read cross-app AX/CG inventories or export snapshots.
@MainActor
final class GlobalHotKeyMonitor {
    enum RegistrationStatus: Equatable {
        case registered
        case handlerInstallFailed(OSStatus)
        case registrationFailed(OSStatus)

        /// Fallback failure value for `SettingsCoordinator` when this
        /// instance has no hotkey monitor at all (temporary DMG copy).
        static let monitorUnavailable = RegistrationStatus.registrationFailed(OSStatus(paramErr))
    }

    private(set) var shortcut: GlobalHotKeyShortcut
    private let backend: HotKeyBackend
    private let onPressed: () -> Void
    private(set) var isRegistered = false
    /// Press-release gate: swallows the repeated pressed events
    /// that system key repeat produces while the key is held.
    private var isPressedDown = false
    /// Every successful registration advances the generation, so a callback queued
    /// on the main queue by the previous round cannot fire after stop/start.
    private var registrationGeneration: UInt64 = 0
    /// One attempt per instance; a repeated start() returns the
    /// previous result, with no automatic retry during this launch.
    private var attemptedStatus: RegistrationStatus?

    init(shortcut: GlobalHotKeyShortcut,
         backend: HotKeyBackend = CarbonHotKeyBackend(),
         onPressed: @escaping () -> Void) {
        self.shortcut = shortcut
        self.backend = backend
        self.onPressed = onPressed
    }

    deinit {
        MainActor.assumeIsolated { stop() }
    }

    @discardableResult
    func start() -> RegistrationStatus {
        if let attemptedStatus { return attemptedStatus }

        let installStatus = backend.installHandler { [weak self] event in
            self?.handle(event) ?? false
        }
        guard installStatus == noErr else {
            let status = RegistrationStatus.handlerInstallFailed(installStatus)
            attemptedStatus = status
            return status
        }

        let registerStatus = backend.register(
            keyCode: shortcut.keyCode,
            modifiers: shortcut.carbonModifiers,
            hotKeyID: shortcut.hotKeyID,
            exclusive: true
        )
        guard registerStatus == noErr else {
            // Registration failed: roll back the installed handler, leave nothing half-done.
            backend.removeHandler()
            let status = RegistrationStatus.registrationFailed(registerStatus)
            attemptedStatus = status
            return status
        }

        isRegistered = true
        registrationGeneration &+= 1
        attemptedStatus = .registered
        return .registered
    }

    func stop() {
        // Mark inactive and clear the press gate first, then unregister
        // the hotkey and remove the handler; safe to call repeatedly.
        let wasRegistered = isRegistered
        isRegistered = false
        isPressedDown = false
        guard wasRegistered else { return }
        backend.unregister()
        backend.removeHandler()
        // An instance that was explicitly stopped may start again (a real
        // re-registration); otherwise the cached .registered would lie. Failure results
        // stay cached: "no automatic retry during this launch" applies to failures only.
        attemptedStatus = nil
    }

    /// Rebind: stop the old one, register the new one; if the new key fails to register, switch
    /// back to the old key and re-register it. Returns the registration result of the **new key**.
    ///
    /// `stop()` clears the attempt cache only if registration had succeeded, so both places
    /// must clear it explicitly again. If the cached failure from the previous round stayed,
    /// `start()` here would report the stale result. On success `start()` advances
    /// `registrationGeneration`, which invalidates callbacks queued by the old registration.
    @discardableResult
    func update(shortcut next: GlobalHotKeyShortcut) -> RegistrationStatus {
        let previous = shortcut
        stop()
        attemptedStatus = nil
        shortcut = next
        let status = start()
        guard status != .registered else { return status }
        stop()
        attemptedStatus = nil
        shortcut = previous
        _ = start()
        return status
    }

    fileprivate func handle(_ event: HotKeyEvent) -> Bool {
        guard isRegistered else { return false }
        switch event {
        case .pressed(let signature, let id):
            guard signature == shortcut.signature, id == shortcut.id else { return false }
            // Repeated pressed while already in the pressed state:
            // it is our key, swallow it without calling back again.
            guard !isPressedDown else { return true }
            isPressedDown = true
            let queuedGeneration = registrationGeneration
            DispatchQueue.main.async { [weak self] in
                // A queued callback belongs only to the registration lifecycle
                // that captured it; stop/start changes the generation.
                guard let self,
                      self.isRegistered,
                      self.registrationGeneration == queuedGeneration else { return }
                self.onPressed()
            }
            return true
        case .released(let signature, let id):
            guard signature == shortcut.signature, id == shortcut.id else { return false }
            isPressedDown = false
            return true
        }
    }
}

/// Production implementation: real Carbon calls. The system delivers
/// hotkey events to the application event target (main-thread run loop).
final class CarbonHotKeyBackend: HotKeyBackend {
    private var handlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    fileprivate var onEvent: ((HotKeyEvent) -> Bool)?

    func installHandler(onEvent: @escaping (HotKeyEvent) -> Bool) -> OSStatus {
        guard handlerRef == nil else { return OSStatus(paramErr) }
        self.onEvent = onEvent
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        var installed: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyEventCallback,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &installed
        )
        if status == noErr {
            handlerRef = installed
        } else {
            self.onEvent = nil
        }
        return status
    }

    func register(keyCode: UInt32, modifiers: UInt32, hotKeyID: EventHotKeyID, exclusive: Bool) -> OSStatus {
        guard hotKeyRef == nil else { return OSStatus(paramErr) }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            exclusive ? OptionBits(kEventHotKeyExclusive) : 0,
            &ref
        )
        if status == noErr { hotKeyRef = ref }
        return status
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    func removeHandler() {
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        onEvent = nil
    }
}

/// Carbon C callback: unpacks the event kind and EventHotKeyID and forwards
/// them to backend.onEvent; on unpack failure, unknown event, or when onEvent
/// decides it is not ours, hands it back to the system (eventNotHandledErr).
private let carbonHotKeyEventCallback: EventHandlerUPP = { _, eventRef, userData in
    guard let eventRef, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let paramStatus = GetEventParameter(
        eventRef,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard paramStatus == noErr else { return OSStatus(eventNotHandledErr) }

    let event: HotKeyEvent
    switch Int(GetEventKind(eventRef)) {
    case kEventHotKeyPressed:
        event = .pressed(signature: hotKeyID.signature, id: hotKeyID.id)
    case kEventHotKeyReleased:
        event = .released(signature: hotKeyID.signature, id: hotKeyID.id)
    default:
        return OSStatus(eventNotHandledErr)
    }

    let backend = Unmanaged<CarbonHotKeyBackend>.fromOpaque(userData).takeUnretainedValue()
    let handled = backend.onEvent?(event) ?? false
    return handled ? noErr : OSStatus(eventNotHandledErr)
}
