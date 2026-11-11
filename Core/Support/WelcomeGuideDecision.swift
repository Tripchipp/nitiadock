import Foundation

/// Whether the first run shows the "we suggest hiding the system Dock" screen.
///
/// Pure decision, no I/O, unit-testable. The caller (`AppDelegate`) reads the system Dock state, shows the
/// window and writes the flag.
///
/// ## Why a single boolean is not enough
///
/// Looking only at "seen or not" hurts two groups:
///
/// - **Existing users who upgraded**. Most of them hid the system Dock long ago (the "Recommended setup"
///   section of the README has always suggested it), so showing it again is pure noise.
/// - **Sandboxed environments**. Writing system Dock preferences requires running unsandboxed
///   (`NativeDockPreferencesService.isAvailable`), so the button could not work: it would only offer a button
///   that always fails.
///
/// So the real system Dock state is read once more and four cases are handled separately. This follows the
/// "four quadrants" discipline of `AutoHideToggleMenuModel.resolvedStoreDelay`: **unreadable** is a state of
/// its own and must not be conflated with "read as false".
enum WelcomeGuideDecision {
    enum Outcome: Equatable {
        /// Show the guide.
        case present
        /// Do not show, and **record it as seen**: this machine never needs to be asked again.
        case skipAndMarkSeen
        /// Do not show, but **do not record**. The system state was just unreadable this time; decide again
        /// on next launch.
        case skipWithoutMarking
    }

    /// - Parameters:
    ///   - hasSeenWelcome: `AppSettingsStore.hasSeenWelcome`
    ///   - canWriteDockPreferences: `NativeDockPreferencesService.isAvailable` (not sandboxed)
    ///   - dockAutohideEnabled: whether the system Dock currently auto-hides; `nil` = **unreadable**
    ///     (`currentAutohideState()` returned nil), not "off"
    static func evaluate(
        hasSeenWelcome: Bool,
        canWriteDockPreferences: Bool,
        dockAutohideEnabled: Bool?
    ) -> Outcome {
        // Seen is seen. This rule must come first: it is what the user has already expressed (whether they
        // clicked "Hide it for me" or "Maybe later"), and none of the later rules may overturn it.
        if hasSeenWelcome { return .skipAndMarkSeen }

        // No button is better than a dead one. The sandbox is a permanent property, so retire the guide on
        // this machine.
        guard canWriteDockPreferences else { return .skipAndMarkSeen }

        guard let dockAutohideEnabled else {
            // CFPreferences occasionally fails to read. **Do not mark as seen here**: one transient failure
            // would swallow the guide for good. Reading again on next launch costs only one silent async read
            // per launch.
            return .skipWithoutMarking
        }

        // Already auto-hiding, so the guide is pointless. Mark it as seen too, so that a "first-run guide"
        // does not suddenly stop the user if they ever make the Dock permanent again: at that point they
        // clearly want the Dock back.
        if dockAutohideEnabled { return .skipAndMarkSeen }

        return .present
    }
}
