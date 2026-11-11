import Combine
import Foundation

struct NativeDockApplyOutcome {
    let resolvedDelay: Double
    let error: Error?
}

/// Two ways changing the show/hide shortcut fails: rejected by pure validation (with
/// a reason) / Carbon registration failed (combination held by another app, etc.).
enum HotKeyChangeError: Error, Equatable {
    case rejected(HotKeyShortcutRejection)
    case registrationFailed
}

/// Injection point for the updater.
///
/// ⚠️ **This protocol exists to keep Sparkle out of the test target.**
/// `SettingsCoordinator.swift` is compiled into both the App and test targets, while
/// `SparkleUpdateService` needs `import Sparkle`; depending on the concrete type would force
/// the test target to link the framework too. Same reason the other three services in this
/// file (login item / system Dock / email subscription) are injected through protocols.
@MainActor
protocol UpdateControlling: AnyObject {
    /// Whether a check can be started now (false while checking / downloading).
    var canCheckForUpdates: Bool { get }
    /// Version number found by a scheduled check and still awaiting the
    /// user (`nil` = none). The status bar uses it to show the hint.
    var pendingUpdateVersion: String? { get }
    var automaticallyChecksForUpdates: Bool { get set }
    func checkForUpdates()
    /// Fires when any of the values above change, for the upper layer to forward to the UI.
    var changes: AnyPublisher<Void, Never> { get }
}

/// Action layer **shared** by the status bar menu and the settings window.
///
/// Deliberately narrowed to the three things that write outside this app: login item, system
/// Dock, update check. NitiaDock's own local switches (shelf / hover / lift avoidance /
/// taskbar size / wake delay) do not go through here: they are local values that take effect
/// immediately, and both UIs observe the same `AppSettingsStore`, so they cannot drift apart.
@MainActor
final class SettingsCoordinator: ObservableObject {
    /// Result of the latest system read or successful write by this app. System I/O runs on the service's
    /// dedicated queue; the menu and settings window show this cache first, then refresh asynchronously.
    @Published private(set) var launchAtLoginState: LaunchAtLoginState

    private let store: AppSettingsStore
    private let launchAtLoginService: LaunchAtLoginServicing
    private let nativeDockPreferencesService: NativeDockPreferencesServicing
    /// Updates go through Sparkle. **The in-flight guard is its job too**
    /// (`canCheckForUpdates`), so none is kept here. The old `UpdateCheckMenuState` existed
    /// because the two UIs each had an entry point, and separate guards would send two requests;
    /// now both UIs ask the same `SparkleUpdateService`, so that is satisfied automatically.
    private let updateService: any UpdateControlling
    /// The real registration entry point for rebinding
    /// (`GlobalHotKeyMonitor.update(shortcut:)`, held by AppDelegate). Injected as a
    /// closure: AppDelegate owns the monitor, and a temporary copy (DMG) has none.
    private let hotKeyRegistrar: (GlobalHotKeyShortcut) -> GlobalHotKeyMonitor.RegistrationStatus
    private var updateServiceSubscription: AnyCancellable?
    private var launchRefreshGeneration: UInt64 = 0
    private var nativeDockRefreshGeneration: UInt64 = 0
    private var nativeDockWriteInFlight = false

