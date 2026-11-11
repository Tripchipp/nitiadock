import Foundation

/// fork: whether an app's "running, but no windows" icon belongs on the bar.
///
/// Some menu-bar apps (LuLu, ItsyPad, many others) are background apps that turn themselves into a
/// regular Dock app only while a window is open, and back again when it closes. The real Dock drops
/// their icon at that moment. Upstream's window tracker checks "is this a regular app?" once, when it
/// first takes the app in, and from then on gives every tracked app without windows an app-level
/// icon until the process exits. So such an app stays on the bar with a running dot although, to
/// macOS, it has no Dock presence any more (reported 2026-09-19).
///
/// `RunningApplicationStore` does follow the policy change: it holds regular apps only, and its
/// workspace sweep drops a process that stopped being regular. So the strip shows a windowless
/// app's icon only while the store still lists its bundle id. Window cards are never affected; an
/// app that has a window is shown whatever its activation policy says.
enum ForkFallbackVisibility {
    static func shows(isAppLevelFallback: Bool, bundleID: String?, runningRegularBundleIDs: Set<String>) -> Bool {
        guard isAppLevelFallback, let bundleID, !bundleID.isEmpty else { return true }
        return runningRegularBundleIDs.contains(bundleID)
    }
}
