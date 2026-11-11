import Carbon.HIToolbox
import Foundation

/// Key combination → display glyphs (e.g. "⌃⌘K"). Pure function, compiled into both the App and test targets.
///
/// The main key's glyph is **fixed at recording time and stored in `StoredHotKeyShortcut.glyphs`**; the
/// display side only reads the stored string. Looking a character up from a keyCode needs UCKeyTranslate
/// plus the current keyboard layout: computing it at display time is heavy and drifts with the layout,
/// while at recording time the NSEvent already carries `charactersIgnoringModifiers` for free.
enum HotKeyGlyphs {
    /// Fixed modifier order ⌃⌥⇧⌘ (the standard display order of the macOS menu bar).
    static func modifierString(carbonModifiers: UInt32) -> String {
        var out = ""
        if carbonModifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { out += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { out += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { out += "⌘" }
        return out
    }

    /// Main key glyph. Returns nil when it is not in the table and the event
    /// character is not printable (the caller treats the key as unusable).
    static func keyString(keyCode: UInt32, charactersIgnoringModifiers: String?) -> String? {
        if let known = specialKeyNames[keyCode] { return known }
        guard let raw = charactersIgnoringModifiers, let scalar = raw.unicodeScalars.first else {
            return nil
        }
        // Function keys such as the F keys map to the Unicode private use area
        // (from U+F700); not in the table means not accepted. Control characters
        // are never accepted (Return and Tab are already in the table).
        guard scalar.value < 0xF700, !CharacterSet.controlCharacters.contains(scalar) else {
            return nil
        }
        let key = raw.uppercased()
        return key.isEmpty ? nil : key
    }

    /// Full display string; nil when the main key cannot be displayed.
    static func display(keyCode: UInt32, carbonModifiers: UInt32, charactersIgnoringModifiers: String?) -> String? {
        guard let key = keyString(keyCode: keyCode, charactersIgnoringModifiers: charactersIgnoringModifiers) else {
            return nil
        }
        return modifierString(carbonModifiers: carbonModifiers) + key
    }

    private static let specialKeyNames: [UInt32: String] = [
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Return): "↩",
        UInt32(kVK_ANSI_KeypadEnter): "⌤",
        UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Home): "↖",
        UInt32(kVK_End): "↘",
        UInt32(kVK_PageUp): "⇞",
        UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]
}
