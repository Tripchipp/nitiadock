import AppKit
import Combine
import Sparkle

/// Thin wrapper around Sparkle. **The two UI entry points (status bar menu / settings
/// window) know only this object**; do not let `SPUStandardUpdaterController` spread to
/// three places. Same discipline as the old `UpdateCheckMenuState` keeping the "in-flight
/// guard" in the shared layer, for the same reason: separate copies eventually drift.
///
/// ## Why gentle reminders must be implemented
///
/// NitiaDock is an `.accessory` app (no Dock icon). Sparkle's own header
/// (`SPUStandardUserDriverDelegate.h`) hardcodes the default behavior for such apps:
///
/// > For background running applications, when `immediateFocus` is `NO` the standard user
/// > driver will always want to show the update alert immediately, **but behind other
/// > running applications**.
///
/// So when a **scheduled check** finds a new version, the update window appears silently behind
/// all windows and the user never sees it. Same trap as the "update check does nothing" report
/// from a real user on 2026-07-29: that time an `NSAlert` was shown without `activate` first,
/// fixed with `runModalInForeground`; this time the framework differs but the cause is identical.
///
/// So this declares gentle reminder support and brings the app to the front when
/// an update is actually shown. The path where the user clicks "Check for Updates"
/// is unaffected (Sparkle guarantees user-initiated checks come to the front).
@MainActor
final class SparkleUpdateService: NSObject, ObservableObject, UpdateControlling {
    /// Whether Sparkle can start a check (false while checking or downloading).
    /// The "Check for Updates" buttons of both UIs read it; replaces the old hand-written in-flight guard.
    @Published private(set) var canCheckForUpdates = false

    /// Version number of a new release found by a scheduled check and not yet handled
    /// (`nil` = none). The status bar uses it to decide whether to draw the dot on the
    /// icon and whether the menu row reads "Check for Updates…" or "Install 0.9.2…".
    ///
    /// ⚠️ **Do not clear it when the user merely glanced at the update window.** The old code cleared it on
    /// `standardUserDriverDidReceiveUserAttention`, so after the user closed the window the UI kept no trace
    /// at all, which was half of the "no proactive notification" report of 2026-08-20. It is withdrawn only
    /// when **the user actually made a choice** (installed / skipped) or **a later check finds no update**.
    @Published private(set) var pendingUpdateVersion: String?

    private var controller: SPUStandardUpdaterController?
    private var canCheckObservation: NSKeyValueObservation?

    /// The version the app has already come to the front for once. **In memory only**:
    /// not persisting it adds no new data boundary; the cost is one more direct
    /// reminder for the same version after restarting NitiaDock, which is acceptable.
    private var announcedVersion: String?

    /// Automatic update checks. The settings window checkbox reads and writes it directly.
    ///
    /// The real value lives in Sparkle (`SUEnableAutomaticChecks` / user preferences); do **not** store a
    /// mirror in `AppSettingsStore`: two copies will drift, and Sparkle writes this preference itself.
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// `UpdateControlling`: flattens the SwiftUI change channel into a plain publisher,
    /// so `SettingsCoordinator` need not know whether this is an `ObservableObject`.
    var changes: AnyPublisher<Void, Never> {
        objectWillChange.map { _ in () }.eraseToAnyPublisher()
    }

