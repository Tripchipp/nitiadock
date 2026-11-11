import SwiftUI

// MARK: - Displays

struct SettingsDisplaysPage: View {
    @ObservedObject var store: AppSettingsStore

    /// "Follow the pointer" or one connected display, for a single taskbar.
    private enum Target: Hashable {
        case followPointer
        case display(uuid: String)
    }

    var body: some View {
        let choice = Binding<ForkMultiDisplayChoice>(
            get: { ForkMultiDisplayChoice(placement: store.taskbarScreenPlacement) },
            set: { store.setTaskbarScreenPlacement($0.placement(replacing: store.taskbarScreenPlacement)) }
        )
        SettingsPage(page: .displays, subtitle: String(localized: "These only matter when more than one display is connected.")) {
            SettingsCard {
                SettingsPickerRow(
                    symbol: "display.2", tint: .teal,
                    title: String(localized: "With more than one display"),
                    subtitle: choiceSubtitle(choice.wrappedValue),
                    selection: choice,
                    options: ForkMultiDisplayChoice.allCases.map { ($0, $0.title) },
                    width: 240
                )
                SettingsDivider()
                if choice.wrappedValue == .singleBar {
                    SettingsPickerRow(
                        symbol: "pin.fill", tint: .orange,
                        title: String(localized: "Show the taskbar on"),
                        subtitle: String(localized: "Pick a display, or let the taskbar move to the display where you rest the pointer at the bottom edge."),
                        selection: Binding(get: { target }, set: setTarget),
                        options: targetOptions,
                        width: 240
                    )
                } else {
                    SettingsToggleRow(
                        symbol: "rectangle.split.2x1", tint: .indigo,
                        title: String(localized: "Windows only on their own display"),
                        subtitle: String(localized: "A window gets a card only on the taskbar of the display it is on. The other taskbars show the app as a single icon."),
                        isOn: Binding(get: { store.collapseForeignWindows }, set: store.setCollapseForeignWindows)
                    )
                }
            }
        }
    }

    private func choiceSubtitle(_ choice: ForkMultiDisplayChoice) -> String {
        switch choice {
        case .eachDisplayOwnApps: return String(localized: "A taskbar on every display, each listing the windows on that display.")
        case .sameOnEveryDisplay: return String(localized: "A taskbar on every display, all listing every window.")
        case .singleBar: return String(localized: "A single taskbar.")
        }
    }

    private var target: Target {
        if case .pinned(let selection) = store.taskbarScreenPlacement { return .display(uuid: selection.uuid) }
        return .followPointer
    }

    private var screens: [(uuid: String, title: String)] { ForkSettingsContext.connectedScreens() }

    private var targetOptions: [(value: Target, title: String)] {
        var options: [(value: Target, title: String)] = [(.followPointer, String(localized: "Where the pointer is"))]
        options += screens.map { (Target.display(uuid: $0.uuid), $0.title) }
        // A pinned display that is unplugged right now stays selectable, so the picker never lies.
        if case .pinned(let pinned) = store.taskbarScreenPlacement, !screens.contains(where: { $0.uuid == pinned.uuid }) {
            options.append((.display(uuid: pinned.uuid), String(format: String(localized: "%@ (disconnected)"), pinned.name)))
        }
        return options
    }

    private func setTarget(_ target: Target) {
        switch target {
        case .followPointer:
            store.setTaskbarScreenPlacement(.followMouse)
        case .display(let uuid):
            let name = screens.first(where: { $0.uuid == uuid })?.title
                ?? store.taskbarScreenPlacement.pinnedSelection?.name ?? ""
            store.setTaskbarScreenPlacement(.pinned(PinnedScreenSelection(uuid: uuid, name: name)))
        }
    }
}

extension ForkMultiDisplayChoice {
    var title: String {
        switch self {
        case .eachDisplayOwnApps: return String(localized: "A taskbar per display")
        case .sameOnEveryDisplay: return String(localized: "The same taskbar everywhere")
        case .singleBar: return String(localized: "One taskbar")
        }
    }
}

// MARK: - Shelf, Drawer & Trash

struct SettingsExtrasPage: View {
    @ObservedObject var store: AppSettingsStore

