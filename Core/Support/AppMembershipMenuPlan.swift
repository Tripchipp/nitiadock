import Foundation

/// **Pure decision layer** of the membership menu: given the surface the icon is on (strip / drawer) + Finder
/// / kept / messaging state, produces the membership items that should appear (order = render order, no
/// closures). Pure logic for unit testing; mapping `Item` to menu items with actions is done by
/// `LauncherMembershipItem.items`, consumed by all four menu construction paths.
///
/// Fixed matrix (the messaging item's title is constant; membership is expressed by the native checkmark):
/// - strip regular: Keep in Dock + Pin to Messaging Zone (unchecked)
/// - strip messaging: Keep in Dock + Pin to Messaging Zone (checked)
/// - drawer regular: Keep in Dock only
/// - drawer messaging: Keep in Dock + Pin to Messaging Zone (checked)
/// - Finder: Keep in Dock only (since 2026-08-20 Finder is part of the unified keep checkmark, but still
///   cannot enter the messaging zone)
enum AppMembershipMenuPlan {
    enum Surface: Equatable { case strip, drawer }

    /// Display state without closures, for the render layer to map to concrete actions.
    enum Item: Equatable {
        case keep(isChecked: Bool)
        case messaging(isChecked: Bool)
    }

    static func items(surface: Surface,
                      isFinder: Bool,
                      isKept: Bool,
                      isMessaging: Bool) -> [Item] {
        // Finder gets only the keep checkmark: a messaging zone icon stands for "this app's main window", and
        // Finder has no such semantics.
        if isFinder { return [.keep(isChecked: isKept)] }
        // The keep checkmark always comes first, the messaging command after it.
        var items: [Item] = [.keep(isChecked: isKept)]
        if isMessaging {
            items.append(.messaging(isChecked: true))
        } else if surface == .strip {
            // "Pin to Messaging Zone" appears only for regular apps on the strip: in the drawer the mark does
            // not change placement (the drawer has higher priority) and has no visible effect, so the drawer
            // surface does not offer the command.
            items.append(.messaging(isChecked: false))
        }
        return items
    }
}
