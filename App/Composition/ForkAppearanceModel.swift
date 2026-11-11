import Combine
import Foundation

/// fork: the live `ForkAppearance`, shared by every view that draws with it.
///
/// Why a shared model and not the SwiftUI environment: chips are hosted in several separate
/// `NSHostingView` roots (strip, capsule, drawer, the drag-carrier snapshot), and the card-width
/// metrics (`WindowTitleTextMetrics`, `ChipPillMetrics`) are static functions that hover
/// hit-testing and tooltip anchoring call with no view in sight. An environment value would have to
/// be injected at every root and threaded through every metrics call site in upstream's code; a
/// missed one renders a drag copy or anchors a tooltip with the wrong width. One shared value keeps
/// the drawn card and the computed card identical by construction.
///
/// `AppSettingsStore` owns persistence and pushes changes here. Views observe `shared`; static
/// metrics read `current`.
@MainActor
final class ForkAppearanceModel: ObservableObject {
    static let shared = ForkAppearanceModel()

    @Published private(set) var value: ForkAppearance = .upstream
    /// Whether macOS itself is in Dark Mode. The app is pinned to the light appearance, so this is
    /// read from the system preference, not from any view's `colorScheme`. Read by the card tint
    /// ("Follow system") and by the settings window, which follows the system appearance.
    @Published private(set) var systemIsDark = false

    /// Same value as `shared.value`, readable from the nonisolated static metrics. Written only on
    /// the main actor, in `apply(_:)`, before the published value changes, so a view re-rendering
    /// because of the change already measures with the new value.
    nonisolated(unsafe) private(set) static var current: ForkAppearance = .upstream

    func apply(_ value: ForkAppearance) {
        guard self.value != value else { return }
        Self.current = value
        self.value = value
    }

    func setSystemIsDark(_ isDark: Bool) {
        guard systemIsDark != isDark else { return }
        systemIsDark = isDark
    }

    /// Test hook: puts the shared state back to upstream.
    func resetForTesting() {
        Self.current = .upstream
        value = .upstream
        systemIsDark = false
    }
}
