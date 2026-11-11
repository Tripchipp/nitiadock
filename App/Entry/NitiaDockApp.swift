import SwiftUI

@main
struct NitiaDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // As early as possible: every app we launch afterwards inherits the environment as it is now.
        // Rationale in `ProcessEnvironmentScrub`.
        ProcessEnvironmentScrub.apply()
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.openSettings(nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
