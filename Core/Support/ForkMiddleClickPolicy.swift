import Foundation

/// What a middle-click on an app card on the bar does (`AppSettingsStore.middleClickActions`).
enum ForkMiddleClickAction: Equatable {
    /// Open an extra window of the app (the card menu's New Window).
    case newWindow
    /// Close only the window the card stands for.
    case closeWindow
    /// Not ours: upstream's middle-click (the folder/Finder preview, which for other apps does nothing).
    case fallThrough
}

/// fork: middle-click on a Finder or browser card.
///
/// An app is never quit by a middle-click. Finder opens another window; a browser opens another
/// window while it has one, and closes the clicked one once it has several. Every other app does
/// nothing, so a stray middle-click cannot lose work.
enum ForkMiddleClickPolicy {
    /// Browsers whose cards get the open/close behaviour. Bundle ids of the stable, beta and nightly
    /// builds that share a browser's windowing.
    static let browserBundleIDs: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.dev", "com.brave.Browser.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary",
        "company.thebrowser.Browser",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    static func isBrowser(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return browserBundleIDs.contains(bundleID)
    }

    /// - `appWindowCount`: how many real windows the app has right now (cards, not counting the
    ///   windowless app-level card).
    static func action(
        enabled: Bool,
        bundleID: String?,
        isAppLevelFallback: Bool,
        appWindowCount: Int,
        ownBundleID: String? = Bundle.main.bundleIdentifier
    ) -> ForkMiddleClickAction {
        guard enabled, let bundleID, !bundleID.isEmpty, bundleID != ownBundleID else { return .fallThrough }
        if FinderTaskbarPolicy.isFinder(bundleID) { return .newWindow }
        guard isBrowser(bundleID) else { return .fallThrough }
        if isAppLevelFallback || appWindowCount <= 1 { return .newWindow }
        return .closeWindow
    }
}
