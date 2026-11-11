import Foundation

/// Every default NitiaDock changes relative to Tungsten Edge, in one place. Each entry names the
/// upstream value.
enum ForkDefaults {
    /// Upstream: `true` (the shelf chip leads the folder zone).
    static let showShelf = false
    /// Upstream has no such setting: the drawer capsule is always shown, which equals `true`.
    static let showDrawer = false
    /// Middle-click on a Finder or browser card opens a window / closes the clicked browser window.
    /// Upstream: a middle-click on an app card does nothing (it only previews folders and Finder
    /// windows), which equals `false`.
    static let middleClickActions = true
    /// Sparkle runs against NitiaDock's own appcast on GitHub. Automatic checks are opt-in: Sparkle
    /// asks on the second launch. `ForkOfflineTests` fails if another network path appears.
    static let updatesEnabled = true
    /// Whether a fresh install ticks "Keep in Dock" for Finder. Upstream: `true`.
    /// macOS keeps Finder running at all times, so a kept Finder is a permanent icon with a running
    /// dot, even with every Finder window closed; on a Windows-style taskbar that reads as a window
    /// that will not go away. Unticked, Finder shows its window cards while it has windows and
    /// nothing otherwise. The checkbox is still there (right-click a Finder card > Keep in Dock).
    static let keepsFinderByDefault = false
    /// Apps that get an unread badge in addition to upstream's built-in messaging list
    /// (`MessagingAppStore.builtinMessagingIDs`, which already has Teams, Slack and Messages).
    /// Upstream has no such list, which equals `[]`. This is only the seed: the list is
    /// user-editable in Settings > Badges.
    static let extraBadgeBundleIDs = ["com.microsoft.Outlook", "com.apple.mail"]
}

/// fork: the product name, read from the bundle so no source file has to spell it.
///
/// TRADEMARK.md reserves upstream's name, and the fork has been renamed once already; both are
/// reasons not to scatter literals. Localized UI text still goes through the string catalog
/// (`Scripts/fork_rebrand_strings.py`); this is for the few places that bypass it.
enum ForkBranding {
    static let fallbackName = "NitiaDock"
    static var appName: String {
        let info = Bundle.main.localizedInfoDictionary ?? [:]
        return (info["CFBundleDisplayName"] as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? fallbackName
    }

    static let repositoryURL = URL(string: "https://github.com/Tripchipp/nitiadock")!
    static let changelogURL = URL(string: "https://github.com/Tripchipp/nitiadock/blob/main/CHANGELOG.md")!
    static let upstreamURL = URL(string: "https://github.com/moonbai-studio/tungsten-edge")!
    static let licenseURL = URL(string: "https://github.com/Tripchipp/nitiadock/blob/main/LICENSE")!

    /// A new bug report on GitHub with the version filled in. Issue forms take a field's id as a
    /// query parameter; only the app and macOS versions are passed, nothing personal.
    static func feedbackURL(version: String?) -> URL {
        var components = URLComponents(string: "https://github.com/Tripchipp/nitiadock/issues/new")!
        let os = ProcessInfo.processInfo.operatingSystemVersion
        components.queryItems = [
            URLQueryItem(name: "template", value: "bug_report.yml"),
            URLQueryItem(name: "app-version", value: version ?? ""),
            URLQueryItem(name: "macos-version", value: "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
        ]
        return components.url ?? repositoryURL
    }

    /// The settings window's title, shown in Mission Control and on the taskbar card.
    static var settingsTitle: String {
        String(format: String(localized: "%@ Settings"), appName)
    }
}
