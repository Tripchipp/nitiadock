import Combine
import Foundation

/// The pages of the settings window, in sidebar order. Pure Foundation/Combine: the test target
/// compiles this file too. Symbols are all available from macOS 12.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case appearance
    case windowCards
    case displays
    case badges
    case extras
    case mouse
    case windows
    case privacy
    case about

    var id: String { rawValue }

    enum Group: CaseIterable {
        case essentials
        case features
        case app

        var title: String {
            switch self {
            case .essentials: return String(localized: "Essentials")
            case .features: return String(localized: "Features")
            case .app: return String(localized: "App")
            }
        }

        var pages: [SettingsTab] {
            SettingsTab.allCases.filter { $0.group == self }
        }
    }

    var group: Group {
        switch self {
        case .general, .appearance, .windowCards, .displays: return .essentials
        case .badges, .extras, .mouse, .windows: return .features
        case .privacy, .about: return .app
        }
    }

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .appearance: return String(localized: "Appearance")
        case .windowCards: return String(localized: "Window Cards")
        case .displays: return String(localized: "Displays")
        case .badges: return String(localized: "Badges")
        case .extras: return String(localized: "Shelf, Drawer & Trash")
        case .mouse: return String(localized: "Mouse & Trackpad")
        case .windows: return String(localized: "Window Management")
        case .privacy: return String(localized: "Privacy & Permissions")
        case .about: return String(localized: "About")
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape.fill"
        case .appearance: return "paintbrush.fill"
        case .windowCards: return "rectangle.grid.1x2.fill"
        case .displays: return "display.2"
        case .badges: return "app.badge.fill"
        case .extras: return "tray.full.fill"
        case .mouse: return "computermouse.fill"
        case .windows: return "macwindow.on.rectangle"
        case .privacy: return "hand.raised.fill"
        case .about: return "info.circle.fill"
        }
    }

    /// The tile colour behind the page's symbol, as in System Settings.
    var tint: SettingsTint {
        switch self {
        case .general: return .gray
        case .appearance: return .blue
        case .windowCards: return .indigo
        case .displays: return .teal
        case .badges: return .red
        case .extras: return .orange
        case .mouse: return .gray
        case .windows: return .purple
        case .privacy: return .blue
        case .about: return .gray
        }
    }
}

/// A named tint, mapped to a SwiftUI colour in the view layer (this file stays Foundation-only).
enum SettingsTint {
    case gray, blue, indigo, teal, red, orange, purple, green, pink, yellow
}

/// The selected page, shared by the window controller and the SwiftUI content. Remembered across
/// launches, so the window reopens where it was left.
@MainActor
final class SettingsTabState: ObservableObject {
    static let defaultsKey = "no.thilip.nitiadock.settings.selectedPage"

    @Published var selected: SettingsTab {
        didSet { defaults.set(selected.rawValue, forKey: Self.defaultsKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selected = defaults.string(forKey: Self.defaultsKey).flatMap(SettingsTab.init(rawValue:)) ?? .general
    }
}
