import Foundation

/// fork: the three answers Settings > Advanced > "Multiple displays" offers, folded out of upstream's
/// four `TaskbarScreenPlacement`s. The status menu keeps the full list (including which display a
/// pinned bar sits on); Settings only needs to say how the bar behaves once there is more than one.
enum ForkMultiDisplayChoice: CaseIterable, Equatable {
    /// One bar on every display, each listing only the windows on its own display.
    case eachDisplayOwnApps
    /// One bar on every display, all listing the same windows.
    case sameOnEveryDisplay
    /// A single bar (follows the pointer, or pinned to one display from the status menu).
    case singleBar

    init(placement: TaskbarScreenPlacement) {
        switch placement {
        case .allScreensPerDisplay: self = .eachDisplayOwnApps
        case .allScreens: self = .sameOnEveryDisplay
        case .followMouse, .pinned: self = .singleBar
        }
    }

    /// The placement to store when this choice is picked while `current` is in force. Picking
    /// "single bar" while already single keeps a pinned display pinned instead of dropping it.
    func placement(replacing current: TaskbarScreenPlacement) -> TaskbarScreenPlacement {
        switch self {
        case .eachDisplayOwnApps: return .allScreensPerDisplay
        case .sameOnEveryDisplay: return .allScreens
        case .singleBar: return Self(placement: current) == .singleBar ? current : .followMouse
        }
    }
}
