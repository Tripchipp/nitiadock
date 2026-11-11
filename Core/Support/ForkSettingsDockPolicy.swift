import Foundation

/// fork: when the app takes a Dock/bar presence for its Settings window.
///
/// NitiaDock runs as an accessory app, which the window tracker ignores (it admits regular apps
/// only), so an open Settings window was a loose window with no card on the bar. While Settings is
/// open the app becomes a regular app, so the window shows up like any other app's window, and it
/// goes back to accessory when Settings closes. The permission state machine owns the activation
/// policy while permissions are being asked for or were lost; this never fights it.
enum ForkSettingsDockPolicy {
    /// Switch only from accessory. Already regular means the permission flow (or something else)
    /// owns the policy, and giving it back later would not be ours to do.
    static func shouldSwitchToRegular(isAccessory: Bool) -> Bool {
        isAccessory
    }

    /// Give the policy back only if this window switched it, the app is still regular, and the close
    /// was the user's. `close()` from outside the window (permission loss) hands the policy over to
    /// the permission machine, which has just set `regular` for its guide window.
    static func shouldRestoreAccessory(switchedByUs: Bool, isRegular: Bool, closedFromOutside: Bool) -> Bool {
        switchedByUs && isRegular && !closedFromOutside
    }
}
