import AppKit
import Foundation
import Security

typealias ShellRunner = @MainActor (_ executable: String, _ arguments: [String]) throws -> Void
typealias URLOpener = @MainActor (URL) -> Bool

/// Snapshot of the system Dock's actual auto-hide state. delay
/// nil = the autohide-delay key is absent (system default).
struct NativeDockAutohideState: Equatable {
    var enabled: Bool
    var delay: Double?
}

/// `apply(delay:)` is the only remaining write path to the system Dock (decided 2026-08-01): the
/// menu's show/hide command was removed and the whole group is expressed by the slider + confirm
/// row. The slider covers every state (always shown / seconds / never wake), so the command was
/// redundant; it also toggled only `autohide` without touching `autohide-delay`, so its literal
/// promise of "hide" exceeded the actual effect and misled. One-key show/hide is left to the
/// system's own ⌥⌘D (owned by macOS, always works, and uses the delay written here).
@MainActor
protocol NativeDockPreferencesServicing {
    var isAvailable: Bool { get }
    func apply(delay: Double) throws
    /// One-off write from the first-run guide screen: each of the three items is
    /// optional, and **the whole batch restarts the Dock only once** (one screen flash).
    func apply(recommendations: NativeDockRecommendations) throws
    /// Current auto-hide state of the system Dock. nil = unreadable (sandbox etc.); the caller
    /// falls back to deriving it from the locally stored value. Must read the actual system value:
    /// the user can change it any time with ⌥⌘D / System Settings, so the local value goes stale.
    func currentAutohideState() async -> NativeDockAutohideState?
    /// Only opens the Dock page in System Settings; does not modify
    /// preferences and is not subject to the write path's sandbox gate.
    func openSystemSettings() -> Bool
    /// Puts back what the setup guide changes: auto-hide off with the standard delay, the Genie
    /// minimize effect, and minimizing into the window's own spot. One Dock restart.
    func restoreDefaults() throws
}

extension NativeDockPreferencesServicing {
    func restoreDefaults() throws { throw NativeDockPreferencesError.sandboxed }
}

struct SandboxEnvironment {
    var isSandboxed: Bool

    static var current: SandboxEnvironment {
        let key = "com.apple.security.app-sandbox" as CFString
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, key, nil) else {
            return SandboxEnvironment(isSandboxed: false)
        }
        return SandboxEnvironment(isSandboxed: (value as? Bool) == true)
    }
}

@MainActor
final class NativeDockPreferencesService: NativeDockPreferencesServicing {
    /// The system Dock's "never wake" value. Deliberately 999 rather
    /// than an extreme float, which Dock preferences parse unreliably.
    static let noWakeDelay = 999.0

    private let sandbox: SandboxEnvironment
    private let runner: ShellRunner
    private let autohideReader: @Sendable () -> NativeDockAutohideState?
    private let urlOpener: URLOpener
    private let readerQueue = DispatchQueue(label: "no.thilip.nitiadock.native-dock-reader", qos: .userInitiated)

    init(sandbox: SandboxEnvironment = .current,
         runner: @escaping ShellRunner = NativeDockPreferencesService.runProcess,
         autohideReader: @escaping @Sendable () -> NativeDockAutohideState? = { NativeDockPreferencesService.readAutohideStateFromSystem() },
         urlOpener: @escaping URLOpener = NativeDockPreferencesService.openURL) {
        self.sandbox = sandbox
        self.runner = runner
        self.autohideReader = autohideReader
        self.urlOpener = urlOpener
    }

    var isAvailable: Bool { !sandbox.isSandboxed }

    func currentAutohideState() async -> NativeDockAutohideState? {
        guard isAvailable else { return nil }
        let autohideReader = autohideReader
        let readerQueue = readerQueue
        return await withCheckedContinuation { continuation in
            readerQueue.async {
                continuation.resume(returning: autohideReader())
            }
        }
    }

