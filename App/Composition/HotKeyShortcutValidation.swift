import Carbon.HIToolbox
import Foundation

/// Reason a recorded key combination was rejected. Lets the settings window
/// pick a human-readable sentence; a plain value for easy unit testing.
enum HotKeyShortcutRejection: Equatable {
    /// None of ⌘ / ⌃ / ⌥ (includes ⇧ only, or no modifier at all).
    case missingPrimaryModifier
    /// ⌥ only or ⌥⇧: known to be unreliable on macOS 15 (FB15168205);
    /// the default shortcut was chosen to avoid exactly this.
    case unreliableModifiers
    /// Taken by the system: ⌃⌥ (VoiceOver's modifier combination, rejected when ⌘ is
    /// absent) and exactly ⌥⌘D (macOS's own system Dock show/hide key: the system
    /// owns it, registering would steal it, same rule as `GlobalHotKeyShortcut`).
    case reservedBySystem
    /// Esc / Delete / Forward Delete cannot be the main key: they have their own meaning in the recorder
    /// field (cancel), and as a global key they would only clash with countless in-app meanings.
    case forbiddenKey
}

/// Pure check for "can this combination be registered as NitiaDock's global shortcut".
/// Compiled into both the App and test targets; the registration side effect lives in `GlobalHotKeyMonitor`.
enum HotKeyShortcutValidation {
    static func validate(keyCode: UInt32, carbonModifiers: UInt32) -> HotKeyShortcutRejection? {
        let cmd = UInt32(cmdKey)
        let opt = UInt32(optionKey)
        let ctl = UInt32(controlKey)
        let shf = UInt32(shiftKey)

        let forbiddenKeys: Set<UInt32> = [
            UInt32(kVK_Escape),
            UInt32(kVK_Delete),
            UInt32(kVK_ForwardDelete),
        ]
        if forbiddenKeys.contains(keyCode) { return .forbiddenKey }

        if carbonModifiers & (cmd | ctl | opt) == 0 { return .missingPrimaryModifier }
        if carbonModifiers == opt || carbonModifiers == (opt | shf) { return .unreliableModifiers }
        // ⌃⌥ without ⌘ is VoiceOver's modifier domain; ⌃⌥⌘X with ⌘ is a common safe combination, allow it.
        if carbonModifiers & ctl != 0, carbonModifiers & opt != 0, carbonModifiers & cmd == 0 {
            return .reservedBySystem
        }
        if carbonModifiers == (opt | cmd), keyCode == UInt32(kVK_ANSI_D) { return .reservedBySystem }
        return nil
    }
}
