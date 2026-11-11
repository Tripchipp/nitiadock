import Foundation

/// Pure decision layer for messaging zone **admission**: which
/// apps can currently have their main window recognized.
///
/// The messaging zone model is "one icon = the app's main window card", so "can the main
/// window be recognized" is itself the capability test for this zone.
/// `MessagingAppStore.autoRegister` uses it as the threshold for auto-marking: looking like
/// a messaging app is not enough, it must also be **correctly representable in this zone**.
///
/// The threshold blocks apps that can "never be recognized": Apple Messages is a Mac Catalyst
/// app whose window title is a UIScene session number, never equal to the app name; terminals
/// like Ghostty title windows with the command name, yet get mislabeled because their App Store
/// category is "Social Networking". In the messaging zone they would only get a launcher icon
/// that "can activate but not minimize", and their unabsorbed windows would be shown twice.
///
/// **Callers must use this only at first registration**: the decision reflects whether
/// recognition works "right now", not a stable property. With WeChat's main window closed only
/// the "Notes" window is left, which is equally unrecognizable at that moment; rechecking
/// every round would kick it out of the messaging zone and jump it back in on reopen.
/// Passing once puts it on the list permanently, with no recheck afterwards.
enum MessagingZoneAdmission {
    /// Read model of one window in the snapshot (only the three
    /// fields the decision needs, no dependency on UI layer types).
    struct WindowFact: Equatable {
        let bundleID: String
        let title: String
        let isAppLevelFallback: Bool

        init(bundleID: String, title: String, isAppLevelFallback: Bool) {
            self.bundleID = bundleID
            self.title = title
            self.isAppLevelFallback = isAppLevelFallback
        }
    }

    /// - Parameter titleMatchesAppName: `(title, bundleID) -> Bool`, injected as
    ///   a closure to keep the impure parts (looking up `NSRunningApplication` /
    ///   reading plists from disk / static caches) on the caller side.
    /// - Returns: The bundleIDs that currently have a real window whose title equals the app name.
    static func mainWindowIdentifiableBundleIDs(
        windows: [WindowFact],
        titleMatchesAppName: (String, String) -> Bool
    ) -> Set<String> {
        var result: Set<String> = []
        for window in windows {
            // app-* fallback items are not real windows and cannot prove the main window is recognizable.
            guard !window.isAppLevelFallback, !window.bundleID.isEmpty else { continue }
            guard !result.contains(window.bundleID) else { continue }
            if titleMatchesAppName(window.title, window.bundleID) {
                result.insert(window.bundleID)
            }
        }
        return result
    }
}
