import AppKit

/// fork: a tap on the trackpad as the pointer lands on an app in the bar. Off by default
/// (Settings > Advanced > Bar); `AppDelegate.startForkBindings` keeps `isEnabled` in step with the setting.
///
/// `NSHapticFeedbackManager` only does something on a Force Touch trackpad and while a finger is on
/// it, so with a mouse this is silent by itself.
@MainActor
enum ForkHaptics {
    static var isEnabled = false

    /// The pointer moved onto the chip `id` (nil when it left every chip).
    static func hoverChanged(to id: String?) {
        guard isEnabled, let id, ForkHapticsPolicy.tapsOnHover(ofChipID: id) else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
