import Foundation

/// Clears "terminal-flavored" environment variables at process entry (2026-08-23).
///
/// When the taskbar launches another app, the system passes our own environment to it as is. A
/// dev build started from a terminal (Xcode / Claude Code / Ghostty) carries `LANG=en_US.UTF-8`,
/// so WeChat launched by it opens with an English UI and its main window title becomes `Weixin`,
/// which breaks the "title == app name" main window recognition. That is where "WeChat launched
/// from NitiaDock is in English" came from (measured: that WeChat process carried the full set
/// of terminal variables, while Telegram launched from the Dock had none).
/// A taskbar should launch apps **like the Dock does**, however it was launched itself.
///
/// Normal users launch from Launchpad / login items, where these
/// variables do not exist, so clearing them has no effect.
/// Our own `DOCK_*` switches are not on the list.
enum ProcessEnvironmentScrub {
    static let exactKeys: Set<String> = [
        "LANG", "COLORTERM", "SHELL", "SHLVL",
        "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID",
    ]
    static let prefixes: [String] = ["LC_", "CLAUDE_", "GHOSTTY_"]

    /// Pure decision: which keys of the given environment to clear. Sorted only for stable output.
    static func keysToUnset(in environment: [String: String]) -> [String] {
        environment.keys
            .filter { key in exactKeys.contains(key) || prefixes.contains(where: { key.hasPrefix($0) }) }
            .sorted()
    }

    /// Call once at entry, as early as possible: any app we launch
    /// afterwards inherits the environment as of that moment.
    static func apply(environment: [String: String] = ProcessInfo.processInfo.environment) {
        for key in keysToUnset(in: environment) {
            unsetenv(key)
        }
    }
}
