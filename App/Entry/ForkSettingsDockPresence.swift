import AppKit

/// fork: gives the Settings window a card on the bar by making the app a regular app while it is
/// open. The decisions are `ForkSettingsDockPolicy`.
@MainActor
final class ForkSettingsDockPresence {
    private var switchedByUs = false

    func settingsWillShow() {
        guard ForkSettingsDockPolicy.shouldSwitchToRegular(isAccessory: NSApp.activationPolicy() == .accessory) else { return }
        if NSApp.setActivationPolicy(.regular) {
            switchedByUs = true
            notifyPolicyChanged()
        }
    }

    func settingsDidClose(fromOutside: Bool) {
        defer { switchedByUs = false }
        guard ForkSettingsDockPolicy.shouldRestoreAccessory(
            switchedByUs: switchedByUs,
            isRegular: NSApp.activationPolicy() == .regular,
            closedFromOutside: fromOutside
        ) else { return }
        NSApp.setActivationPolicy(.accessory)
        notifyPolicyChanged()
    }

    /// A policy flip posts no workspace notification, and the store would only notice at its next
    /// sweep: the Settings card would linger for about two seconds after closing. Read it again now,
    /// and once more shortly after in case the system has not applied the change yet.
    private func notifyPolicyChanged() {
        ForkSettingsContext.activationPolicyDidChange?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            ForkSettingsContext.activationPolicyDidChange?()
        }
    }
}
