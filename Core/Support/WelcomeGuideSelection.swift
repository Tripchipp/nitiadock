import Foundation

/// State of the three checkboxes on the first-run guide screen.
///
/// All checked by default (`recommended`). All three belong to the same thing, "hand the system Dock over to
/// NitiaDock", but **may be checked separately**: this writes someone else's system preferences, so the user
/// gets room to decline any one of them (decided 2026-08-28).
struct WelcomeGuideSelection: Equatable {
    var hidesDock: Bool
    var usesScaleMinimizeEffect: Bool
    var minimizesIntoAppIcon: Bool

    static let recommended = WelcomeGuideSelection(
        hidesDock: true,
        usesScaleMinimizeEffect: true,
        minimizesIntoAppIcon: true
    )

    var isEmpty: Bool { !hidesDock && !usesScaleMinimizeEffect && !minimizesIntoAppIcon }
}

/// Which items one recommended-settings write touches. `autoHideDelay == nil` means **do not touch**
/// `autohide` / `autohide-delay` at all, not "write a default": the two mean entirely different things to the
/// four-quadrant read-back.
struct NativeDockRecommendations: Equatable {
    var autoHideDelay: Double?
    var minimizeEffectScale: Bool
    var minimizeIntoAppIcon: Bool

    var isEmpty: Bool { autoHideDelay == nil && !minimizeEffectScale && !minimizeIntoAppIcon }
}

extension WelcomeGuideSelection {
    /// Checkboxes -> which keys to write. **This is the easiest place in the whole chain to wire the two
    /// minimize options backwards**, so it is its own pure function with unit tests
    /// (`WelcomeGuideDecisionTests`); testing only `NativeDockRecommendations` would not catch a swap.
    ///
    /// - Parameter hideDelay: the delay level used when "Hide system Dock" is checked, passed by the caller
    ///   as `AppSettingsStore.neverWakeDelay`: Core should not know App-layer constants.
    func recommendations(hideDelay: Double) -> NativeDockRecommendations {
        NativeDockRecommendations(
            autoHideDelay: hidesDock ? hideDelay : nil,
            minimizeEffectScale: usesScaleMinimizeEffect,
            minimizeIntoAppIcon: minimizesIntoAppIcon
        )
    }
}