    var body: some View {
        SettingsPage(page: .extras, subtitle: String(localized: "Optional items at the ends of the taskbar. Off, they give their room to window cards.")) {
            SettingsCard {
                SettingsToggleRow(
                    symbol: "tray.full.fill", tint: .orange,
                    title: String(localized: "Shelf"),
                    subtitle: String(localized: "Drop files on the taskbar to keep them at hand. The shelf keeps a link, the files stay where they are."),
                    isOn: Binding(get: { store.showShelf }, set: store.setShowShelf)
                )
                SettingsDivider()
                SettingsToggleRow(
                    symbol: "archivebox.fill", tint: .yellow,
                    title: String(localized: "Drawer"),
                    subtitle: String(localized: "A button at the right end that holds apps you rarely use. Right-click an app to move it there."),
                    isOn: Binding(get: { store.showDrawer }, set: store.setShowDrawer)
                )
                SettingsDivider()
                SettingsToggleRow(
                    symbol: "trash.fill", tint: .gray,
                    title: String(localized: "Trash"),
                    subtitle: String(localized: "The Trash, as on the Dock. Drop files on it to delete them."),
                    isOn: Binding(get: { store.showTrash }, set: store.setShowTrash)
                )
            }
        }
    }
}

// MARK: - Mouse & Trackpad

struct SettingsMousePage: View {
    @ObservedObject var store: AppSettingsStore

    var body: some View {
        SettingsPage(page: .mouse) {
            SettingsCard {
                SettingsToggleRow(
                    symbol: "text.bubble.fill", tint: .blue,
                    title: String(localized: "Show app names on hover"),
                    subtitle: String(localized: "A label with the app’s name above the icon under the pointer."),
                    isOn: Binding(
                        get: { store.hoverStyle.isExpressive },
                        set: { store.setHoverStyle($0 ? .standard : .quiet) }
                    )
                )
                SettingsDivider()
                SettingsToggleRow(
                    symbol: "computermouse.fill", tint: .purple,
                    title: String(localized: "Middle-click for a new window"),
                    subtitle: String(localized: "On Finder or a browser, a middle-click opens a new window. On a browser window, it closes that window."),
                    isOn: Binding(get: { store.middleClickActions }, set: store.setMiddleClickActions)
                )
                SettingsDivider()
                SettingsToggleRow(
                    symbol: "hand.tap.fill", tint: .pink,
                    title: String(localized: "Haptic feedback"),
                    subtitle: String(localized: "A light tap on the trackpad as the pointer moves from one item to the next."),
                    info: String(localized: "Needs a Force Touch trackpad with your finger on it. A mouse feels nothing."),
                    isOn: Binding(get: { store.hapticFeedback }, set: store.setHapticFeedback)
                )
            }
        }
    }
}

// MARK: - Window management

struct SettingsWindowManagementPage: View {
    @ObservedObject var store: AppSettingsStore

    var body: some View {
        SettingsPage(page: .windows) {
            SettingsCard(title: String(localized: "Keeping windows clear of the taskbar")) {
                SettingsToggleRow(
                    symbol: "arrow.up.to.line", tint: .purple,
                    title: String(localized: "Keep maximized windows above the taskbar"),
                    subtitle: String(localized: "A window that fills the screen stops at the top of the taskbar."),
                    isOn: Binding(get: { store.windowLiftEnabled }, set: store.setWindowLiftEnabled)
                )
                SettingsDivider()
                SettingsToggleRow(
                    symbol: "rectangle.bottomthird.inset.filled", tint: .indigo,
                    title: String(localized: "Reserve space for the taskbar"),
                    subtitle: String(localized: "Moves or shrinks the front window when it would end up under the taskbar."),
                    info: String(localized: "Only while the taskbar is always visible. Windows are not moved back when you turn this off."),
                    isOn: Binding(get: { store.reserveScreenSpace }, set: store.setReserveScreenSpace)
                )
            }

            SettingsCard(title: String(localized: "Full screen")) {
                SettingsToggleRow(
                    symbol: "arrow.up.left.and.arrow.down.right", tint: .green,
                    title: String(localized: "Smooth full-screen switching"),
                    subtitle: String(localized: "Hides the taskbar a moment before a window goes full screen, so it does not flash."),
                    info: String(localized: "To do this, NitiaDock watches for the four ways into full screen: the green window button, Control-Command-F, Control-Left or Right Arrow, and a three-finger swipe. It looks at clicks, key presses and gestures only to recognise these. What you type is never recorded, logged or sent anywhere. Turning this off stops the watching completely."),
                    isOn: Binding(get: { store.fullscreenIntentEnabled }, set: store.setFullscreenIntentEnabled)
                )
            }
        }
    }
}