    /// Starts the updater.
    ///
    /// ⚠️ **Call only on the normal run path of a non-temporary copy.** A temporary copy mounted in a DMG has
    /// no reason to update itself (it is gone on unmount) and would leave traces in the system. Same reason
    /// `AppDelegate` does not register the global hotkey or request system permissions for a temporary copy.
    func start() {
        guard controller == nil else { return }
        // updaterDelegate is also self: the status bar hint is withdrawn only
        // **after the user makes a choice**, and only updater-side callbacks
        // report "installed / skipped" and "no update found this round".
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        self.controller = controller
        // A feed URL left in the app's preferences would be used before the one in Info.plist.
        // NitiaDock never sets one, so anything there was written by something else: drop it.
        controller.updater.clearFeedURLFromUserDefaults()

        // canCheckForUpdates is published by Sparkle via KVO, not Combine. Bridged here for the two UIs.
        canCheckForUpdates = controller.updater.canCheckForUpdates
        canCheckObservation = controller.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] _, change in
            // Use only the Bool delivered by KVO (`.new` + `.initial` guarantee a value); do
            // not read `updater` back in this Sendable callback. It is a main-actor-isolated
            // object, which strict concurrency forbids touching from here.
            guard let value = change.newValue else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.canCheckForUpdates = value
            }
        }
    }

    /// User-initiated check. Sparkle ships the full UI (update available / up to date / check failed),
    /// so the custom-drawn copy of `UpdateCheckAlertContent` is no longer needed here.
    ///
    /// **The hint is not withdrawn here**: clicking only brings up the update window, and the user may
    /// close it again; withdrawal happens only in the "made a choice" and "no update left" callbacks.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

extension SparkleUpdateService: SPUStandardUserDriverDelegate {
    /// Declares that we handle gentle reminders ourselves.
    /// Without it Sparkle never calls the callbacks below.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Whether Sparkle should open the update window itself for this scheduled check.
    ///
    /// Returning `false` = "I will notify in my own UI, do not open a window", the hook Sparkle provides
    /// for gentle reminders. Decided by the pure `ScheduledUpdatePresentation`: a given version opens
    /// the window only the first time; after that the dot on the menu bar icon takes over.
    ///
    /// ⚠️ **No side effects allowed in this callback** (stated in the Sparkle
    /// header), so it only reads `announcedVersion`; recording is left to
    /// `willHandleShowingUpdate` below. User-initiated checks never reach this.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Sparkle calls this synchronous callback on the main thread; `assumeIsolated` only tells the
        // compiler that. It cannot become a Task, which would leave no return value to give here.
        MainActor.assumeIsolated {
            ScheduledUpdatePresentation.decide(
                version: update.displayVersionString,
                userInitiated: false,
                announcedVersion: announcedVersion
            ) == .announce
        }
    }

    /// Sparkle is about to show an update.
    ///
    /// `state.userInitiated == false` means this is the result of a **scheduled check**. For an
    /// `.accessory` app that update window sits behind all windows, so without activate there is
    /// effectively no notification (same cause as the 2026-07-29 "update check does nothing" case). So
    /// bring the app to the front the first time a version is seen; later rounds for the same version
    /// are stopped by the callback above before a window opens, leaving only the status bar dot.
    ///
    /// User-initiated checks do not activate: Sparkle already brings that path to the front.
    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        let userInitiated = state.userInitiated
        let version = update.displayVersionString
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Whether or not this round opens a window, the status bar must know a version is waiting.
            self.pendingUpdateVersion = version
            switch ScheduledUpdatePresentation.decide(
                version: version,
                userInitiated: userInitiated,
                announcedVersion: self.announcedVersion
            ) {
            case .announce:
                self.announcedVersion = version
                NSApp.activate(ignoringOtherApps: true)
            case .remindQuietly, .deferToSparkle:
                break
            }
        }
    }
}

extension SparkleUpdateService: SPUUpdaterDelegate {
    /// The user made a choice for this update: installed / skipped /
    /// remind me later. The first two withdraw the status bar hint.
    ///
    /// "Remind me later" (`.dismiss`) does **not** withdraw it: that means "noted, not now",
    /// so the dot should stay; otherwise it is back to "close the window and nothing remains".
    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        switch choice {
        case .install, .skip:
            pendingUpdateVersion = nil
        case .dismiss:
            break
        @unknown default:
            break
        }
    }

    /// This round found no update, so the user is already on the latest version
    /// (possibly installed manually), and the status bar hint should be withdrawn.
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        pendingUpdateVersion = nil
    }
}
