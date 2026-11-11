import AppKit
import XCTest

@MainActor
final class AppSettingsStoreTests: XCTestCase {
    func testTrashDefaultsIgnoreLegacyKeyAndPersistIndependently() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "com.tungsten.edge.trash.visible")
        let store = AppSettingsStore(defaults: defaults)
        XCTAssertTrue(store.showTrash)
        store.setShowTrash(false)
        XCTAssertEqual(store.showShelf, ForkDefaults.showShelf)   // fork: upstream asserts true
        XCTAssertFalse(AppSettingsStore(defaults: defaults).showTrash)
        store.setShowShelf(false)
        store.setShowTrash(true)
        let reloaded = AppSettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.showTrash)
        XCTAssertFalse(reloaded.showShelf)
    }
    /// Fresh install: NitiaDock's own bar is **always visible by default** (decided 2026-09-01), the system
    /// Dock mirror seed is still 1.0.
    func testFreshInstallDefaultsToAlwaysVisibleForTheTaskbar() {
        let defaults = makeDefaults()

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.neverHideDelay)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(store.edgeAutoHideDelay), 0)
        XCTAssertEqual(store.nativeDockAutoHideDelay, 1.0)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(store.nativeDockAutoHideDelay), 10)
        XCTAssertNil(defaults.object(forKey: "com.tungsten.edge.autoHide.nativeDock.enabled"))
        XCTAssertNil(defaults.object(forKey: "com.tungsten.edge.autoHide.edge.enabled"))
    }

    /// ⚠️ **The easiest trap** after the default became always visible: remembered must still be a finite
    /// tier. If it also became `-1`, ⌥⇧⌘D would toggle from always visible to always visible and the shortcut
    /// would become a no-op.
    func testFreshInstallRemembersAFiniteDelayToToggleBackTo() {
        let defaults = makeDefaults()

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.lastEnabledEdgeAutoHideDelay, AppSettingsStore.defaultEnabledEdgeAutoHideDelay)
        XCTAssertNotEqual(store.lastEnabledEdgeAutoHideDelay, AppSettingsStore.neverHideDelay)

        store.toggleEdgeAutoHideMode()
        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.defaultEnabledEdgeAutoHideDelay, "always visible -> auto-hide")
        store.toggleEdgeAutoHideMode()
        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.neverHideDelay, "pressing again switches back to always visible")
    }

    func testLegacyDisabledEnabledKeyMigratesToNeverHideOnlyWhenKeyExists() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "com.tungsten.edge.autoHide.nativeDock.enabled")
        defaults.set(0.0, forKey: "com.tungsten.edge.autoHide.nativeDock.delay")

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.nativeDockAutoHideDelay, AppSettingsStore.neverHideDelay)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(store.nativeDockAutoHideDelay), 0)
        XCTAssertNil(defaults.object(forKey: "com.tungsten.edge.autoHide.nativeDock.enabled"))
    }

    func testLegacyEnabledTrueWithZeroDelaySnapsToFiniteMinimum() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "com.tungsten.edge.autoHide.nativeDock.enabled")
        defaults.set(0.0, forKey: "com.tungsten.edge.autoHide.nativeDock.delay")

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.nativeDockAutoHideDelay, AppSettingsStore.finiteDelayMin)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(store.nativeDockAutoHideDelay), 1)
        XCTAssertNil(defaults.object(forKey: "com.tungsten.edge.autoHide.nativeDock.enabled"))
    }

    func testLegacyEnabledTrueWithSubMinimumDelaySnapsToFiniteMinimum() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "com.tungsten.edge.autoHide.edge.enabled")
        defaults.set(0.05, forKey: "com.tungsten.edge.autoHide.edge.delay")

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.finiteDelayMin)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(store.edgeAutoHideDelay), 1)
        XCTAssertNil(defaults.object(forKey: "com.tungsten.edge.autoHide.edge.enabled"))
    }

    func testSliderDelayMappingKeepsSubMinimumSecondsDistinctFromNeverHide() {
        XCTAssertEqual(AppSettingsStore.delayFromSliderIndex(0), AppSettingsStore.neverHideDelay)
        XCTAssertEqual(AppSettingsStore.delayFromSliderIndex(1), AppSettingsStore.finiteDelayMin)
        XCTAssertEqual(AppSettingsStore.delayFromSliderIndex(30), AppSettingsStore.finiteDelayMax)
        XCTAssertEqual(AppSettingsStore.delayFromSliderIndex(31), AppSettingsStore.neverWakeDelay)

        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(-99.0), 0)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(AppSettingsStore.neverHideDelay), 0)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(0.0), 1)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(0.3), 3)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(1.0), 10)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(3.0), 30)
        XCTAssertEqual(AppSettingsStore.sliderIndexFromDelay(AppSettingsStore.neverWakeDelay), 31)
    }

    func testSnapDelayClampsOnlySentinelBoundsToSpecialStates() {
        XCTAssertEqual(AppSettingsStore.snapDelay(-99.0), AppSettingsStore.neverHideDelay)
        XCTAssertEqual(AppSettingsStore.snapDelay(-0.2), AppSettingsStore.finiteDelayMin)
        XCTAssertEqual(AppSettingsStore.snapDelay(0.0), AppSettingsStore.finiteDelayMin)
        XCTAssertEqual(AppSettingsStore.snapDelay(0.05), AppSettingsStore.finiteDelayMin)
        XCTAssertEqual(AppSettingsStore.snapDelay(0.3), 0.3)
        XCTAssertEqual(AppSettingsStore.snapDelay(3.3), AppSettingsStore.finiteDelayMax)
        XCTAssertEqual(AppSettingsStore.snapDelay(999.0), AppSettingsStore.neverWakeDelay)
        XCTAssertEqual(AppSettingsStore.snapDelay(1.34), 1.3)
    }

    @MainActor
    func testShowShelfDefaultsToOnAndPersists() {
        let defaults = makeDefaults()
        // fork: upstream asserts true here; NitiaDock's default lives in ForkDefaults.
        XCTAssertEqual(AppSettingsStore(defaults: defaults).showShelf, ForkDefaults.showShelf)

        let store = AppSettingsStore(defaults: defaults)
        store.setShowShelf(false)
        XCTAssertFalse(store.showShelf)
        XCTAssertFalse(AppSettingsStore(defaults: defaults).showShelf, "off must persist across restarts")

        store.setShowShelf(true)
        XCTAssertTrue(AppSettingsStore(defaults: defaults).showShelf)
    }

    @MainActor
    func testDockSizeDefaultsToMediumAndPersists() {
        let defaults = makeDefaults()
        XCTAssertEqual(AppSettingsStore(defaults: defaults).dockSize, .medium)

        let store = AppSettingsStore(defaults: defaults)
        store.setDockSize(.extraLarge)
        XCTAssertEqual(AppSettingsStore(defaults: defaults).dockSize, .extraLarge, "the tier must persist across restarts")
    }

    @MainActor
    func testDockSizeRewritesCorruptStoredValueToMedium() {
        let defaults = makeDefaults()
        defaults.set("gigantic", forKey: "com.tungsten.edge.dockSize")
        XCTAssertEqual(AppSettingsStore(defaults: defaults).dockSize, .medium)
        // Must **rewrite immediately**, otherwise every launch repeats the fallback and the stored value
        // never matches the checked UI item.
        XCTAssertEqual(defaults.string(forKey: "com.tungsten.edge.dockSize"), DockSize.medium.rawValue)

        defaults.set(42, forKey: "com.tungsten.edge.dockSize")
        XCTAssertEqual(AppSettingsStore(defaults: defaults).dockSize, .medium, "a wrong type must fall back too")
    }

    @MainActor
    func testHoverStyleDefaultsToQuietAndPersists() {
        let defaults = makeDefaults()
        XCTAssertEqual(AppSettingsStore(defaults: defaults).hoverStyle, .quiet, "fresh install shows no app name bubble (decided 2026-09-01)")

        let store = AppSettingsStore(defaults: defaults)
        store.setHoverStyle(.standard)
        XCTAssertEqual(store.hoverStyle, .standard)
        XCTAssertEqual(AppSettingsStore(defaults: defaults).hoverStyle, .standard, "the tier must persist across restarts")

        store.setHoverStyle(.quiet)
        XCTAssertEqual(AppSettingsStore(defaults: defaults).hoverStyle, .quiet)
    }

    @MainActor
    func testWindowLiftEnabledStaysOffForUpgradersAndPersists() {
        let defaults = makeDefaults()
        // Off when the key is missing is **a deliberate decision**, not a missing registration: maximize lift
        // avoidance really rewrites other apps' window sizes and must not be turned on for existing users by
        // an upgrade. The fresh-install case is written on explicitly by the seed method (see the next test);
        // do not "fix" this into register: true, which would turn it on for all existing users.
        XCTAssertFalse(AppSettingsStore(defaults: defaults).windowLiftEnabled, "existing users upgrading stay off")

        let store = AppSettingsStore(defaults: defaults)
        store.setWindowLiftEnabled(true)
        XCTAssertTrue(store.windowLiftEnabled)
        XCTAssertTrue(AppSettingsStore(defaults: defaults).windowLiftEnabled, "on must persist across restarts")

        store.setWindowLiftEnabled(false)
        XCTAssertFalse(AppSettingsStore(defaults: defaults).windowLiftEnabled)
    }

    /// Fresh install seeds it on (decided 2026-09-01), and seeds **only when the key has never been
    /// written**.
    func testWindowLiftSeedOnlyAppliesWhenTheUserNeverTouchedIt() {
        let fresh = makeDefaults()
        let store = AppSettingsStore(defaults: fresh)
        store.seedWindowLiftEnabledForFreshInstall(lineage: .pristine)
        XCTAssertTrue(store.windowLiftEnabled, "fresh install seeds on")
        XCTAssertTrue(AppSettingsStore(defaults: fresh).windowLiftEnabled, "must be persisted")

        // The user turned it off: even if seed is called again it must not override their choice.
        let chosen = makeDefaults()
        let existing = AppSettingsStore(defaults: chosen)
        existing.setWindowLiftEnabled(true)
        existing.setWindowLiftEnabled(false)
        existing.seedWindowLiftEnabledForFreshInstall(lineage: .pristine)
        XCTAssertFalse(existing.windowLiftEnabled, "key exists = the user set it, respect that")

        // Idempotent: calling again after seeding changes nothing.
        store.setWindowLiftEnabled(false)
        store.seedWindowLiftEnabledForFreshInstall(lineage: .pristine)
        XCTAssertFalse(store.windowLiftEnabled)
    }

    @MainActor
    func testFullscreenIntentDefaultsToOnAndPersists() {
        let defaults = makeDefaults()
        XCTAssertTrue(AppSettingsStore(defaults: defaults).fullscreenIntentEnabled)

        let store = AppSettingsStore(defaults: defaults)
        store.setFullscreenIntentEnabled(false)
        XCTAssertFalse(store.fullscreenIntentEnabled)
        XCTAssertFalse(AppSettingsStore(defaults: defaults).fullscreenIntentEnabled)

        store.setFullscreenIntentEnabled(true)
        XCTAssertTrue(AppSettingsStore(defaults: defaults).fullscreenIntentEnabled)
    }

    @MainActor
    func testHoverStyleRewritesCorruptStoredValueToTheDefault() {
        let defaults = makeDefaults()
        defaults.set("silent", forKey: "com.tungsten.edge.hoverStyle")
        XCTAssertEqual(AppSettingsStore(defaults: defaults).hoverStyle, HoverStyle.default)
        // Same as dockSize: must **rewrite immediately**, otherwise every launch repeats the fallback and the
        // stored value never matches the checked menu item.
        XCTAssertEqual(defaults.string(forKey: "com.tungsten.edge.hoverStyle"), HoverStyle.default.rawValue)

        defaults.set(7, forKey: "com.tungsten.edge.hoverStyle")
        XCTAssertEqual(AppSettingsStore(defaults: defaults).hoverStyle, HoverStyle.default, "a wrong type must fall back too")
    }

    @MainActor
    func testHoverStyleDoesNotDisturbOtherSettings() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        store.setDockSize(.large)
        store.setShowShelf(false)

        store.setHoverStyle(.quiet)

        let reloaded = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.hoverStyle, .quiet)
        XCTAssertEqual(reloaded.dockSize, .large, "hover tier and size tier are two independent keys")
        XCTAssertFalse(reloaded.showShelf)
    }

    func testHoverStyleRawValuesAreStableAcrossReleases() {
        // Same as dockSize: the raw value is in UserDefaults, so renaming silently resets all existing users
        // to the standard tier.
        XCTAssertEqual(HoverStyle.allCases.map(\.rawValue), ["standard", "quiet"])
        // Fresh install shows no app name bubble by default (decided 2026-09-01, previously .standard).
        XCTAssertEqual(HoverStyle.default, .quiet)
        // isExpressive is the single criterion for all chip views and for the menu check state; inverted, the
        // whole tier breaks.
        XCTAssertTrue(HoverStyle.standard.isExpressive)
        XCTAssertFalse(HoverStyle.quiet.isExpressive)
    }

    /// Hover feedback of the quiet tier: **the standard tier must always be false**.
    ///
    /// Decided 2026-08-17: the standard tier's feedback is the name bubble, its look unchanged to the pixel;
    /// this only adds feedback to the tier with names off (which had no hover feedback at all before).
    func testQuietHoverFeedbackOnlyExistsInTheQuietTier() {
        for hovering in [true, false] {
            XCTAssertFalse(
                HoverStyle.standard.showsQuietHoverFeedback(isHovering: hovering),
                "the standard tier should give no feedback for any input (hover=\(hovering))"
            )
        }
        XCTAssertTrue(HoverStyle.quiet.showsQuietHoverFeedback(isHovering: true))
        XCTAssertFalse(HoverStyle.quiet.showsQuietHoverFeedback(isHovering: false))
    }

    @MainActor
    func testDockSizeRawValuesAreStableAcrossReleases() {
        // The raw value is in UserDefaults, so renaming silently resets all existing users' tier to medium.
        XCTAssertEqual(DockSize.allCases.map(\.rawValue), ["small", "medium", "large", "extraLarge"])
        XCTAssertEqual(DockSize.allCases.map(\.title),
                       [String(localized: "Small"), String(localized: "Medium"), String(localized: "Large"), String(localized: "Extra Large")])
    }

    @MainActor
    func testNativeDockSliderCommandsCoverResidentFiniteAndNeverWake() {
        // The always-visible tier only turns autohide off and does not write the delay: the delay is
        // meaningless here, and writing it would overwrite the user's original value.
        let resident = NativeDockPreferencesService.commands(for: AppSettingsStore.neverHideDelay)
        XCTAssertEqual(resident.count, 2)
        XCTAssertEqual(resident[0].executable, "/usr/bin/defaults")
        XCTAssertEqual(resident[0].arguments, ["write", "com.apple.dock", "autohide", "-bool", "false"])
        XCTAssertEqual(resident[1].arguments, ["Dock"])

        let finite = NativeDockPreferencesService.commands(for: 0.5)
        XCTAssertEqual(finite.count, 3)
        XCTAssertEqual(finite[0].arguments, ["write", "com.apple.dock", "autohide", "-bool", "true"])
        XCTAssertEqual(finite[1].arguments, ["write", "com.apple.dock", "autohide-delay", "-float", "0.5"])
        XCTAssertEqual(finite[2].arguments, ["Dock"])

        let neverWake = NativeDockPreferencesService.commands(for: AppSettingsStore.neverWakeDelay)
        XCTAssertEqual(neverWake[1].arguments, ["write", "com.apple.dock", "autohide-delay", "-float", "999.0"])
    }

    /// Batch write of the onboarding screen: **a single `killall Dock` at the end**. Restarting once per item
    /// would make the screen flash three times in a row.
    @MainActor
    func testWelcomeRecommendationCommandsRestartDockExactlyOnce() {
        let all = NativeDockPreferencesService.commands(for: NativeDockRecommendations(
            autoHideDelay: AppSettingsStore.neverWakeDelay,
            minimizeEffectScale: true,
            minimizeIntoAppIcon: true
        ))
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(all[0].arguments, ["write", "com.apple.dock", "autohide", "-bool", "true"])
        XCTAssertEqual(all[1].arguments, ["write", "com.apple.dock", "autohide-delay", "-float", "999.0"])
        XCTAssertEqual(all[2].arguments, ["write", "com.apple.dock", "mineffect", "-string", "scale"])
        XCTAssertEqual(all[3].arguments, ["write", "com.apple.dock", "minimize-to-application", "-bool", "true"])
        XCTAssertEqual(all[4].executable, "/usr/bin/killall")
        XCTAssertEqual(all.filter { $0.executable == "/usr/bin/killall" }.count, 1)
    }

    /// Without "Hide system Dock" checked no autohide key may be written: not touching is different from
    /// writing the default.
    @MainActor
    func testMinimizeOnlyRecommendationCommandsSkipAutohideKeys() {
        let minimizeOnly = NativeDockPreferencesService.commands(for: NativeDockRecommendations(
            autoHideDelay: nil,
            minimizeEffectScale: true,
            minimizeIntoAppIcon: true
        ))
        XCTAssertEqual(minimizeOnly.count, 3)
        XCTAssertFalse(minimizeOnly.contains { $0.arguments.contains("autohide") })
        XCTAssertFalse(minimizeOnly.contains { $0.arguments.contains("autohide-delay") })
        XCTAssertEqual(minimizeOnly.last?.executable, "/usr/bin/killall")
    }

    /// Nothing checked: no write, no restart, no flash.
    @MainActor
    func testEmptyRecommendationCommandsAreNoOp() {
        XCTAssertTrue(NativeDockPreferencesService.commands(for: NativeDockRecommendations(
            autoHideDelay: nil,
            minimizeEffectScale: false,
            minimizeIntoAppIcon: false
        )).isEmpty)
    }

    @MainActor
    func testNativeDockPreferenceServiceDoesNotRunWhenSandboxed() {
        var didRun = false
        let service = NativeDockPreferencesService(sandbox: SandboxEnvironment(isSandboxed: true)) { _, _ in
            didRun = true
        }

        XCTAssertFalse(service.isAvailable)
        XCTAssertThrowsError(try service.apply(delay: 0.5))
        XCTAssertFalse(didRun)
    }

    @MainActor
    func testNativeDockSliderApplyStopsAtFirstFailedCommand() {
        var ranCommands: [(String, [String])] = []
        let service = NativeDockPreferencesService(
            sandbox: SandboxEnvironment(isSandboxed: false),
            runner: { executable, arguments in
                ranCommands.append((executable, arguments))
                if arguments.contains("autohide-delay") {
                    throw NativeDockPreferencesError.commandFailed(executable: executable, status: 1)
                }
            },
            autohideReader: { nil }
        )

        XCTAssertThrowsError(try service.apply(delay: 0.5))
        XCTAssertEqual(ranCommands.count, 2, "after the second command fails, killall Dock must not run")
    }

    @MainActor
    func testRestoreDockWritesMacOSDefaultsAndRestartsOnceEvenWithoutADelayKey() throws {
        var ran: [[String]] = []
        let service = NativeDockPreferencesService(
            sandbox: SandboxEnvironment(isSandboxed: false),
            runner: { executable, arguments in
                ran.append([executable] + arguments)
                if arguments.first == "delete" {
                    throw NativeDockPreferencesError.commandFailed(executable: executable, status: 1)
                }
            },
            autohideReader: { nil }
        )

        try service.restoreDefaults()
        XCTAssertTrue(ran.contains(["/usr/bin/defaults", "write", "com.apple.dock", "autohide", "-bool", "false"]))
        XCTAssertTrue(ran.contains(["/usr/bin/defaults", "write", "com.apple.dock", "mineffect", "-string", "genie"]))
        XCTAssertTrue(ran.contains(["/usr/bin/defaults", "write", "com.apple.dock", "minimize-to-application", "-bool", "false"]))
        XCTAssertEqual(ran.last, ["/usr/bin/killall", "Dock"])
        XCTAssertEqual(ran.filter { $0.first == "/usr/bin/killall" }.count, 1)
    }

    @MainActor
    func testRestoreDockRefusesInTheSandbox() {
        var didRun = false
        let service = NativeDockPreferencesService(
            sandbox: SandboxEnvironment(isSandboxed: true),
            runner: { _, _ in didRun = true },
            autohideReader: { nil }
        )
        XCTAssertThrowsError(try service.restoreDefaults())
        XCTAssertFalse(didRun)
    }

    func testNativeDockStateReadStopsBeforeValueAccessWhenSynchronizeFails() {
        var requestedKeys: [String] = []

        let state = NativeDockPreferencesService.readAutohideState(
            synchronize: { false },
            valueForKey: { key in
                requestedKeys.append(key)
                return nil
            }
        )

        XCTAssertNil(state)
        XCTAssertTrue(requestedKeys.isEmpty)
    }

    func testNativeDockStateDecoderDistinguishesMissingKeysFromCorruptValues() {
        XCTAssertEqual(
            NativeDockPreferencesService.decodeAutohideState(autohideValue: nil, delayValue: nil),
            NativeDockAutohideState(enabled: false, delay: nil)
        )
        XCTAssertEqual(
            NativeDockPreferencesService.decodeAutohideState(autohideValue: true, delayValue: 0.2),
            NativeDockAutohideState(enabled: true, delay: 0.2)
        )
        XCTAssertEqual(
            NativeDockPreferencesService.decodeAutohideState(autohideValue: nil, delayValue: 0.2),
            NativeDockAutohideState(enabled: false, delay: 0.2)
        )
        XCTAssertEqual(
            NativeDockPreferencesService.decodeAutohideState(autohideValue: false, delayValue: "bad"),
            NativeDockAutohideState(enabled: false, delay: nil),
            "when the system is explicitly off, a bad delay must not mask the trustworthy autohide value"
        )

        XCTAssertNil(NativeDockPreferencesService.decodeAutohideState(autohideValue: "true", delayValue: 0.2))
        XCTAssertNil(NativeDockPreferencesService.decodeAutohideState(autohideValue: NSNumber(value: 1), delayValue: 0.2))
        XCTAssertNil(NativeDockPreferencesService.decodeAutohideState(autohideValue: true, delayValue: "0.2"))
        XCTAssertNil(NativeDockPreferencesService.decodeAutohideState(autohideValue: true, delayValue: false))
        XCTAssertNil(NativeDockPreferencesService.decodeAutohideState(
            autohideValue: true,
            delayValue: NSNumber(value: Double.nan)
        ))
        XCTAssertNil(NativeDockPreferencesService.decodeAutohideState(
            autohideValue: true,
            delayValue: NSNumber(value: Double.infinity)
        ))
    }

    func testLaunchAtLoginMenuPresentationCoversFourStates() {
        XCTAssertEqual(
            LaunchAtLoginMenuPresentation(state: .unsupported),
            LaunchAtLoginMenuPresentation(title: String(localized: "Open at Login (Unavailable)"), isEnabled: false, isChecked: false, showsSettingsItem: false)
        )
        XCTAssertEqual(
            LaunchAtLoginMenuPresentation(state: .off),
            LaunchAtLoginMenuPresentation(title: String(localized: "Open at Login"), isEnabled: true, isChecked: false, showsSettingsItem: false)
        )
        XCTAssertEqual(
            LaunchAtLoginMenuPresentation(state: .on),
            LaunchAtLoginMenuPresentation(title: String(localized: "Open at Login"), isEnabled: true, isChecked: true, showsSettingsItem: false)
        )
        XCTAssertEqual(
            LaunchAtLoginMenuPresentation(state: .requiresApproval),
            LaunchAtLoginMenuPresentation(title: String(localized: "Open at Login (Pending Approval)"), isEnabled: true, isChecked: false, showsSettingsItem: true)
        )
    }

    func testLaunchAtLoginMenuToggleDecisionCoversFourStates() {
        XCTAssertNil(LaunchAtLoginMenuModel.requestedEnabledValue(afterSelecting: .unsupported))
        XCTAssertEqual(LaunchAtLoginMenuModel.requestedEnabledValue(afterSelecting: .off), true)
        XCTAssertEqual(LaunchAtLoginMenuModel.requestedEnabledValue(afterSelecting: .on), false)
        XCTAssertEqual(LaunchAtLoginMenuModel.requestedEnabledValue(afterSelecting: .requiresApproval), true)
    }

    func testLaunchAtLoginColdStartPresentationUsesRealStatusOverStoredIntent() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "com.tungsten.edge.launchAtLogin")
        let store = AppSettingsStore(defaults: defaults)

        let presentation = LaunchAtLoginMenuPresentation(state: .off)

        XCTAssertTrue(store.launchAtLogin)
        XCTAssertFalse(presentation.isChecked)
    }

    func testPanelVisibilityKeepsHiddenUntilAllReasonsAreCleared() {
        var state = PanelVisibilityState()

        state.setFullscreen(true)
        state.setEdgeAutoHidden(true)
        XCTAssertFalse(state.isVisible)

        state.setFullscreen(false)
        XCTAssertFalse(state.isVisible)

        state.setEdgeAutoHidden(false)
        XCTAssertTrue(state.isVisible)
    }

    func testPanelVisibilityInhibitorClearsEdgeAutoHideEvenAfterFullscreenExit() {
        var state = PanelVisibilityState()

        state.setEdgeAutoHidden(true)
        state.setFullscreen(true)
        state.setInhibitor(.dragging, active: true)
        state.setFullscreen(false)
        state.reconcileEdgeAutoHide(isEnabled: true)

        XCTAssertFalse(state.hideReasons.contains(.edgeAutoHide))
        XCTAssertTrue(state.isVisible)
    }

    func testPanelVisibilityConstantModeClearsEdgeAutoHide() {
        var state = PanelVisibilityState()

        state.setEdgeAutoHidden(true)
        state.reconcileEdgeAutoHide(isEnabled: false)

        XCTAssertTrue(state.isVisible)
    }

    /// While the NitiaDock menu is open (the same one from the status bar icon or the taskbar right-click),
    /// edge auto-hide must pause, otherwise the idle timer keeps running and the taskbar retracts from under
    /// the open menu.
    func testTaskbarMenuOpenInhibitsIdleHideAndReleasesOnClose() {
        var state = PanelVisibilityState()
        XCTAssertTrue(EdgeAutoHideRuntimeRules.canArmIdleHide(state: state, delay: 0.9))

        state.setInhibitor(.taskbarMenuOpen, active: true)
        XCTAssertFalse(EdgeAutoHideRuntimeRules.canArmIdleHide(state: state, delay: 0.9))

        state.setInhibitor(.taskbarMenuOpen, active: false)
        XCTAssertTrue(EdgeAutoHideRuntimeRules.canArmIdleHide(state: state, delay: 0.9))
    }

    /// The menu was opened while the taskbar was already retracted (the user clicked the status bar icon):
    /// the suppressor must bring it back and not leave the menu hanging where there is no taskbar.
    func testTaskbarMenuOpenClearsAnAlreadyHiddenEdgeAutoHide() {
        var state = PanelVisibilityState()
        state.setEdgeAutoHidden(true)
        XCTAssertFalse(state.isVisible)

        state.setInhibitor(.taskbarMenuOpen, active: true)
        state.reconcileEdgeAutoHide(isEnabled: true)

        XCTAssertTrue(state.isVisible)
    }

    func testEdgeAutoHideWakeRulesRequireHiddenFiniteDelayAndNoInhibitors() {
        var state = PanelVisibilityState()

        XCTAssertFalse(EdgeAutoHideRuntimeRules.canArmWake(state: state, delay: 0.9))

        state.setEdgeAutoHidden(true)
        XCTAssertTrue(EdgeAutoHideRuntimeRules.canArmWake(state: state, delay: 0.9))
        XCTAssertFalse(EdgeAutoHideRuntimeRules.canArmWake(state: state, delay: AppSettingsStore.neverWakeDelay))
        XCTAssertFalse(EdgeAutoHideRuntimeRules.canArmWake(state: state, delay: AppSettingsStore.neverHideDelay))

        state.setInhibitor(.drawerOpen, active: true)
        XCTAssertFalse(EdgeAutoHideRuntimeRules.canArmWake(state: state, delay: 0.9))
    }

    func testEdgeAutoHideIdleRulesRequireVisibleAndNoInhibitors() {
        var state = PanelVisibilityState()

        XCTAssertTrue(EdgeAutoHideRuntimeRules.canArmIdleHide(state: state, delay: 0.9))
        XCTAssertEqual(EdgeAutoHideRuntimeRules.idleHideInterval(for: 0.9), EdgeAutoHideRuntimeRules.fixedIdleHideDelay)
        XCTAssertEqual(EdgeAutoHideRuntimeRules.idleHideInterval(for: AppSettingsStore.neverWakeDelay), EdgeAutoHideRuntimeRules.fixedIdleHideDelay)
        XCTAssertNil(EdgeAutoHideRuntimeRules.idleHideInterval(for: AppSettingsStore.neverHideDelay))

        state.setEdgeAutoHidden(true)
        XCTAssertFalse(EdgeAutoHideRuntimeRules.canArmIdleHide(state: state, delay: 0.9))

        state.setEdgeAutoHidden(false)
        state.setInhibitor(.dragging, active: true)
        XCTAssertFalse(EdgeAutoHideRuntimeRules.canArmIdleHide(state: state, delay: 0.9))
    }

    func testBottomHotZoneSuppressesIdleHideOnlyForFiniteWakeDelays() {
        XCTAssertTrue(EdgeAutoHideRuntimeRules.bottomHotZoneSuppressesIdleHide(delay: 0.1))
        XCTAssertTrue(EdgeAutoHideRuntimeRules.bottomHotZoneSuppressesIdleHide(delay: 0.9))
        XCTAssertTrue(EdgeAutoHideRuntimeRules.bottomHotZoneSuppressesIdleHide(delay: 3.0))

        // 999: auto-hide without wake. With no wake action there is no risk of a "fight", so the bottom-edge
        // hot zone should not additionally hold off hiding.
        XCTAssertFalse(EdgeAutoHideRuntimeRules.bottomHotZoneSuppressesIdleHide(delay: AppSettingsStore.neverWakeDelay))

        // -1: always visible. It never hides anyway, so holding makes no difference; the rule should still
        // return false (which does not mean it takes effect).
        XCTAssertFalse(EdgeAutoHideRuntimeRules.bottomHotZoneSuppressesIdleHide(delay: AppSettingsStore.neverHideDelay))
    }

    // MARK: - Always-visible toggle (toggleEdgeAutoHideMode) and remembered seeding

    func testToggleFromFiniteDelayEntersResidentAndRestoresSameDelay() {
        let defaults = makeDefaults()
        defaults.set(0.5, forKey: "com.tungsten.edge.autoHide.edge.delay")
        let store = AppSettingsStore(defaults: defaults)

        store.toggleEdgeAutoHideMode()
        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.neverHideDelay)
        XCTAssertEqual(store.lastEnabledEdgeAutoHideDelay, 0.5)

        store.toggleEdgeAutoHideMode()
        XCTAssertEqual(store.edgeAutoHideDelay, 0.5)
    }

    func testToggleFromNeverWakeRoundTripsBackToNeverWake() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        store.setEdgeAutoHideDelay(AppSettingsStore.neverWakeDelay)

        store.toggleEdgeAutoHideMode()
        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.neverHideDelay)

        store.toggleEdgeAutoHideMode()
        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.neverWakeDelay)
    }

    func testToggleFromResidentWithoutHistoryFallsBackToDefaultDelay() {
        let defaults = makeDefaults()
        defaults.set(AppSettingsStore.neverHideDelay, forKey: "com.tungsten.edge.autoHide.edge.delay")
        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.lastEnabledEdgeAutoHideDelay, AppSettingsStore.defaultEnabledEdgeAutoHideDelay)

        store.toggleEdgeAutoHideMode()
        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.defaultEnabledEdgeAutoHideDelay)
    }

    func testRememberedSeedsFromCurrentFiniteValueOverStaleStoredValue() {
        let defaults = makeDefaults()
        defaults.set(0.5, forKey: "com.tungsten.edge.autoHide.edge.delay")
        defaults.set(2.0, forKey: "com.tungsten.edge.autoHide.edge.lastEnabledDelay")

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.lastEnabledEdgeAutoHideDelay, 0.5)
        XCTAssertEqual(defaults.double(forKey: "com.tungsten.edge.autoHide.edge.lastEnabledDelay"), 0.5)
    }

    func testRememberedIsReadOnlyWhenCurrentIsResident() {
        let defaults = makeDefaults()
        defaults.set(AppSettingsStore.neverHideDelay, forKey: "com.tungsten.edge.autoHide.edge.delay")
        defaults.set(2.0, forKey: "com.tungsten.edge.autoHide.edge.lastEnabledDelay")

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.lastEnabledEdgeAutoHideDelay, 2.0)
    }

    func testCorruptRememberedValuesFallBackToDefault() {
        let corruptValues: [Any] = ["string", Double.nan, AppSettingsStore.neverHideDelay, -50.0]
        for corrupt in corruptValues {
            let defaults = makeDefaults()
            defaults.set(AppSettingsStore.neverHideDelay, forKey: "com.tungsten.edge.autoHide.edge.delay")
            defaults.set(corrupt, forKey: "com.tungsten.edge.autoHide.edge.lastEnabledDelay")

            let store = AppSettingsStore(defaults: defaults)

            XCTAssertEqual(store.lastEnabledEdgeAutoHideDelay, AppSettingsStore.defaultEnabledEdgeAutoHideDelay, "corrupt=\(corrupt)")
        }
    }

    func testLegacyDisabledMigrationThenToggleRestoresDefaultDelay() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "com.tungsten.edge.autoHide.edge.enabled")
        defaults.set(0.7, forKey: "com.tungsten.edge.autoHide.edge.delay")

        let store = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.neverHideDelay)
        XCTAssertEqual(store.lastEnabledEdgeAutoHideDelay, AppSettingsStore.defaultEnabledEdgeAutoHideDelay)

        store.toggleEdgeAutoHideMode()
        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.defaultEnabledEdgeAutoHideDelay)
    }

    func testCrossStoreRebuildKeepsRememberedDelay() {
        let defaults = makeDefaults()
        let first = AppSettingsStore(defaults: defaults)
        first.setEdgeAutoHideDelay(2.0)
        first.toggleEdgeAutoHideMode()
        XCTAssertEqual(first.edgeAutoHideDelay, AppSettingsStore.neverHideDelay)

        let second = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(second.edgeAutoHideDelay, AppSettingsStore.neverHideDelay)
        XCTAssertEqual(second.lastEnabledEdgeAutoHideDelay, 2.0)

        second.toggleEdgeAutoHideMode()
        XCTAssertEqual(second.edgeAutoHideDelay, 2.0)
    }

    func testNonFiniteSetterInputsAreIgnored() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        store.setEdgeAutoHideDelay(0.5)

        store.setEdgeAutoHideDelay(.nan)
        store.setEdgeAutoHideDelay(.infinity)
        store.setEdgeAutoHideDelay(-.infinity)
        store.setNativeDockAutoHideDelay(.nan)

        XCTAssertEqual(store.edgeAutoHideDelay, 0.5)
        XCTAssertEqual(store.lastEnabledEdgeAutoHideDelay, 0.5)
        XCTAssertEqual(store.nativeDockAutoHideDelay, AppSettingsStore.defaultNativeDockAutoHideDelay)
    }

    func testSnapDelayReturnsFallbackForNonFiniteInput() {
        XCTAssertEqual(AppSettingsStore.snapDelay(.nan), AppSettingsStore.defaultEnabledEdgeAutoHideDelay)
        XCTAssertEqual(AppSettingsStore.snapDelay(.infinity, fallbackForNonFinite: 1.0), 1.0)
        XCTAssertEqual(AppSettingsStore.snapDelay(-.infinity, fallbackForNonFinite: 2.0), 2.0)
    }

    func testStoredActiveDelayRejectsWrongTypesAndUsesPerGroupFallback() {
        XCTAssertEqual(AppSettingsStore.sanitizedStoredDelay("bad", fallback: 1.0), 1.0)
        XCTAssertEqual(AppSettingsStore.sanitizedStoredDelay(true, fallback: 1.0), 1.0)
        XCTAssertEqual(AppSettingsStore.sanitizedStoredDelay(NSNumber(value: Double.nan), fallback: 1.0), 1.0)
        XCTAssertEqual(AppSettingsStore.sanitizedStoredDelay(2.04, fallback: 1.0), 2.0)

        let defaults = makeDefaults()
        defaults.set("bad", forKey: "com.tungsten.edge.autoHide.nativeDock.delay")
        defaults.set(true, forKey: "com.tungsten.edge.autoHide.edge.delay")

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.nativeDockAutoHideDelay, AppSettingsStore.defaultNativeDockAutoHideDelay)
        XCTAssertEqual(store.edgeAutoHideDelay, AppSettingsStore.defaultEnabledEdgeAutoHideDelay)
        XCTAssertEqual(defaults.double(forKey: "com.tungsten.edge.autoHide.nativeDock.delay"), 1.0)
        XCTAssertEqual(defaults.double(forKey: "com.tungsten.edge.autoHide.edge.delay"), 0.1)
    }

    func testSanitizedLastEnabledDelayNeverReturnsResident() {
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(nil), AppSettingsStore.defaultEnabledEdgeAutoHideDelay)
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(.nan), AppSettingsStore.defaultEnabledEdgeAutoHideDelay)
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(AppSettingsStore.neverHideDelay), AppSettingsStore.defaultEnabledEdgeAutoHideDelay)
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(-50.0), AppSettingsStore.defaultEnabledEdgeAutoHideDelay)
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(0.05), AppSettingsStore.finiteDelayMin)
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(2.0), 2.0)
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(AppSettingsStore.neverWakeDelay), AppSettingsStore.neverWakeDelay)
    }

    // MARK: - Reverse mouse wheel

    // MARK: - Custom show/hide shortcut storage

    func testEdgeToggleShortcutDefaultsToNilAndRoundTrips() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        XCTAssertNil(store.edgeToggleShortcut, "missing key = default ⌥⇧⌘D")

        let custom = StoredHotKeyShortcut(keyCode: 40, carbonModifiers: 4352, glyphs: "⌃⌘K")
        store.setEdgeToggleShortcut(custom)
        XCTAssertEqual(store.edgeToggleShortcut, custom)

        let reloaded = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.edgeToggleShortcut, custom, "round trip across launches")
    }

    func testEdgeToggleShortcutResetRemovesKeyAndMalformedFallsBackToNil() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        store.setEdgeToggleShortcut(StoredHotKeyShortcut(keyCode: 40, carbonModifiers: 4352, glyphs: "⌃⌘K"))

        store.setEdgeToggleShortcut(nil)
        XCTAssertNil(store.edgeToggleShortcut)
        XCTAssertNil(defaults.dictionary(forKey: "com.tungsten.edge.hotKey.edgeAutoHideMode"), "restoring the default must delete the key, not write an empty value")

        // Bad data (wrong type / missing field / out of range) always falls back to nil; it must not crash
        // the launch read or store half a key.
        defaults.set(["keyCode": "not-a-number", "glyphs": "X"], forKey: "com.tungsten.edge.hotKey.edgeAutoHideMode")
        XCTAssertNil(AppSettingsStore(defaults: defaults).edgeToggleShortcut)
        defaults.set(["keyCode": 99999, "modifiers": 256, "glyphs": "X"], forKey: "com.tungsten.edge.hotKey.edgeAutoHideMode")
        XCTAssertNil(AppSettingsStore(defaults: defaults).edgeToggleShortcut, "keyCode beyond 16 bits is rejected")
        defaults.set(["keyCode": 40, "modifiers": 256, "glyphs": ""], forKey: "com.tungsten.edge.hotKey.edgeAutoHideMode")
        XCTAssertNil(AppSettingsStore(defaults: defaults).edgeToggleShortcut, "empty glyph is rejected")
    }

    // MARK: - Menu group title pure logic

    /// The shortcut is written into the title only when Carbon registration succeeded: when it failed the key
    /// does nothing, and mentioning it would be a lie. Since 2026-08-24 the glyphs are passed in by the
    /// caller (the user can rebind), so the title follows the combination currently in effect.
    func testEdgeSectionTitleMentionsShortcutOnlyWhenRegistered() {
        XCTAssertEqual(
            AutoHideToggleMenuModel.edgeSectionTitle(isHotKeyRegistered: true, glyphs: "⌥⇧⌘D"),
            String(format: String(localized: "NitiaDock (%@ to show/hide)"), "⌥⇧⌘D")
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.edgeSectionTitle(isHotKeyRegistered: true, glyphs: "⌃⌘K"),
            String(format: String(localized: "NitiaDock (%@ to show/hide)"), "⌃⌘K")
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.edgeSectionTitle(isHotKeyRegistered: false, glyphs: "⌃⌘K"),
            String(localized: "NitiaDock"),
            "no combination is mentioned when registration failed"
        )
    }

    @MainActor
    func testEdgeSliderIsCompactAndKeepsAccessibilityContext() {
        let view = PreferenceSliderMenuItemView(accessibilityTitle: "Wake delay")
        view.sync(delay: 0.5)

        XCTAssertEqual(view.frame.height, 58)
        XCTAssertEqual(view.accessibilityLabel(), "Wake delay, 0.5s")
        XCTAssertEqual(view.accessibilityValue() as? String, "0.5s")
    }

    @MainActor
    func testNativeDockApplyRowIsAButtonWiredToApply() {
        let row = NativeDockApplyRowView()
        var fired = 0
        row.onApply = { fired += 1 }

        // Must be a real button, not a plain menu text row: a menu row has the same visual weight as its
        // neighbors, and the user who just dragged the slider is still looking at it; missing the row means
        // "thought it was set but it never took effect".
        guard let button = row.subviews.compactMap({ $0 as? MenuActionButton }).first else {
            return XCTFail("the confirm row must contain a real button")
        }

        // A custom view in a menu is not in the key window; without overriding acceptsFirstMouse the first
        // click is swallowed and the user thinks the button is broken. The override looks redundant, but
        // removing it reproduces the bug.
        XCTAssertTrue(button.acceptsFirstMouse(for: nil))

        // Subviews (text / icon) must not intercept the mouse, otherwise the middle of the button cannot be
        // clicked.
        let center = NSPoint(x: button.frame.midX, y: button.frame.midY)
        XCTAssertIdentical(button.hitTest(center), button)

        button.performClickForTesting()
        XCTAssertEqual(fired, 1, "the button must be wired to onApply, otherwise the confirmation is dead")
    }

    @MainActor
    func testNativeDockApplyRowCarriesTargetTierForVoiceOver() {
        let row = NativeDockApplyRowView()
        row.updateTarget(
            description: AutoHideToggleMenuModel.nativeApplyTitle(draft: AppSettingsStore.neverWakeDelay)
        )
        // The button title is always "Apply"; the tier goes through accessibility only: VoiceOver users
        // cannot see the slider position.
        XCTAssertEqual(row.accessibilityLabel(),
                       String(format: String(localized: "Apply “%@” (the Dock will restart)"), String(localized: "Never Wake")))
    }

    func testNativeApplyRowAppearsOnlyWhenDraftDiffersFromAppliedTier() {
        // The same tier (including floating-point representation error) should not show the confirm row:
        // there is nothing to apply.
        XCTAssertFalse(AutoHideToggleMenuModel.shouldShowNativeApply(draft: 1.0, applied: 1.0))
        XCTAssertFalse(AutoHideToggleMenuModel.shouldShowNativeApply(
            draft: AppSettingsStore.neverHideDelay,
            applied: AppSettingsStore.neverHideDelay
        ))
        // Integer tiers are compared, not floats: the slider can only rest on a tier, and values between
        // tiers that map to the same tier mean "unchanged".
        XCTAssertFalse(AutoHideToggleMenuModel.shouldShowNativeApply(draft: 1.0 + 1e-12, applied: 1.0))

        XCTAssertTrue(AutoHideToggleMenuModel.shouldShowNativeApply(
            draft: AppSettingsStore.neverWakeDelay,
            applied: AppSettingsStore.neverHideDelay
        ))
        XCTAssertTrue(AutoHideToggleMenuModel.shouldShowNativeApply(draft: 0.5, applied: 1.0))
    }

    func testNativeApplyTitleNamesTheTargetTier() {
        XCTAssertEqual(
            AutoHideToggleMenuModel.nativeApplyTitle(draft: AppSettingsStore.neverWakeDelay),
            String(format: String(localized: "Apply “%@” (the Dock will restart)"), String(localized: "Never Wake"))
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.nativeApplyTitle(draft: AppSettingsStore.neverHideDelay),
            String(format: String(localized: "Apply “%@” (the Dock will restart)"), String(localized: "Always Visible"))
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.nativeApplyTitle(draft: 1.0),
            String(format: String(localized: "Apply “%@” (the Dock will restart)"), "1.0s")
        )
    }

    func testDelayDisplayNameIsSharedBySliderAndApplyRow() {
        // The slider itself and the confirm row must use the same measure, otherwise the tier the confirm row
        // names differs from what the slider shows.
        XCTAssertEqual(AutoHideToggleMenuModel.delayDisplayName(sliderIndex: 0), String(localized: "Always Visible"))
        XCTAssertEqual(
            AutoHideToggleMenuModel.delayDisplayName(sliderIndex: AppSettingsStore.sliderIndexMax),
            String(localized: "Never Wake")
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.delayDisplayName(
                sliderIndex: AppSettingsStore.sliderIndexFromDelay(1.0)
            ),
            "1.0s"
        )
    }

    func testResolvedStoreDelayCoversWriteAndReadQuadrants() {
        let target = 0.5
        let previous = AppSettingsStore.neverHideDelay

        // System readable: always use the system's true value, regardless of whether the write succeeded.
        XCTAssertEqual(
            AutoHideToggleMenuModel.resolvedStoreDelay(
                writeSucceeded: true,
                systemState: NativeDockAutohideState(enabled: true, delay: 0.5),
                target: target,
                previous: previous
            ),
            0.5
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.resolvedStoreDelay(
                writeSucceeded: false,
                systemState: NativeDockAutohideState(enabled: true, delay: 0.5),
                target: target,
                previous: previous
            ),
            0.5,
            "a multi-step write may have partly taken effect; if it can be read, go by what was read"
        )
        // Write succeeded but cannot be read back: keep target. Rolling back would make the UI the opposite
        // of the system setting already in effect.
        XCTAssertEqual(
            AutoHideToggleMenuModel.resolvedStoreDelay(
                writeSucceeded: true,
                systemState: nil,
                target: target,
                previous: previous
            ),
            target
        )
        // Write failed and cannot be read back: can only revert to the state before the change.
        XCTAssertEqual(
            AutoHideToggleMenuModel.resolvedStoreDelay(
                writeSucceeded: false,
                systemState: nil,
                target: target,
                previous: previous
            ),
            previous
        )
    }

    func testPreferenceSliderCommitIsConsumedExactlyOnce() {
        var tracker = PreferenceSliderCommitTracker()
        tracker.begin(currentDelay: 0.5)
        tracker.stage(1.0)
        // Repeated begin during a drag must not overwrite the start point, otherwise previous becomes an
        // intermediate value.
        tracker.begin(currentDelay: 0.9)
        tracker.stage(1.5)

        let first = tracker.consume()
        XCTAssertEqual(first?.previous, 0.5)
        XCTAssertEqual(first?.target, 1.5)
        // Confirm-row commit and "discard the draft when the menu opens" both go through consume, and only
        // the first gets the value: otherwise a confirmed value would be set back to the old one by the
        // discard logic that follows, or defaults + killall Dock would be written twice.
        XCTAssertNil(tracker.consume())
        XCTAssertNil(tracker.consume())
    }

    func testPreferenceSliderCommitSkipsUnchangedAndUnstartedAdjustments() {
        var unchanged = PreferenceSliderCommitTracker()
        unchanged.begin(currentDelay: 0.5)
        unchanged.stage(0.5)
        XCTAssertNil(unchanged.consume(), "an unchanged value should not be written to the system")

        var neverStarted = PreferenceSliderCommitTracker()
        neverStarted.stage(1.0)
        XCTAssertNil(neverStarted.consume(), "no start point means no previous, cannot commit")

        // After consuming, starting a new round still works.
        var reused = PreferenceSliderCommitTracker()
        reused.begin(currentDelay: 0.2)
        reused.stage(0.4)
        XCTAssertNotNil(reused.consume())
        reused.begin(currentDelay: 0.4)
        reused.stage(0.8)
        XCTAssertEqual(reused.consume()?.previous, 0.4)
    }

    func testNativeDockSectionTitleMentionsSystemShortcutAsPlainText() {
        // ⌥⌘D belongs to macOS; we neither define nor register it. With the show/hide command removed it is
        // the only one-key way to "bring the Dock back temporarily", so the title must mention it, but only
        // as plain text: as a keyEquivalent the menu would capture it.
        XCTAssertTrue(AutoHideToggleMenuModel.nativeDockSectionTitle.contains("⌥⌘D"))
        // "Dock" is in both languages (the Chinese title and the English "The Dock"); assert the
        // language-independent part.
        XCTAssertTrue(AutoHideToggleMenuModel.nativeDockSectionTitle.contains("Dock"))
    }

    func testReconciledStoreDelayAlignsStoreWithSystemTruth() {
        // System off: change the stored value to always visible unless it already is; no change needed if it
        // is.
        XCTAssertEqual(
            AutoHideToggleMenuModel.reconciledStoreDelay(systemEnabled: false, systemDelay: nil, currentStoreDelay: 1.0),
            AppSettingsStore.neverHideDelay
        )
        XCTAssertNil(
            AutoHideToggleMenuModel.reconciledStoreDelay(systemEnabled: false, systemDelay: 0.5, currentStoreDelay: AppSettingsStore.neverHideDelay)
        )

        // System on: align to the system delay (snapped to a valid tier); with no key use the system default
        // 0.5.
        XCTAssertEqual(
            AutoHideToggleMenuModel.reconciledStoreDelay(systemEnabled: true, systemDelay: 0.2, currentStoreDelay: AppSettingsStore.neverHideDelay),
            0.2
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.reconciledStoreDelay(systemEnabled: true, systemDelay: nil, currentStoreDelay: AppSettingsStore.neverHideDelay),
            AutoHideToggleMenuModel.systemDefaultAutohideDelay
        )
        // 999 (no-wake tier) round-trips as is; 0 snaps to the minimum tier 0.1; already equal returns nil.
        XCTAssertEqual(
            AutoHideToggleMenuModel.reconciledStoreDelay(systemEnabled: true, systemDelay: 999.0, currentStoreDelay: 1.0),
            AppSettingsStore.neverWakeDelay
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.reconciledStoreDelay(systemEnabled: true, systemDelay: 0.0, currentStoreDelay: 1.0),
            AppSettingsStore.finiteDelayMin
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.reconciledStoreDelay(systemEnabled: true, systemDelay: -1.0, currentStoreDelay: 1.0),
            AppSettingsStore.finiteDelayMin,
            "when the system switch is explicitly on, a negative delay must not be read as the app's always-visible sentinel"
        )
        XCTAssertEqual(
            AutoHideToggleMenuModel.reconciledStoreDelay(systemEnabled: true, systemDelay: .nan, currentStoreDelay: 0.2),
            AppSettingsStore.defaultNativeDockAutoHideDelay
        )
        XCTAssertNil(
            AutoHideToggleMenuModel.reconciledStoreDelay(systemEnabled: true, systemDelay: 1.0, currentStoreDelay: 1.0)
        )
    }

    @MainActor
    func testNativeDockAutohideStateReadRespectsSandboxAndInjectedReader() async {
        let sandboxed = NativeDockPreferencesService(
            sandbox: SandboxEnvironment(isSandboxed: true),
            runner: { _, _ in },
            autohideReader: { NativeDockAutohideState(enabled: true, delay: 0.5) }
        )
        let sandboxedState = await sandboxed.currentAutohideState()
        XCTAssertNil(sandboxedState, "unreadable in the sandbox, return nil so the caller falls back to the stored value")

        let readable = NativeDockPreferencesService(
            sandbox: SandboxEnvironment(isSandboxed: false),
            runner: { _, _ in },
            autohideReader: { NativeDockAutohideState(enabled: true, delay: 0.2) }
        )
        let readableState = await readable.currentAutohideState()
        XCTAssertEqual(readableState, NativeDockAutohideState(enabled: true, delay: 0.2))
    }

    @MainActor
    func testSystemTruthReadersRunOffMainThread() async {
        let launch = LaunchAtLoginService(backend: ThreadProbeLaunchBackend())
        let launchState = await launch.currentState()
        XCTAssertEqual(launchState, .on)

        let native = NativeDockPreferencesService(
            sandbox: SandboxEnvironment(isSandboxed: false),
            runner: { _, _ in },
            autohideReader: {
                NativeDockAutohideState(enabled: !Thread.isMainThread, delay: 0.4)
            }
        )
        let nativeState = await native.currentAutohideState()
        XCTAssertEqual(
            nativeState,
            NativeDockAutohideState(enabled: true, delay: 0.4)
        )
    }

    func testOpenSystemDockSettingsUsesDeepLinkFirst() {
        var openedURLs: [URL] = []
        let service = NativeDockPreferencesService(
            sandbox: SandboxEnvironment(isSandboxed: false),
            runner: { _, _ in },
            autohideReader: { nil },
            urlOpener: { url in
                openedURLs.append(url)
                return true
            }
        )

        XCTAssertTrue(service.openSystemSettings())
        XCTAssertEqual(openedURLs.map(\.absoluteString), ["x-apple.systempreferences:com.apple.preference.dock"])
    }

    func testOpenSystemDockSettingsFallsBackToPreferencePane() {
        var openedURLs: [URL] = []
        let service = NativeDockPreferencesService(
            sandbox: SandboxEnvironment(isSandboxed: false),
            runner: { _, _ in },
            autohideReader: { nil },
            urlOpener: { url in
                openedURLs.append(url)
                return url.isFileURL
            }
        )

        XCTAssertTrue(service.openSystemSettings())
        XCTAssertEqual(openedURLs.count, 2)
        XCTAssertEqual(openedURLs[0].absoluteString, "x-apple.systempreferences:com.apple.preference.dock")
        XCTAssertEqual(openedURLs[1].path, "/System/Library/PreferencePanes/Dock.prefPane")
    }

    func testOpenSystemDockSettingsReportsFailureAfterBothAttempts() {
        let service = NativeDockPreferencesService(
            sandbox: SandboxEnvironment(isSandboxed: false),
            runner: { _, _ in },
            autohideReader: { nil },
            urlOpener: { _ in false }
        )

        XCTAssertFalse(service.openSystemSettings())
    }

    func testOpenSystemDockSettingsIsNotBlockedBySandboxWriteGate() {
        var openedURLs: [URL] = []
        let service = NativeDockPreferencesService(
            sandbox: SandboxEnvironment(isSandboxed: true),
            runner: { _, _ in },
            autohideReader: { nil },
            urlOpener: { url in
                openedURLs.append(url)
                return true
            }
        )

        XCTAssertFalse(service.isAvailable)
        XCTAssertTrue(service.openSystemSettings())
        XCTAssertEqual(openedURLs.count, 1)
    }

    // MARK: - System Dock group remembered mirror

    func testNativeRememberedSeedsFromCurrentFiniteValueOverStaleStoredValue() {
        let defaults = makeDefaults()
        defaults.set(2.0, forKey: "com.tungsten.edge.autoHide.nativeDock.delay")
        defaults.set(0.5, forKey: "com.tungsten.edge.autoHide.nativeDock.lastEnabledDelay")

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.lastEnabledNativeDockAutoHideDelay, 2.0)
        XCTAssertEqual(defaults.double(forKey: "com.tungsten.edge.autoHide.nativeDock.lastEnabledDelay"), 2.0)
    }

    func testNativeRememberedIsReadWhenCurrentIsResidentAndCorruptFallsBackToNativeDefault() {
        let defaults = makeDefaults()
        defaults.set(AppSettingsStore.neverHideDelay, forKey: "com.tungsten.edge.autoHide.nativeDock.delay")
        defaults.set(2.0, forKey: "com.tungsten.edge.autoHide.nativeDock.lastEnabledDelay")
        XCTAssertEqual(AppSettingsStore(defaults: defaults).lastEnabledNativeDockAutoHideDelay, 2.0)

        let corrupted = makeDefaults()
        corrupted.set(AppSettingsStore.neverHideDelay, forKey: "com.tungsten.edge.autoHide.nativeDock.delay")
        corrupted.set(AppSettingsStore.neverHideDelay, forKey: "com.tungsten.edge.autoHide.nativeDock.lastEnabledDelay")
        // The fallback is the native group's own default tier 1.0, not edge's 0.1.
        XCTAssertEqual(AppSettingsStore(defaults: corrupted).lastEnabledNativeDockAutoHideDelay, AppSettingsStore.defaultNativeDockAutoHideDelay)
    }

    func testNativeSetterSyncsRememberedBeforeActiveDedup() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)

        store.setNativeDockAutoHideDelay(2.0)
        XCTAssertEqual(store.lastEnabledNativeDockAutoHideDelay, 2.0)

        store.setNativeDockAutoHideDelay(AppSettingsStore.neverHideDelay)
        XCTAssertEqual(store.nativeDockAutoHideDelay, AppSettingsStore.neverHideDelay)
        XCTAssertEqual(store.lastEnabledNativeDockAutoHideDelay, 2.0, "writing always visible does not touch remembered")

        let rebuilt = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(rebuilt.lastEnabledNativeDockAutoHideDelay, 2.0, "remembered survives rebuilding the Store")
    }

    func testSanitizedLastEnabledDelayHonorsPerGroupFallback() {
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(nil, fallback: AppSettingsStore.defaultNativeDockAutoHideDelay), 1.0)
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(.nan, fallback: 1.0), 1.0)
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(AppSettingsStore.neverHideDelay, fallback: 1.0), 1.0)
        XCTAssertEqual(AppSettingsStore.sanitizedLastEnabledDelay(2.0, fallback: 1.0), 2.0)
    }

    func testFullscreenPendingConfirmationIsAtomicAndStaleTimeoutCannotRevealPanels() {
        var state = PanelVisibilityState()
        state.beginFullscreenTransition(generation: 7)
        XCTAssertFalse(state.isVisible)
        XCTAssertFalse(state.timeoutFullscreenTransition(generation: 6))
        XCTAssertFalse(state.isVisible)

        XCTAssertTrue(state.confirmFullscreenTransition(generation: 7))
        XCTAssertFalse(state.isVisible)
        XCTAssertFalse(state.hideReasons.contains(.fullscreenTransitionPending))
        XCTAssertTrue(state.hideReasons.contains(.fullscreen))
    }

    func testFullscreenPendingTimeoutPreservesEdgeHiddenStateAndBlocksEdgeTimers() {
        var state = PanelVisibilityState()
        state.setEdgeAutoHidden(true)
        state.beginFullscreenTransition(generation: 8)
        XCTAssertFalse(EdgeAutoHideRuntimeRules.canArmWake(state: state, delay: 0.5))
        XCTAssertFalse(EdgeAutoHideRuntimeRules.canArmIdleHide(state: state, delay: 0.5))

        XCTAssertTrue(state.timeoutFullscreenTransition(generation: 8))
        XCTAssertFalse(state.isVisible)
        XCTAssertTrue(state.hideReasons.contains(.edgeAutoHide))
    }

    func testFullscreenSpaceHoldBeginsOnlyFromConfirmedFullscreen() {
        XCTAssertTrue(FullscreenSpaceHoldDecision.shouldBegin(isFullscreen: true, hasInputIntent: false))
        XCTAssertFalse(FullscreenSpaceHoldDecision.shouldBegin(isFullscreen: false, hasInputIntent: false))
        XCTAssertFalse(FullscreenSpaceHoldDecision.shouldBegin(isFullscreen: true, hasInputIntent: true))
    }

    // While the hold lasts, **transient verdicts in neither direction are let through**. Before 2026-08-30
    // true was applied directly with .apply, so the false true that lagging CG reported at the moment of
    // leaving fullscreen destroyed the 120ms hold, the correct AX false was dropped as .stale, and the bar
    // only came back at the 5-second reconcile (measured fingerprint). true has nothing to do
    // during the hold anyway, the state is already .fullscreen; everything waits for the final check.
    func testFullscreenSpaceHoldSuppressesTransientVerdictsInBothDirections() {
        XCTAssertEqual(
            FullscreenSpaceHoldDecision.disposition(
                isFullscreenVerdict: false,
                expectedGeneration: 4,
                activeGeneration: 4,
                isFinalWindowedConfirmation: false
            ),
            .hold
        )
        XCTAssertEqual(
            FullscreenSpaceHoldDecision.disposition(
                isFullscreenVerdict: true,
                expectedGeneration: 4,
                activeGeneration: 4,
                isFinalWindowedConfirmation: false
            ),
            .hold
        )
    }

    // Regression for the full leave-fullscreen script: the Space-switch arm starts the hold -> a false CG
    // true during the transition must not kill the hold -> a final false is let through and reveals; a final
    // true (a real fullscreen-to-fullscreen switch) is also let through and stays hidden.
    func testFullscreenSpaceHoldExitScenarioRevealsOnFinalVerdictOnly() {
        let g: UInt64 = 9
        // space-cg true during the transition: hold
        XCTAssertEqual(
            FullscreenSpaceHoldDecision.disposition(
                isFullscreenVerdict: true, expectedGeneration: g,
                activeGeneration: g, isFinalWindowedConfirmation: false
            ),
            .hold
        )
        // The following space-ax false (same generation, not final): still hold
        XCTAssertEqual(
            FullscreenSpaceHoldDecision.disposition(
                isFullscreenVerdict: false, expectedGeneration: g,
                activeGeneration: g, isFinalWindowedConfirmation: false
            ),
            .hold
        )
        // 120ms final false: let through -> reveal
        XCTAssertEqual(
            FullscreenSpaceHoldDecision.disposition(
                isFullscreenVerdict: false, expectedGeneration: g,
                activeGeneration: g, isFinalWindowedConfirmation: true
            ),
            .apply
        )
        // 120ms final true (fullscreen to fullscreen): also let through -> stay hidden
        XCTAssertEqual(
            FullscreenSpaceHoldDecision.disposition(
                isFullscreenVerdict: true, expectedGeneration: g,
                activeGeneration: g, isFinalWindowedConfirmation: true
            ),
            .apply
        )
    }

    func testFullscreenSpaceHoldRequiresFinalConfirmationBeforeWindowedReveal() {
        XCTAssertEqual(
            FullscreenSpaceHoldDecision.disposition(
                isFullscreenVerdict: false,
                expectedGeneration: 7,
                activeGeneration: 7,
                isFinalWindowedConfirmation: true
            ),
            .apply
        )
        XCTAssertEqual(FullscreenSpaceHoldDecision.postSpaceConfirmationDelay, 0.12)
        XCTAssertEqual(FullscreenSpaceHoldDecision.activationFallbackDelay, 0.5)
    }

    func testFullscreenSpaceHoldRejectsOldGenerationAndAppliesWithoutHold() {
        XCTAssertEqual(
            FullscreenSpaceHoldDecision.disposition(
                isFullscreenVerdict: false,
                expectedGeneration: 8,
                activeGeneration: 9,
                isFinalWindowedConfirmation: true
            ),
            .stale
        )
        XCTAssertEqual(
            FullscreenSpaceHoldDecision.disposition(
                isFullscreenVerdict: false,
                expectedGeneration: 9,
                activeGeneration: nil,
                isFinalWindowedConfirmation: true
            ),
            .stale
        )
        XCTAssertEqual(
            FullscreenSpaceHoldDecision.disposition(
                isFullscreenVerdict: false,
                expectedGeneration: nil,
                activeGeneration: nil,
                isFinalWindowedConfirmation: false
            ),
            .apply
        )
    }

    func testTaskbarScreenPlacementDefaultsToFollowMouseWithoutWritingKeys() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.taskbarScreenPlacement, .followMouse)
        // A missing key means the default; init must not write the key (invisible to upgrading users).
        XCTAssertNil(defaults.object(forKey: "com.tungsten.edge.taskbarScreen.mode"))
        XCTAssertNil(defaults.object(forKey: "com.tungsten.edge.taskbarScreen.pinned"))
    }

    func testTaskbarScreenPlacementPinnedRoundTrips() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        let selection = PinnedScreenSelection(uuid: "UUID-1", name: "LG HDR 4K")

        store.setTaskbarScreenPlacement(.pinned(selection))

        XCTAssertEqual(store.taskbarScreenPlacement, .pinned(selection))
        let rebuilt = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(rebuilt.taskbarScreenPlacement, .pinned(selection))
    }

    func testTaskbarScreenPlacementPinnedWithBrokenSelectionFallsBackAndRewritesMode() {
        let defaults = makeDefaults()
        defaults.set("pinned", forKey: "com.tungsten.edge.taskbarScreen.mode")
        defaults.set(["uuid": 42], forKey: "com.tungsten.edge.taskbarScreen.pinned")

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.taskbarScreenPlacement, .followMouse)
        XCTAssertEqual(
            defaults.string(forKey: "com.tungsten.edge.taskbarScreen.mode"),
            "followMouse",
            "after a bad selection falls back the mode key must be rewritten at once, otherwise every launch repeats the fallback and the UI does not match the stored value"
        )
    }

    func testTaskbarScreenPlacementUnknownModeDegradesWithoutRewritingKey() {
        let defaults = makeDefaults()
        defaults.set("someFutureMode", forKey: "com.tungsten.edge.taskbarScreen.mode")

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.taskbarScreenPlacement, .followMouse)
        XCTAssertEqual(
            defaults.string(forKey: "com.tungsten.edge.taskbarScreen.mode"),
            "someFutureMode",
            "a tier from a future version read by an old version only runs degraded and does not destroy the user's choice"
        )
    }

    func testTaskbarScreenPlacementAllScreensRoundTrips() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)

        store.setTaskbarScreenPlacement(.allScreens)

        XCTAssertEqual(store.taskbarScreenPlacement, .allScreens)
        XCTAssertEqual(defaults.string(forKey: "com.tungsten.edge.taskbarScreen.mode"), "allScreens")
        XCTAssertEqual(AppSettingsStore(defaults: defaults).taskbarScreenPlacement, .allScreens)

        store.setTaskbarScreenPlacement(.allScreensPerDisplay)
        XCTAssertEqual(defaults.string(forKey: "com.tungsten.edge.taskbarScreen.mode"), "allScreensPerDisplay")
        XCTAssertEqual(AppSettingsStore(defaults: defaults).taskbarScreenPlacement, .allScreensPerDisplay)
    }

    func testTaskbarScreenPlacementAllScreensKeepsPinnedSelectionRemembered() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        let selection = PinnedScreenSelection(uuid: "UUID-1", name: "LG HDR 4K")
        store.setTaskbarScreenPlacement(.pinned(selection))

        store.setTaskbarScreenPlacement(.allScreens)

        XCTAssertNotNil(defaults.dictionary(forKey: "com.tungsten.edge.taskbarScreen.pinned"))
        store.setTaskbarScreenPlacement(.pinned(selection))
        XCTAssertEqual(AppSettingsStore(defaults: defaults).taskbarScreenPlacement, .pinned(selection))
    }

    func testTaskbarScreenPlacementSwitchingBackKeepsPinnedSelectionRemembered() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        let selection = PinnedScreenSelection(uuid: "UUID-1", name: "LG HDR 4K")
        store.setTaskbarScreenPlacement(.pinned(selection))

        store.setTaskbarScreenPlacement(.followMouse)

        XCTAssertEqual(store.taskbarScreenPlacement, .followMouse)
        XCTAssertEqual(defaults.string(forKey: "com.tungsten.edge.taskbarScreen.mode"), "followMouse")
        XCTAssertNotNil(
            defaults.dictionary(forKey: "com.tungsten.edge.taskbarScreen.pinned"),
            "remembered convention: switching back to follow-mouse keeps the last chosen display"
        )
    }

    func testTaskbarPerDisplaySeedArmsOnlyForPristineInstallAndOnlyOnce() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)

        store.armTaskbarPerDisplaySeedForFreshInstall(lineage: .priorUse)
        XCTAssertNil(defaults.object(forKey: "com.tungsten.edge.taskbarScreen.perDisplaySeedPending"))

        store.armTaskbarPerDisplaySeedForFreshInstall(lineage: .pristine)
        XCTAssertTrue(store.taskbarPerDisplaySeedPending)
        store.consumeTaskbarPerDisplaySeedIfPresent()
        store.armTaskbarPerDisplaySeedForFreshInstall(lineage: .pristine)
        XCTAssertFalse(store.taskbarPerDisplaySeedPending, "consumed marker must never re-arm")
    }

    func testAppSettingsStoreInitNeverArmsTaskbarPerDisplaySeed() {
        let defaults = makeDefaults()

        _ = AppSettingsStore(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: "com.tungsten.edge.taskbarScreen.perDisplaySeedPending"))
    }

    func testExplicitUnchangedPlacementChoiceConsumesTaskbarPerDisplaySeed() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        store.armTaskbarPerDisplaySeedForFreshInstall(lineage: .pristine)

        store.setTaskbarScreenPlacement(.followMouse)

        XCTAssertFalse(store.taskbarPerDisplaySeedPending)
        XCTAssertNil(defaults.object(forKey: "com.tungsten.edge.taskbarScreen.mode"))
    }

    func testTaskbarPerDisplaySeedWritesModeAndConsumesMarker() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)
        store.armTaskbarPerDisplaySeedForFreshInstall(lineage: .pristine)

        store.applyTaskbarPerDisplaySeed()

        XCTAssertEqual(store.taskbarScreenPlacement, .allScreensPerDisplay)
        XCTAssertEqual(defaults.string(forKey: "com.tungsten.edge.taskbarScreen.mode"), "allScreensPerDisplay")
        XCTAssertFalse(store.taskbarPerDisplaySeedPending)
    }

    func testTaskbarPlacementChoiceDoesNotCreateSeedMarkerForUpgrader() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)

        store.setTaskbarScreenPlacement(.allScreens)

        XCTAssertNil(defaults.object(forKey: "com.tungsten.edge.taskbarScreen.perDisplaySeedPending"))
    }

    func testPriorUseLineageCannotSeedWindowLift() {
        let defaults = makeDefaults()
        let store = AppSettingsStore(defaults: defaults)

        store.seedWindowLiftEnabledForFreshInstall(lineage: .priorUse)

        XCTAssertFalse(store.windowLiftEnabled)
        XCTAssertNil(defaults.object(forKey: "com.tungsten.edge.windowLiftEnabled"))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "com.tungsten.edge.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

/// Only answers "was the state read on the main thread": if not, `.on`.
private struct ThreadProbeLaunchBackend: LaunchAtLoginBackend {
    func readState() -> LaunchAtLoginState { Thread.isMainThread ? .off : .on }
    func setEnabled(_ enabled: Bool) throws {}
    func openSettings() {}
}