    init(
        store: AppSettingsStore,
        launchAtLoginService: LaunchAtLoginServicing,
        nativeDockPreferencesService: NativeDockPreferencesServicing,
        updateService: any UpdateControlling,
        hotKeyRegistrar: @escaping (GlobalHotKeyShortcut) -> GlobalHotKeyMonitor.RegistrationStatus
    ) {
        self.store = store
        self.launchAtLoginService = launchAtLoginService
        self.nativeDockPreferencesService = nativeDockPreferencesService
        self.updateService = updateService
        self.hotKeyRegistrar = hotKeyRegistrar
        // **The mirror only seeds the first frame; it is not the source of truth.**
        // `SMAppService.mainApp.status` is XPC, and a synchronous read in init would add that cost
        // to every UI construction. Every presentation entry point (menu `menuWillOpen`, settings
        // window `present()`, `applicationDidBecomeActive`) refreshes asynchronously right away,
        // so reading the local mirror here only gives the first frame something to show.
        //
        // The cost, stated plainly: if the user changed the login item in System Settings while
        // this app was not running, the first-frame checkbox may be wrong (`.requiresApproval`
        // also shows as `.on` at first); it self-heals within one refresh cycle. That is **never**
        // a reason to treat the mirror as long-term truth: `launchAtLoginState` is written only by
        // `refreshLaunchAtLoginState` and by the optimistic update after a successful write.
        launchAtLoginState = store.launchAtLogin ? .on : .off

        // `canCheckForUpdates` lives in `SparkleUpdateService`, but the two UIs observe this object.
        // Forwarding its changes here means callers do not have to watch two ObservableObjects.
        // (This channel feeds only the status bar menu and settings window, not the taskbar's render path.)
        updateServiceSubscription = updateService.changes
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: Login item

    /// Returning false means the result is stale or the task was
    /// cancelled; the caller must not use it to refresh on-screen UI.
    @discardableResult
    func refreshLaunchAtLoginState() async -> Bool {
        launchRefreshGeneration &+= 1
        let generation = launchRefreshGeneration
        let next = await launchAtLoginService.currentState()
        guard !Task.isCancelled, generation == launchRefreshGeneration else { return false }
        if launchAtLoginState != next { launchAtLoginState = next }
        return true
    }

    /// The local mirror is updated only on a **successful write**: the mirror
    /// means "the state we believe", and on a failed write the system did not
    /// change, so changing the mirror would make the next presentation lie.
    func setLaunchAtLogin(_ enabled: Bool) -> Result<Void, Error> {
        launchRefreshGeneration &+= 1
        do {
            try launchAtLoginService.setEnabled(enabled)
            store.setLaunchAtLogin(enabled)
            let optimistic: LaunchAtLoginState = enabled ? .on : .off
            if launchAtLoginState != optimistic { launchAtLoginState = optimistic }
            refreshLaunchAtLoginStateSoon()
            return .success(())
        } catch {
            refreshLaunchAtLoginStateSoon()
            return .failure(error)
        }
    }

    private func refreshLaunchAtLoginStateSoon() {
        Task { @MainActor [weak self] in
            _ = await self?.refreshLaunchAtLoginState()
        }
    }

    func openLoginItemsSettings() {
        launchAtLoginService.openSystemSettings()
    }

    // MARK: Show/hide shortcut

    /// The only entry point for rebinding: pure validation first (`HotKeyShortcutValidation`),
    /// then real registration, and **persist only after registration succeeds**; the reverse
    /// would let the stored key and the active key diverge. `nil` = restore the default ⌥⇧⌘D.
    /// On registration failure `GlobalHotKeyMonitor.update` has already fallen back to the old
    /// key, so nothing to clean up here; just report the failure to the UI.
    func applyEdgeToggleShortcut(_ stored: StoredHotKeyShortcut?) -> Result<Void, HotKeyChangeError> {
        let target: GlobalHotKeyShortcut
        if let stored {
            if let rejection = HotKeyShortcutValidation.validate(
                keyCode: stored.keyCode,
                carbonModifiers: stored.carbonModifiers
            ) {
                return .failure(.rejected(rejection))
            }
            target = GlobalHotKeyShortcut(stored: stored)
        } else {
            target = .edgeAutoHideMode
        }
        guard hotKeyRegistrar(target) == .registered else {
            return .failure(.registrationFailed)
        }
        store.setEdgeToggleShortcut(stored)
        return .success(())
    }

    // MARK: System Dock

    /// Only updates the local mirror so the UI matches the system value, and **never applies it in
    /// reverse**: presenting the settings UI once must not cause a `killall Dock`. No competing
    /// read is started during a write; a late old read is dropped by generation. Returning false
    /// means this result was not accepted; the caller must not refresh on-screen UI from it.
    @discardableResult
    func reconcileNativeDockMirror() async -> Bool {
        guard !nativeDockWriteInFlight else { return false }
        nativeDockRefreshGeneration &+= 1
        let generation = nativeDockRefreshGeneration
        let state = await nativeDockPreferencesService.currentAutohideState()
        guard !Task.isCancelled,
              !nativeDockWriteInFlight,
              generation == nativeDockRefreshGeneration else { return false }
        _ = reconcileNativeDockMirror(using: state)
        return true
    }

    @discardableResult
    private func reconcileNativeDockMirror(using state: NativeDockAutohideState?) -> Double {
        guard let state else {
            // When the system value cannot be read (sandbox etc.), leave the
            // mirror alone; the caller continues with the current mirror.
            return store.nativeDockAutoHideDelay
        }
        if let target = AutoHideToggleMenuModel.reconciledStoreDelay(
            systemEnabled: state.enabled,
            systemDelay: state.delay,
            currentStoreDelay: store.nativeDockAutoHideDelay
        ) {
            store.setNativeDockAutoHideDelay(target)
        }
        return store.nativeDockAutoHideDelay
    }

    /// The **only** write path to the system Dock.
    ///
    /// `previous` is not passed in by the UI: while the draft is on screen the user
    /// may change the real value at any time with ⌥⌘D or System Settings, so the UI's
    /// starting point is already stale. Re-read the system value before writing.
    ///
    /// defaults + killall is a multi-step, non-transactional sequence, so always re-read the system value
    /// after writing before deciding what the mirror gets (four quadrants: see
    /// `AutoHideToggleMenuModel.resolvedStoreDelay`). **No alert here**: alerts belong to the caller, and the
    /// two UIs present them differently (NSAlert for the menu, an attached alert for the settings window).
    func applyNativeDock(target: Double) async -> NativeDockApplyOutcome {
        await applyNativeDock(recommendations: NativeDockRecommendations(
            autoHideDelay: target,
            minimizeEffectScale: false,
            minimizeIntoAppIcon: false
        ))
    }

    /// Batch write from the guide screen. **The four-quadrant read-back covers only the `autohide`
    /// half**: with only the two minimize items checked, no system state is read and the mirror is
    /// untouched. Without touching autohide there is no "what did it become after writing" to resolve.
    func applyNativeDock(recommendations: NativeDockRecommendations) async -> NativeDockApplyOutcome {
        guard nativeDockPreferencesService.isAvailable else {
            return NativeDockApplyOutcome(
                resolvedDelay: store.nativeDockAutoHideDelay,
                error: NativeDockPreferencesError.sandboxed
            )
        }

        nativeDockWriteInFlight = true
        nativeDockRefreshGeneration &+= 1
        defer { nativeDockWriteInFlight = false }

        var previous: Double?
        if recommendations.autoHideDelay != nil {
            let previousState = await nativeDockPreferencesService.currentAutohideState()
            previous = reconcileNativeDockMirror(using: previousState)
        }

        var writeError: Error?
        do {
            try nativeDockPreferencesService.apply(recommendations: recommendations)
        } catch {
            writeError = error
        }

        guard let target = recommendations.autoHideDelay, let previous else {
            return NativeDockApplyOutcome(resolvedDelay: store.nativeDockAutoHideDelay, error: writeError)
        }

        let readback = await nativeDockPreferencesService.currentAutohideState()
        let resolved = AutoHideToggleMenuModel.resolvedStoreDelay(
            writeSucceeded: writeError == nil,
            systemState: readback,
            target: target,
            previous: previous
        )
        store.setNativeDockAutoHideDelay(resolved)
        return NativeDockApplyOutcome(resolvedDelay: resolved, error: writeError)
    }

    /// Undoes the setup guide: the Dock shows again and minimizes the standard way. The mirror is
    /// set to "always visible" only when the write went through.
    func restoreNativeDock() async -> Error? {
        guard nativeDockPreferencesService.isAvailable else { return NativeDockPreferencesError.sandboxed }
        nativeDockWriteInFlight = true
        nativeDockRefreshGeneration &+= 1
        defer { nativeDockWriteInFlight = false }
        do {
            try nativeDockPreferencesService.restoreDefaults()
            store.setNativeDockAutoHideDelay(AppSettingsStore.neverHideDelay)
            return nil
        } catch {
            return error
        }
    }

    func openNativeDockSettings() -> Bool {
        nativeDockPreferencesService.openSystemSettings()
    }

    // MARK: Update check

    /// The version row is used by both the menu and the settings window. Mainline does not bump the
    /// version after a release, so the number alone cannot tell a dev build from a user-installed
    /// package; the origin is therefore shown too (decided in the pure `BuildProvenance`, unit-tested).
    var versionTitle: String? {
        let info = Bundle.main.infoDictionary
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        return BuildProvenance.versionTitle(
            version: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String,
            isDebugBuild: isDebugBuild,
            bundlePath: Bundle.main.bundleURL.path
        )
    }

    /// User-initiated update check. **The result UI comes entirely from Sparkle**
    /// (update available / up to date / check failed), so this returns no copy and needs
    /// no alert. The old `UpdateCheckAlertContent` was deleted along with the "download
    /// manually from the website" wording, since manual download is no longer needed.
    func checkForUpdates() {
        updateService.checkForUpdates()
    }

    /// Enabled state shared by the "Check for Updates" buttons of both UIs.
    var canCheckForUpdates: Bool {
        updateService.canCheckForUpdates
    }

    /// Version number found by a scheduled check and still awaiting the user. The status bar uses it
    /// to light the dot on the icon and to change the "Check for Updates…" row into "Install X.Y.Z…".
    var pendingUpdateVersion: String? {
        updateService.pendingUpdateVersion
    }

    /// The "Automatically check for updates" checkbox in the settings window.
    ///
    /// The real value lives in Sparkle; **no mirror is stored in `AppSettingsStore`**:
    /// two copies would drift, and Sparkle writes this preference itself.
    var automaticallyChecksForUpdates: Bool {
        get { updateService.automaticallyChecksForUpdates }
        set { updateService.automaticallyChecksForUpdates = newValue }
    }
}