    /// Monterey uses "Dock & Menu Bar"; Ventura and later map to "Desktop & Dock".
    /// If the deep link fails, let the system open Dock.prefPane; neither path starts a subprocess.
    func openSystemSettings() -> Bool {
        if let primary = URL(string: "x-apple.systempreferences:com.apple.preference.dock"),
           urlOpener(primary) {
            return true
        }
        return urlOpener(URL(fileURLWithPath: "/System/Library/PreferencePanes/Dock.prefPane"))
    }

    private static func openURL(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    nonisolated static func readAutohideStateFromSystem() -> NativeDockAutohideState? {
        let domain = "com.apple.dock" as CFString
        // External changes (⌥⌘D / System Settings / killall Dock) do not reach this process's CFPreferences
        // cache on their own, so synchronize before every read, or stale values may be returned indefinitely.
        return readAutohideState(
            synchronize: { CFPreferencesAppSynchronize(domain) },
            valueForKey: { key in
                CFPreferencesCopyAppValue(key as CFString, domain)
            }
        )
    }

    /// Injects the sync and fetch actions, which isolates CFPreferences
    /// I/O and makes branches such as sync failure directly unit-testable.
    nonisolated static func readAutohideState(
        synchronize: () -> Bool,
        valueForKey: (String) -> Any?
    ) -> NativeDockAutohideState? {
        guard synchronize() else { return nil }
        return decodeAutohideState(
            autohideValue: valueForKey("autohide"),
            delayValue: valueForKey("autohide-delay")
        )
    }

    /// Pure decoding rules: a missing autohide key means off; present but not a Bool means
    /// the whole snapshot is unreadable. When on, a missing delay key means system default
    /// and a wrong type means unreadable; when off, delay does not affect the on/off value.
    nonisolated static func decodeAutohideState(
        autohideValue: Any?,
        delayValue: Any?
    ) -> NativeDockAutohideState? {
        let enabled: Bool
        if let autohideValue {
            guard let decoded = strictBooleanValue(autohideValue) else { return nil }
            enabled = decoded
        } else {
            enabled = false
        }

        if !enabled {
            let delay = delayValue.flatMap { finiteNumericValue($0) }
            return NativeDockAutohideState(enabled: false, delay: delay)
        }

        let delay: Double?
        if let delayValue {
            guard let decoded = finiteNumericValue(delayValue) else { return nil }
            delay = decoded
        } else {
            delay = nil
        }
        return NativeDockAutohideState(enabled: enabled, delay: delay)
    }

    /// Slider: writes a whole step. The always-shown step only turns `autohide` off and writes
    /// no delay: the delay is meaningless then, and writing it would overwrite the user's value.
    func apply(delay: Double) throws {
        guard isAvailable else { throw NativeDockPreferencesError.sandboxed }
        for command in Self.commands(for: delay) {
            try runner(command.executable, command.arguments)
        }
    }

    func apply(recommendations: NativeDockRecommendations) throws {
        guard isAvailable else { throw NativeDockPreferencesError.sandboxed }
        for command in Self.commands(for: recommendations) {
            try runner(command.executable, command.arguments)
        }
    }

    static let restartDockCommand: (executable: String, arguments: [String]) = ("/usr/bin/killall", ["Dock"])

    /// macOS's own defaults for the keys the setup guide writes. `autohide-delay` is deleted rather
    /// than written, because "unset" is what a Mac that never changed it has.
    static let restoreCommands: [(executable: String, arguments: [String])] = [
        ("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "false"]),
        ("/usr/bin/defaults", ["write", "com.apple.dock", "mineffect", "-string", "genie"]),
        ("/usr/bin/defaults", ["write", "com.apple.dock", "minimize-to-application", "-bool", "false"]),
    ]

    func restoreDefaults() throws {
        guard isAvailable else { throw NativeDockPreferencesError.sandboxed }
        for command in Self.restoreCommands {
            try runner(command.executable, command.arguments)
        }
        // Fails when the key was never set, which is already the default.
        try? runner("/usr/bin/defaults", ["delete", "com.apple.dock", "autohide-delay"])
        try runner(Self.restartDockCommand.executable, Self.restartDockCommand.arguments)
    }

    static func commands(for delay: Double) -> [(executable: String, arguments: [String])] {
        autohideWriteCommands(for: delay) + [restartDockCommand]
    }

    /// Guide screen: each of the three items is optional; commands are ordered
    /// autohide → mineffect → minimize-to-application, with **a single `killall Dock`
    /// appended at the end**. Restarting after each item would flash the screen three
    /// times. Nothing checked returns an empty array: no write, no restart, no flash.
    static func commands(for recommendations: NativeDockRecommendations) -> [(executable: String, arguments: [String])] {
        guard !recommendations.isEmpty else { return [] }

        var commands: [(executable: String, arguments: [String])] = []
        if let delay = recommendations.autoHideDelay {
            commands += autohideWriteCommands(for: delay)
        }
        if recommendations.minimizeEffectScale {
            commands.append(("/usr/bin/defaults", ["write", "com.apple.dock", "mineffect", "-string", "scale"]))
        }
        if recommendations.minimizeIntoAppIcon {
            commands.append(("/usr/bin/defaults", ["write", "com.apple.dock", "minimize-to-application", "-bool", "true"]))
        }
        return commands + [restartDockCommand]
    }

    /// Writes only, without `killall`, so several write groups can be merged into one restart.
    private static func autohideWriteCommands(enabled: Bool) -> [(executable: String, arguments: [String])] {
        [("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", enabled ? "true" : "false"])]
    }

    private static func autohideWriteCommands(for delay: Double) -> [(executable: String, arguments: [String])] {
        if delay <= AppSettingsStore.neverHideDelay {
            return autohideWriteCommands(enabled: false)
        }

        let effectiveDelay = delay >= AppSettingsStore.neverWakeDelay
            ? noWakeDelay
            : AppSettingsStore.snapDelay(delay, fallbackForNonFinite: AppSettingsStore.defaultNativeDockAutoHideDelay)
        return [
            ("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", "true"]),
            ("/usr/bin/defaults", ["write", "com.apple.dock", "autohide-delay", "-float", String(format: "%.1f", effectiveDelay)]),
        ]
    }

