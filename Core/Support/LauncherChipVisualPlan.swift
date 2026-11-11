import Foundation

/// The **pure visual decision layer** of LauncherChip: given the running
/// state, decides whether to draw the running dot under the icon.
/// Extracted as pure logic for unit testing; rendering side effects stay in LauncherChip.
///
/// Only one check is left in this type, but **the signal it carries is now the only one**: on
/// 2026-08-02 per-state icon dimming was removed (light and dark together, see
/// `DockThemeTokens`), so "is this app still there" is expressed entirely by this
/// dot: running = dot, quit = no dot, regardless of the section (messaging zone / drawer / kept icon).
/// "Running but hidden / minimized" no longer has any icon-level indication, an explicitly accepted cost.
enum LauncherChipVisualPlan {
    struct Visual: Equatable {
        let showsRunningDot: Bool
    }

    static func visual(isRunning: Bool) -> Visual {
        Visual(showsRunningDot: isRunning)
    }
}
