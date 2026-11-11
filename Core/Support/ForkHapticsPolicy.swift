import Foundation

/// fork: when the trackpad taps as the pointer moves over the bar (`AppSettingsStore.hapticFeedback`).
enum ForkHapticsPolicy {
    /// Whether the pointer arriving on the chip with this id gets a tap: the app and window cards, the
    /// kept and messaging app icons. Folders, the shelf, the trash and the gaps do not; they are not apps.
    static func tapsOnHover(ofChipID id: String) -> Bool {
        if id.isEmpty || id == "shelf" || id == "trash" { return false }
        if id.hasPrefix("folder-") || id.hasPrefix("extghost-") || id.hasPrefix("zone-divider") { return false }
        return true
    }
}