    private static func runProcess(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NativeDockPreferencesError.commandFailed(executable: executable, status: process.terminationStatus)
        }
    }

    nonisolated private static func strictBooleanValue(_ value: Any) -> Bool? {
        DefaultsValueParsing.strictBooleanValue(value)
    }

    nonisolated private static func finiteNumericValue(_ value: Any) -> Double? {
        DefaultsValueParsing.finiteNumericValue(value)
    }
}

/// Frozen keys: the "hide completely" of `d08e8d6` used these three keys to record the exact
/// delay before hiding. With the slider back this snapshot is no longer needed, but it is **not
/// read, written or deleted**: existing users' machines may hold exact old values (e.g. 0.75,
/// which the slider's 0.1 step cannot express), and deleting them would lose the value and break
/// the data boundary of `git revert d08e8d6`. Left as orphan keys, harmless. A lossy migration
/// needs explicit sign-off first. Only the names are kept here, to prevent future key collisions.
///
/// - `com.tungsten.edge.nativeDock.restoreDelay.captured`
/// - `com.tungsten.edge.nativeDock.restoreDelay.present`
/// - `com.tungsten.edge.nativeDock.restoreDelay.value`

enum NativeDockPreferencesError: LocalizedError {
    case sandboxed
    case commandFailed(executable: String, status: Int32)

    var errorDescription: String? {
        switch self {
        case .sandboxed:
            return String(localized: "Dock settings can’t be changed directly from a sandboxed environment.")
        case .commandFailed(let executable, let status):
            return String(format: String(localized: "%@ failed (status code %d)."), executable, status)
        }
    }
}
