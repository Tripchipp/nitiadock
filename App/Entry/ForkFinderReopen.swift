import AppKit

/// fork: opens a Finder window when Finder is started from outside (Spotlight, Raycast) and comes
/// up without one. The decision is `ForkFinderReopenPolicy`; this only watches launches and acts.
@MainActor
final class ForkFinderReopen {
    static let shared = ForkFinderReopen()

    private let startedAt = Date()
    private var observer: NSObjectProtocol?
    private var checkedPIDs: Set<pid_t> = []

    /// Finder needs a moment to restore its own windows and to become active, so the check runs
    /// after a delay and a few times before it gives up.
    private let checkDelays: [TimeInterval] = [1.0, 2.0, 3.0]

    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  FinderTaskbarPolicy.isFinder(app.bundleIdentifier)
            else { return }
            Task { @MainActor [weak self] in self?.scheduleChecks(for: app) }
        }
    }

    private func scheduleChecks(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard checkedPIDs.insert(pid).inserted else { return }
        for (index, delay) in checkDelays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.check(app, isLastAttempt: index == (self?.checkDelays.count ?? 0) - 1)
            }
        }
    }

    private func check(_ app: NSRunningApplication, isLastAttempt: Bool) {
        guard !app.isTerminated, checkedPIDs.contains(app.processIdentifier) else { return }
        let infos = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]) ?? []
        let windowCount = ForkFinderReopenPolicy.onScreenWindowCount(in: infos, pid: app.processIdentifier)
        if windowCount > 0 {
            // Finder has a window (restored, or opened by whatever launched it): done.
            checkedPIDs.remove(app.processIdentifier)
            return
        }
        if ForkFinderReopenPolicy.shouldOpenWindow(
            isActive: app.isActive,
            onScreenWindowCount: windowCount,
            secondsSinceAppStart: Date().timeIntervalSince(startedAt)
        ) {
            checkedPIDs.remove(app.processIdentifier)
            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser)
        } else if isLastAttempt {
            checkedPIDs.remove(app.processIdentifier)
        }
    }
}
