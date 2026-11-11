import Foundation

/// Pure presentation/dedup decisions for the two auto-hide settings (system Dock + NitiaDock), covered by
/// unit tests.
///
/// Lives in `App/Composition` rather than `Core/Support`: it is about how the **menu** presents things
/// (wording of group titles, when the confirm row appears), an app-layer presentation convention rather than
/// a UI-independent decision of the Core kind. Since `keyEquivalentPresentation` was removed on 2026-08-03 it
/// no longer carries AppKit types, but the reason for its placement is unchanged. Don't move it again just to
/// "look purer".
@MainActor
enum AutoHideToggleMenuModel {
    /// Group title for the system Dock group (not clickable). The two sliders look identical; without titles
    /// you can't tell which controls what.
    ///
    /// ⌥⌘D is written into the title as **plain text**, with no `keyEquivalent`: the row is not clickable
    /// anyway, and setting one would be captured by the menu and make the disabled row look clickable. The
    /// key is owned by macOS and always works; we only tell the user it exists. With the show/hide command
    /// removed, it is the one-key way to "bring the Dock back temporarily".
    static let nativeDockSectionTitle = String(localized: "macOS Dock (⌥⌘D to show/hide)")

    /// Group title for the NitiaDock group (not clickable), **symmetric** with the one above.
    ///
    /// The two groups used to be asymmetric: the system Dock had a header and NitiaDock had none, so the
    /// whole menu had a single header at the top and "Open System Dock Settings…" looked like it belonged
    /// with the NitiaDock commands below it (feedback of 2026-08-03). When the header was added, the
    /// clickable show/hide command was removed: switching to always shown is now done by dragging the slider
    /// or pressing ⌥⇧⌘D.
    ///
    /// The shortcut is likewise written into the title as **plain text** only, with no `keyEquivalent` (same
    /// reason as above), and it is mentioned only when Carbon registration succeeded: if registration failed
    /// the key does nothing, and showing it would be a lie. `glyphs` = the glyphs of the currently effective
    /// combination (user-configurable since 2026-08-24, no longer hardcoded to ⌥⇧⌘D).
    static func edgeSectionTitle(isHotKeyRegistered: Bool, glyphs: String) -> String {
        isHotKeyRegistered
            ? String(format: String(localized: "NitiaDock (%@ to show/hide)"), glyphs)
            : String(localized: "NitiaDock")
    }

    /// Display name of a slider level. The slider itself and the confirm row must share this one definition,
    /// otherwise the level the confirm row names and the one shown on the slider differ.
    static func delayDisplayName(sliderIndex index: Int) -> String {
        switch index {
        case 0:
            return String(localized: "Always Visible")
        case AppSettingsStore.sliderIndexMax:
            return String(localized: "Never Wake")
        default:
            return String(format: "%.1fs", AppSettingsStore.delayFromSliderIndex(index))
        }
    }

    /// Every write to the system Dock ends with `killall Dock`, so the screen always flashes once. That flash
    /// cannot be removed (it is the only path on macOS that makes an `autohide-delay` change take effect), so
    /// it can only be made to happen **after** the user actively confirms, where an expected flash does not
    /// feel odd. So the slider does not auto-commit, and the confirm row appears only when the draft differs
    /// from the effective value.
    ///
    /// Compares **integer levels**, not floats: the slider can only rest on levels anyway, and comparing
    /// floats gets bitten by representation error.
    static func shouldShowNativeApply(draft: Double, applied: Double) -> Bool {
        AppSettingsStore.sliderIndexFromDelay(draft) != AppSettingsStore.sliderIndexFromDelay(applied)
    }

    /// Including the target level in the title is deliberate: it also reminds the user that "the level you
    /// dragged to is not in effect yet".
    static func nativeApplyTitle(draft: Double) -> String {
        let name = delayDisplayName(sliderIndex: AppSettingsStore.sliderIndexFromDelay(draft))
        // Explicit %@ + String(format:), not the interpolation syntax of String(localized:): the latter's key
        // is derived by the compiler from the interpolation types (String -> %@), so the key's shape is not
        // visible here and a mistake only shows at runtime. With a handwritten placeholder the key is this
        // literal, and a script can check each one.
        return String(format: String(localized: "Apply “%@” (the Dock will restart)"), name)
    }

    /// The system Dock's actual default delay when the autohide-delay key does not exist.
    static let systemDefaultAutohideDelay = 0.5

    /// System truth -> the level value the local mirror should hold.
    static func storeDelay(systemEnabled: Bool, systemDelay: Double?) -> Double {
        guard systemEnabled else { return AppSettingsStore.neverHideDelay }
        let rawDelay = systemDelay ?? systemDefaultAutohideDelay
        // The system switch is definitely on; a negative delay can only be treated as an externally
        // customized very short delay, and must not pass through snapDelay to be misread as this app's
        // "always shown" sentinel -1.
        let enabledDelay = rawDelay.isFinite
            ? max(rawDelay, AppSettingsStore.finiteDelayMin)
            : AppSettingsStore.defaultNativeDockAutoHideDelay
        return AppSettingsStore.snapDelay(
            enabledDelay,
            fallbackForNonFinite: AppSettingsStore.defaultNativeDockAutoHideDelay
        )
    }

    /// Feeds the actual system state back into the local mirror so the slider, title and click direction all
    /// start from the same truth. Returns nil = already consistent, no change needed
    /// (`setNativeDockAutoHideDelay` dedups too, but checking here first saves a pointless `@Published`
    /// notification).
    static func reconciledStoreDelay(
        systemEnabled: Bool,
        systemDelay: Double?,
        currentStoreDelay: Double
    ) -> Double? {
        let target = storeDelay(systemEnabled: systemEnabled, systemDelay: systemDelay)
        return currentStoreDelay == target ? nil : target
    }

    /// What value the local mirror should take after writing to the system. Four quadrants, and it **cannot
    /// be a blanket "revert to previous on failure"**: rolling back when the write succeeded but cannot be
    /// read back would make the UI show the opposite of the system setting already in effect.
    ///
    /// |            | System readable | System unreadable |
    /// |------------|--------------|--------------|
    /// | **Write succeeded** | use the value read | keep target  |
    /// | **Write failed** | use the value read (may be the result of a partial write) | keep previous |
    static func resolvedStoreDelay(
        writeSucceeded: Bool,
        systemState: NativeDockAutohideState?,
        target: Double,
        previous: Double
    ) -> Double {
        if let systemState {
            return storeDelay(systemEnabled: systemState.enabled, systemDelay: systemState.delay)
        }
        return writeSucceeded ? target : previous
    }

}
