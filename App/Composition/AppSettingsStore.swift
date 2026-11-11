import Combine
import Foundation

/// Hover effect level.
/// - `standard`: icon scales 36 -> 24pt + the name pops out below + the folder cell enlarges as a block
///   (native Dock feel).
/// - `quiet`: the taskbar stays **completely still** as the pointer passes over it. No scaling, no movement,
///   no name, no brighter capsule background.
///
/// Two places this level does not affect (decided 2026-08-02): **icons in the drawer panel** behave as
/// before, and the 3x3 grid in the **drawer entry capsule** still enlarges slightly, since the capsule
/// belongs to the drawer. The "full-title popover when the title is too long" stays in both levels: it is the
/// only way to read a truncated title, and it moves no card.
///
/// **Externally this is a single checkbox**: the menu calls it "Show app name on hover", **checked =
/// `.standard`**, unchecked = `.quiet` (renamed 2026-08-02; the original "Hover Effect ▸ Standard / Quiet"
/// was too abstract). That name **deliberately says only half of it**: unchecking also stops icon scaling and
/// folder cell enlargement. Don't narrow the behavior to match the name. Elsewhere the
/// code still uses the internal concept "quiet level" (= `.quiet` = unchecked), and the enum is kept so a
/// third level can be added later.
enum HoverStyle: String, CaseIterable {
    case standard
    case quiet

    /// **Default `.quiet`** (decided 2026-09-01, previously `.standard`): on a fresh install, moving the
    /// pointer over the taskbar shows no app name bubble, only a slight enlargement. Existing users already
    /// have a value in the key and are unaffected.
    static let `default` = HoverStyle.quiet

    /// Whether hover produces **expressive** changes (name bubble, folder cell enlargement). Chip views all
    /// use this as the criterion instead of comparing cases themselves; the menu's checked state reads it too
    /// (`.on` ⟺ `isExpressive`).
    var isExpressive: Bool { self == .standard }

    /// Whether expressive hover is happening right now (name bubble / folder cell enlargement). Shared by all
    /// chips instead of each writing `isExpressive && isHovered`.
    func showsExpressiveHover(isHovering: Bool) -> Bool { isExpressive && isHovering }

    /// Hover feedback for the quiet level: the whole block **enlarges slightly**.
    ///
    /// **Always false in the standard level**: its feedback is the name bubble, and the 2026-08-17
    /// requirement was that the standard level must not change by a single pixel. This was added because the
    /// quiet level originally had **no feedback at all**: moving the app name into the bubble on 2026-08-16
    /// also froze the chip's hover geometry (icon does not shrink, pill does not make room), so the standard
    /// level still had the bubble and the quiet level dropped to zero.
    ///
    /// The first form was a "light background tint with no size change" (the one predicted early
    /// on); after seeing it on a real machine on 2026-08-17 the verdict was "mediocre", and it became a
    /// slight enlargement. **Enlarging is safe today**: the reason it was once rejected was "changing size
    /// reflows the whole row", and that referred to the old layout where the app name was written below the
    /// icon and the card widened as soon as the name appeared. With the name in the bubble neither level
    /// reflows any more, and this uses `scaleEffect` (a pure render transform that does not change layout).
    ///
    func showsQuietHoverFeedback(isHovering: Bool) -> Bool {
        !isExpressive && isHovering
    }
}

/// User-defined shortcut for showing/hiding the taskbar (nil = default ⌥⇧⌘D). `glyphs` is fixed from the
/// NSEvent characters at recording time (see `HotKeyGlyphs` for why); the display side only reads it.
struct StoredHotKeyShortcut: Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let glyphs: String
}


@MainActor
final class AppSettingsStore: ObservableObject {
    static let delayStep: Double = 0.1
    static let finiteDelayMin: Double = 0.1
    static let finiteDelayMax: Double = 3.0
    static let neverHideDelay: Double = -1.0
    static let neverWakeDelay: Double = 999.0
    static let sliderIndexMax = 31
    // nonisolated: referenced in snapDelay's default argument (a nonisolated evaluation context).
    nonisolated static let defaultNativeDockAutoHideDelay: Double = 1.0
    /// **Level for NitiaDock's own bar on a fresh install: always shown** (decided 2026-09-01, previously
    /// auto-hide with a 0.1 s wake). Used only at the one `register` site.
    ///
    /// ⚠️ **This and the one below are two constants and must never be merged.** This one is "what a first
    /// install looks like"; the one below is "which level is used when auto-hide is on". The latter must be a
    /// **finite value**, and two fallbacks depend on it: the remembered value must not be `-1` (otherwise
    /// ⌥⇧⌘D switches from always shown to always shown and the shortcut becomes a no-op), and `snapDelay`'s
    /// non-finite fallback must not be `-1` either (otherwise NaN would be read as the "always shown"
    /// sentinel).
    nonisolated static let firstRunEdgeAutoHideDelay: Double = AppSettingsStore.neverHideDelay
    /// Default level when auto-hide is **on**; also the fallback for remembered and non-finite values. See
    /// the ⚠️ above.
    nonisolated static let defaultEnabledEdgeAutoHideDelay: Double = 0.1

    @Published private(set) var launchAtLogin: Bool
    /// Whether the shelf is shown at the head of the pinned folder zone. When off it is no longer rendered;
    /// stashed files are unaffected.
    @Published private(set) var showShelf: Bool
    /// fork: whether the drawer capsule (and with it the whole app drawer) exists. Off = the capsule
    /// panel is never shown, nothing can be stashed, and apps stashed earlier come back onto the
    /// strip; the stored drawer list is kept and returns when this is switched back on.
    @Published private(set) var showDrawer: Bool
    @Published private(set) var middleClickActions: Bool   // fork
    /// fork: with several displays, an app's windows are cards only on their own display's bar; the
    /// other bars show the app as one icon (`ForkForeignWindowCollapse`). Off by default, unregistered.
    @Published private(set) var collapseForeignWindows: Bool
    /// fork: a trackpad tap as the pointer moves onto an app on the bar (`ForkHaptics`). Off by default,
    /// unregistered.
    @Published private(set) var hapticFeedback: Bool
    /// fork: keep the frontmost window out of the band the bar occupies (`ForkReservedSpace`).
    /// **Off by default and never seeded**: it moves and resizes other apps' windows, which has to be
    /// the user's own choice (same reasoning as `windowLiftEnabled`).
    @Published private(set) var reserveScreenSpace: Bool
    /// fork: the theme-override layer (Settings > Appearance). `.upstream` = nothing overridden.
    @Published private(set) var appearance: ForkAppearance
    @Published private(set) var showTrash: Bool
    /// Taskbar size level. The panel geometry and every chip size in the bar derive from it.
    @Published private(set) var dockSize: DockSize
    /// Hover effect level. Only affects the hover visuals of chips in the bar; the resting layout is
    /// pixel-identical (so no relayout is needed).
    @Published private(set) var hoverStyle: HoverStyle
    /// Maximized windows avoid the taskbar (menu item "Maximized windows avoid the taskbar"). **Seeded on for
    /// fresh installs, stays off for existing users** (2026-09-01; previously off by default for everyone).
    /// It pairs with "taskbar always shown by default" decided in the same round: an always-shown bar covers
    /// the bottom edge of maximized windows, and lift avoidance compensates. But this feature really rewrites
    /// the window size of **other apps**, so an upgrade must not turn it on for existing users. Seeding goes
    /// through `seedWindowLiftEnabledForFreshInstall()`; see the comment there.
    @Published private(set) var windowLiftEnabled: Bool
    /// Predictively hides the taskbar before a standard green-button / Control-Command-F input is delivered.
    /// On by default.
    @Published private(set) var fullscreenIntentEnabled: Bool
    /// Custom shortcut for showing/hiding the taskbar; nil = default ⌥⇧⌘D. **Written only by
    /// `SettingsCoordinator.applyEdgeToggleShortcut` after registration succeeds**: persisting first and then
    /// failing to register would make the stored key and the effective key diverge.
    @Published private(set) var edgeToggleShortcut: StoredHotKeyShortcut?
    /// Where the taskbar is shown. Default `.followMouse` = current behavior (dwell at the bottom edge to
    /// switch display); `.pinned` fixes it to one display.
    @Published private(set) var taskbarScreenPlacement: TaskbarScreenPlacement
    /// This machine has already seen the first-run welcome guide (the screen suggesting to hide the system
    /// Dock).
    /// One-time display state, unrelated to whether the Dock was actually hidden: clicking "Maybe later" also
    /// counts as seen and is not nagged again. Anyone who wants to change it uses the system Dock slider in
    /// the status bar menu.
    @Published private(set) var hasSeenWelcome: Bool
    @Published private(set) var nativeDockAutoHideDelay: Double
    @Published private(set) var edgeAutoHideDelay: Double
    /// Delay value the "auto-hide" toggle (menu / global shortcut) returns to when leaving always shown. Only
    /// finite levels (0.1...3.0) or no wake (999) are allowed, never always shown (-1) itself.
    private(set) var lastEnabledEdgeAutoHideDelay: Double
    /// Mirrored remembered value for the system Dock group, same rule as above (the fallback default level is
    /// 1.0).
    private(set) var lastEnabledNativeDockAutoHideDelay: Double

    var nativeDockAutoHideEnabled: Bool { nativeDockAutoHideDelay != Self.neverHideDelay }
    var edgeAutoHideEnabled: Bool { edgeAutoHideDelay != Self.neverHideDelay }
    var taskbarPerDisplaySeedPending: Bool {
        defaults.bool(forKey: Keys.taskbarScreenPerDisplaySeedPending)
    }
    var hasStoredTaskbarScreenChoice: Bool {
        defaults.object(forKey: Keys.taskbarScreenMode) != nil
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrateLegacyEnabledKey(
            defaults: defaults,
            enabledKey: Keys.nativeDockAutoHideEnabled,
            delayKey: Keys.nativeDockAutoHideDelay
        )
        Self.migrateLegacyEnabledKey(
            defaults: defaults,
            enabledKey: Keys.edgeAutoHideEnabled,
            delayKey: Keys.edgeAutoHideDelay
        )
        // The remembered key (lastEnabledDelay) gets no registered default, to tell "never written" from
        // "actually written". When never written, the seeding logic below decides, instead of silently
        // getting a registered fake history value.
        defaults.register(defaults: [
            Keys.launchAtLogin: false,
            Keys.showShelf: ForkDefaults.showShelf,
            Keys.showDrawer: ForkDefaults.showDrawer,
            Keys.middleClickActions: ForkDefaults.middleClickActions,
            Keys.showTrash: true,
            Keys.fullscreenIntentEnabled: true,
            Keys.nativeDockAutoHideDelay: Self.defaultNativeDockAutoHideDelay,
            // First install = always shown; the remembered seed is still a finite level, see the constant's
            // comment.
            Keys.edgeAutoHideDelay: Self.firstRunEdgeAutoHideDelay,
        ])

        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        showShelf = defaults.bool(forKey: Keys.showShelf)
        showDrawer = defaults.bool(forKey: Keys.showDrawer)
        middleClickActions = defaults.bool(forKey: Keys.middleClickActions)
        collapseForeignWindows = defaults.bool(forKey: Keys.collapseForeignWindows)   // not registered: missing = off
        hapticFeedback = defaults.bool(forKey: Keys.hapticFeedback)   // not registered: missing = off
        appearance = ForkAppearanceStorage.load(from: defaults)
        reserveScreenSpace = defaults.bool(forKey: Keys.reserveScreenSpace)   // not registered: missing = off
        showTrash = defaults.bool(forKey: Keys.showTrash)
        // Deliberately **not** in the register above: missing key = false = stays off for existing users. The
        // one fresh-install case is written to true explicitly by `seedWindowLiftEnabledForFreshInstall()`.
        // Registering true would turn it on for **every** existing user who never touched this switch, and
        // this feature rewrites other apps' window sizes, so it must not take effect silently through an
        // upgrade.
        windowLiftEnabled = defaults.bool(forKey: Keys.windowLiftEnabled)
        // Also deliberately not registered: missing key = false = not subscribed yet.
        // Same as above: missing key = false = welcome guide not seen yet.
        hasSeenWelcome = defaults.bool(forKey: Keys.hasSeenWelcome)
        fullscreenIntentEnabled = defaults.bool(forKey: Keys.fullscreenIntentEnabled)
        // Deliberately not registered: missing key = nil = default ⌥⇧⌘D; bad data (hand-edited, wrong type)
        // also falls back to nil.
        edgeToggleShortcut = Self.storedHotKeyShortcut(defaults.dictionary(forKey: Keys.edgeToggleShortcut))
        // Also deliberately not registered: missing key = false is exactly "off by default"; registering
        // false would read as on by default.
        // Deliberately not registered: missing key = followMouse = current behavior, so upgrades change
        // nothing for existing users.
        let pinnedSelection = Self.storedPinnedScreenSelection(
            defaults.dictionary(forKey: Keys.taskbarScreenPinned)
        )
        switch defaults.string(forKey: Keys.taskbarScreenMode) {
        case nil, TaskbarScreenMode.followMouse.rawValue:
            taskbarScreenPlacement = .followMouse
        case TaskbarScreenMode.allScreens.rawValue:
            taskbarScreenPlacement = .allScreens
        case TaskbarScreenMode.allScreensPerDisplay.rawValue:
            taskbarScreenPlacement = .allScreensPerDisplay
        case TaskbarScreenMode.pinned.rawValue:
            if let pinnedSelection {
                taskbarScreenPlacement = .pinned(pinnedSelection)
            } else {
                // pinned but the selection is missing/bad -> fall back and rewrite the mode key at once (same
                // convention as dockSize: rewrite on a bad value).
                taskbarScreenPlacement = .followMouse
                defaults.set(TaskbarScreenMode.followMouse.rawValue, forKey: Keys.taskbarScreenMode)
            }
        default:
            // Unknown string (a newer version's level read by an older version) -> run as followMouse but
            // **do not rewrite the key**, so a downgrade does not destroy the choice the user made in the
            // newer version.
            taskbarScreenPlacement = .followMouse
        }
        // Bad values (hand-edited, left over from an old version, wrong type) all fall back to the middle
        // level and are **rewritten at once**. Otherwise every launch repeats the fallback, and the level
        // checked in the UI does not match the stored value.
        dockSize = DockSize(rawValue: defaults.string(forKey: Keys.dockSize) ?? "") ?? .default
        hoverStyle = HoverStyle(rawValue: defaults.string(forKey: Keys.hoverStyle) ?? "") ?? .default
        let nativeDelay = Self.sanitizedStoredDelay(
            defaults.object(forKey: Keys.nativeDockAutoHideDelay),
            fallback: Self.defaultNativeDockAutoHideDelay
        )
        nativeDockAutoHideDelay = nativeDelay
        if nativeDelay == Self.neverHideDelay {
            lastEnabledNativeDockAutoHideDelay = Self.sanitizedLastEnabledDelay(
                Self.storedNumericValue(defaults.object(forKey: Keys.nativeDockAutoHideLastEnabledDelay)),
                fallback: Self.defaultNativeDockAutoHideDelay
            )
        } else {
            lastEnabledNativeDockAutoHideDelay = nativeDelay
        }
        let edgeDelay = Self.sanitizedStoredDelay(
            defaults.object(forKey: Keys.edgeAutoHideDelay),
            fallback: Self.defaultEnabledEdgeAutoHideDelay
        )
        edgeAutoHideDelay = edgeDelay
        if edgeDelay == Self.neverHideDelay {
            lastEnabledEdgeAutoHideDelay = Self.sanitizedLastEnabledDelay(
                Self.storedNumericValue(defaults.object(forKey: Keys.edgeAutoHideLastEnabledDelay)),
                fallback: Self.defaultEnabledEdgeAutoHideDelay
            )
        } else {
            lastEnabledEdgeAutoHideDelay = edgeDelay
        }
        defaults.set(dockSize.rawValue, forKey: Keys.dockSize)
        defaults.set(hoverStyle.rawValue, forKey: Keys.hoverStyle)
        defaults.set(nativeDelay, forKey: Keys.nativeDockAutoHideDelay)
        defaults.set(lastEnabledNativeDockAutoHideDelay, forKey: Keys.nativeDockAutoHideLastEnabledDelay)
        defaults.set(edgeDelay, forKey: Keys.edgeAutoHideDelay)
        defaults.set(lastEnabledEdgeAutoHideDelay, forKey: Keys.edgeAutoHideLastEnabledDelay)
        if defaults === UserDefaults.standard { ForkAppearanceModel.shared.apply(appearance) }   // fork
    }

    func setDockSize(_ value: DockSize) {
        guard dockSize != value else { return }
        dockSize = value
        defaults.set(value.rawValue, forKey: Keys.dockSize)
    }

    /// Should be called only by `SettingsCoordinator.applyEdgeToggleShortcut`, **after registration
    /// succeeds** (see the property comment).
    func setEdgeToggleShortcut(_ value: StoredHotKeyShortcut?) {
        guard edgeToggleShortcut != value else { return }
        edgeToggleShortcut = value
        guard let value else {
            defaults.removeObject(forKey: Keys.edgeToggleShortcut)
            return
        }
        defaults.set(
            [
                "keyCode": Int(value.keyCode),
                "modifiers": Int(value.carbonModifiers),
                "glyphs": value.glyphs,
            ],
            forKey: Keys.edgeToggleShortcut
        )
    }

    func setTaskbarScreenPlacement(_ value: TaskbarScreenPlacement) {
        consumeTaskbarPerDisplaySeedIfPresent()
        guard taskbarScreenPlacement != value else { return }
        taskbarScreenPlacement = value
        defaults.set(value.mode.rawValue, forKey: Keys.taskbarScreenMode)
        if let selection = value.pinnedSelection {
            defaults.set(
                ["uuid": selection.uuid, "name": selection.name],
                forKey: Keys.taskbarScreenPinned
            )
        }
        // Switching back to followMouse **keeps** the pinned dictionary (remembered convention, in the spirit
        // of lastEnabledEdgeAutoHideDelay: switching to pinned again still remembers the display chosen last
        // time).
    }

    /// Only a genuinely fresh install may arm this; the store's own init never creates the key.
    func armTaskbarPerDisplaySeedForFreshInstall(lineage: InstallLineage) {
        guard lineage == .pristine,
              defaults.object(forKey: Keys.taskbarScreenPerDisplaySeedPending) == nil
        else { return }
        defaults.set(true, forKey: Keys.taskbarScreenPerDisplaySeedPending)
    }

    func applyTaskbarPerDisplaySeed() {
        setTaskbarScreenPlacement(.allScreensPerDisplay)
    }

    func consumeTaskbarPerDisplaySeedIfPresent() {
        guard defaults.object(forKey: Keys.taskbarScreenPerDisplaySeedPending) != nil,
              defaults.bool(forKey: Keys.taskbarScreenPerDisplaySeedPending)
        else { return }
        defaults.set(false, forKey: Keys.taskbarScreenPerDisplaySeedPending)
    }

    private static func storedPinnedScreenSelection(_ dict: [String: Any]?) -> PinnedScreenSelection? {
        guard let dict,
              let uuid = dict["uuid"] as? String, !uuid.isEmpty,
              let name = dict["name"] as? String
        else { return nil }
        return PinnedScreenSelection(uuid: uuid, name: name)
    }

    private static func storedHotKeyShortcut(_ dict: [String: Any]?) -> StoredHotKeyShortcut? {
        guard let dict,
              let keyCode = dict["keyCode"] as? Int, keyCode >= 0, keyCode <= 0xFFFF,
              let modifiers = dict["modifiers"] as? Int, modifiers >= 0, modifiers <= 0xFFFF_FFFF,
              let glyphs = dict["glyphs"] as? String, !glyphs.isEmpty
        else { return nil }
        return StoredHotKeyShortcut(
            keyCode: UInt32(keyCode),
            carbonModifiers: UInt32(modifiers),
            glyphs: glyphs
        )
    }

    func setHoverStyle(_ value: HoverStyle) {
        guard hoverStyle != value else { return }
        hoverStyle = value
        defaults.set(value.rawValue, forKey: Keys.hoverStyle)
    }

    func setShowShelf(_ value: Bool) {
        guard showShelf != value else { return }
        showShelf = value
        defaults.set(value, forKey: Keys.showShelf)
    }

    /// fork. Persists, then pushes to `ForkAppearanceModel.shared` so views and the static card
    /// metrics pick it up. Only the app's real store (`.standard`) feeds the shared model: the many
    /// tests that build a store on a scratch suite must not repaint global state.
    func setAppearance(_ value: ForkAppearance) {
        let value = value.sanitized
        guard appearance != value else { return }
        ForkAppearanceStorage.save(value, to: defaults)
        if defaults === UserDefaults.standard { ForkAppearanceModel.shared.apply(value) }
        appearance = value
    }

    func setHapticFeedback(_ value: Bool) {
        guard hapticFeedback != value else { return }
        hapticFeedback = value
        defaults.set(value, forKey: Keys.hapticFeedback)
    }

    func setCollapseForeignWindows(_ value: Bool) {
        guard collapseForeignWindows != value else { return }
        collapseForeignWindows = value
        defaults.set(value, forKey: Keys.collapseForeignWindows)
    }

    func setReserveScreenSpace(_ value: Bool) {
        guard reserveScreenSpace != value else { return }
        reserveScreenSpace = value
        defaults.set(value, forKey: Keys.reserveScreenSpace)
    }

    func setMiddleClickActions(_ value: Bool) {
        guard middleClickActions != value else { return }
        middleClickActions = value
        defaults.set(value, forKey: Keys.middleClickActions)
    }

    func setShowDrawer(_ value: Bool) {
        guard showDrawer != value else { return }
        showDrawer = value
        defaults.set(value, forKey: Keys.showDrawer)
    }

    func setShowTrash(_ value: Bool) {
        guard showTrash != value else { return }
        showTrash = value
        defaults.set(value, forKey: Keys.showTrash)
    }

    /// Seeds "lift maximized windows clear of the taskbar" to on for a fresh install (2026-09-01).
    ///
    /// **Only `AppDelegate` may call this, once.** The verdict is `InstallLineage`: a snapshot of the
    /// persistent domain taken at the very start of the process, where an empty domain means a fresh
    /// install. ⚠️ What is load-bearing is *where* that snapshot is taken: `AppDelegate.installLineage`
    /// must be that type's **first stored property**, because this store and its siblings write defaults
    /// inside their own inits, so a snapshot taken one step later is guaranteed to be non-empty. This has
    /// **nothing** to do with the ordering against `recordFirstLaunchIfNeeded()`; that was the old,
    /// now-retired verdict.
    ///
    /// Getting the order wrong fails in the safe direction: a non-empty domain reads as `.priorUse` and
    /// nothing is seeded, so the feature goes silently dead for fresh installs rather than flipping an
    /// existing user. That is why there is **no assertion** here: 71 tests construct this type directly,
    /// and a process-level assert would abort the whole test run on the first one.
    ///
    /// An existing key means the user chose, even if they chose off: always respected, never overwritten.
    func seedWindowLiftEnabledForFreshInstall(lineage: InstallLineage) {
        guard lineage == .pristine else { return }
        guard defaults.object(forKey: Keys.windowLiftEnabled) == nil else { return }
        setWindowLiftEnabled(true)
    }

    func setWindowLiftEnabled(_ value: Bool) {
        guard windowLiftEnabled != value else { return }
        windowLiftEnabled = value
        defaults.set(value, forKey: Keys.windowLiftEnabled)
    }

    func setHasSeenWelcome(_ value: Bool) {
        guard hasSeenWelcome != value else { return }
        hasSeenWelcome = value
        defaults.set(value, forKey: Keys.hasSeenWelcome)
    }

    func setFullscreenIntentEnabled(_ value: Bool) {
        guard fullscreenIntentEnabled != value else { return }
        fullscreenIntentEnabled = value
        defaults.set(value, forKey: Keys.fullscreenIntentEnabled)
    }

    func setLaunchAtLogin(_ value: Bool) {
        guard launchAtLogin != value else { return }
        launchAtLogin = value
        defaults.set(value, forKey: Keys.launchAtLogin)
    }

    func setNativeDockAutoHideDelay(_ value: Double) {
        guard value.isFinite else { return }
        let snapped = Self.snapDelay(value, fallbackForNonFinite: Self.defaultNativeDockAutoHideDelay)
        // The remembered sync comes before active dedup: remembered must be corrected even when active is
        // unchanged.
        if snapped != Self.neverHideDelay, lastEnabledNativeDockAutoHideDelay != snapped {
            lastEnabledNativeDockAutoHideDelay = snapped
            defaults.set(snapped, forKey: Keys.nativeDockAutoHideLastEnabledDelay)
        }
        guard nativeDockAutoHideDelay != snapped else { return }
        nativeDockAutoHideDelay = snapped
        defaults.set(snapped, forKey: Keys.nativeDockAutoHideDelay)
    }

    // The system Dock group deliberately has no blind-flip toggle method: the system state can be changed
    // externally (⌥⌘D / System Settings), and blindly flipping the local stored value flips the wrong way
    // when the two are out of sync. The show/hide command in the menu was removed on 2026-08-01; the whole
    // group is now expressed by a slider + confirm row, and flipping is handed back to the system's own ⌥⌘D.
    //
    // So `lastEnabledNativeDockAutoHideDelay` currently has **no reader** (only that command used it to
    // restore "the last level"): the slider carries its own position and needs no memory. The field and its
    // persistence stay: it is user data, deleting the key is a lossy migration, and the command would need it
    // again if it returns. Not a missed read.

    func setEdgeAutoHideDelay(_ value: Double) {
        guard value.isFinite else { return }
        let snapped = Self.snapDelay(value, fallbackForNonFinite: Self.defaultEnabledEdgeAutoHideDelay)
        // The remembered sync comes before active dedup: remembered must be corrected even when active is
        // unchanged.
        if snapped != Self.neverHideDelay, lastEnabledEdgeAutoHideDelay != snapped {
            lastEnabledEdgeAutoHideDelay = snapped
            defaults.set(snapped, forKey: Keys.edgeAutoHideLastEnabledDelay)
        }
        guard edgeAutoHideDelay != snapped else { return }
        edgeAutoHideDelay = snapped
        defaults.set(snapped, forKey: Keys.edgeAutoHideDelay)
    }

    /// NitiaDock's "auto-hide" toggle: always shown ⇄ the last delay (including no wake, 999). The name
    /// avoids "Now": switching to the auto-hide side does not hide immediately, it still goes through the
    /// usual idle timer and pointer checks.
    func toggleEdgeAutoHideMode() {
        if edgeAutoHideDelay == Self.neverHideDelay {
            setEdgeAutoHideDelay(lastEnabledEdgeAutoHideDelay)
        } else {
            setEdgeAutoHideDelay(Self.neverHideDelay)
        }
    }

    static func delayFromSliderIndex(_ index: Int) -> Double {
        let clamped = min(max(index, 0), sliderIndexMax)
        switch clamped {
        case 0:
            return neverHideDelay
        case sliderIndexMax:
            return neverWakeDelay
        case sliderIndexMax - 1:
            return finiteDelayMax
        default:
            return ((finiteDelayMin + Double(clamped - 1) * delayStep) * 10).rounded() / 10
        }
    }

    static func sliderIndexFromDelay(_ value: Double) -> Int {
        guard value > neverHideDelay else { return 0 }
        guard value < neverWakeDelay else { return sliderIndexMax }
        let clamped = min(max(value, finiteDelayMin), finiteDelayMax)
        return Int(((clamped - finiteDelayMin) / delayStep).rounded()) + 1
    }

    static func snapDelay(_ value: Double, fallbackForNonFinite fallback: Double = AppSettingsStore.defaultEnabledEdgeAutoHideDelay) -> Double {
        // NaN/±inf reaching the Int(...) conversion below would crash outright (every comparison with NaN is
        // false, so clamp has no effect).
        guard value.isFinite else { return fallback }
        if value <= neverHideDelay { return neverHideDelay }
        if value >= neverWakeDelay { return neverWakeDelay }
        let clamped = min(max(value, finiteDelayMin), finiteDelayMax)
        return delayFromSliderIndex(Int(((clamped - finiteDelayMin) / delayStep).rounded()) + 1)
    }

    /// UserDefaults read entry point for the active delay. Only real number objects are accepted; strings,
    /// booleans and non-finite values all fall back to the group's default level, so `double(forKey:)` cannot
    /// silently turn a bad type into 0.0.
    static func sanitizedStoredDelay(_ value: Any?, fallback: Double) -> Double {
        guard let value = storedNumericValue(value) else { return fallback }
        return snapDelay(value, fallbackForNonFinite: fallback)
    }

    /// Defensive funnel for remembered values: missing, wrong type, non-finite, or always shown after
    /// snapping all fall back to the default level (0.1 for the edge group, 1.0 for the system Dock group).
    static func sanitizedLastEnabledDelay(_ value: Double?, fallback: Double = AppSettingsStore.defaultEnabledEdgeAutoHideDelay) -> Double {
        guard let value, value.isFinite else { return fallback }
        let snapped = snapDelay(value, fallbackForNonFinite: fallback)
        return snapped == neverHideDelay ? fallback : snapped
    }

    private static func storedNumericValue(_ value: Any?) -> Double? {
        DefaultsValueParsing.finiteNumericValue(value)
    }

    private static func migrateLegacyEnabledKey(defaults: UserDefaults, enabledKey: String, delayKey: String) {
        if let storedEnabled = defaults.object(forKey: enabledKey) as? Bool, storedEnabled == false {
            defaults.set(neverHideDelay, forKey: delayKey)
        }
        defaults.removeObject(forKey: enabledKey)
    }
}

private enum Keys {
    static let launchAtLogin = "com.tungsten.edge.launchAtLogin"
    static let showShelf = "com.tungsten.edge.showShelf"
    /// fork. Missing key = off.
    static let hapticFeedback = "com.tungsten.edge.hapticFeedback"
    /// fork. Missing key = off.
    static let collapseForeignWindows = "com.tungsten.edge.collapseForeignWindows"
    /// fork. Missing key = off.
    static let reserveScreenSpace = "com.tungsten.edge.reserveScreenSpace"
    /// fork. Missing key = `ForkDefaults.showDrawer`.
    static let showDrawer = "com.tungsten.edge.showDrawer"
    /// fork. Missing key = `ForkDefaults.middleClickActions`.
    static let middleClickActions = "com.tungsten.edge.middleClickActions"
    // Never read the retired com.tungsten.edge.trash.visible key.
    static let showTrash = "com.tungsten.edge.showTrash"
    static let dockSize = "com.tungsten.edge.dockSize"
    static let hoverStyle = "com.tungsten.edge.hoverStyle"
        // `com.tungsten.edge.appearanceMode` was removed together with dark mode (2026-08-16). **The key is
        // left orphaned: not read, not written, not deleted**, so reverting this change can still read back
        // the user's original choice.
    static let windowLiftEnabled = "com.tungsten.edge.windowLiftEnabled"
    static let fullscreenIntentEnabled = "com.tungsten.edge.fullscreenIntentEnabled"
    /// Custom show/hide shortcut (dictionary: keyCode / modifiers / glyphs). Missing key = default ⌥⇧⌘D.
    static let edgeToggleShortcut = "com.tungsten.edge.hotKey.edgeAutoHideMode"
    /// Where the taskbar is shown (followMouse / pinned / allScreens / allScreensPerDisplay). Missing key =
    /// followMouse.
    /// ⚠️ The old `com.tungsten.edge.displayMode` (the early "single display / multi-display" level, removed
    /// with the feature) is an orphan key and is **never read again**. New features only use the
    /// two keys below.
    static let taskbarScreenMode = "com.tungsten.edge.taskbarScreen.mode"
    /// Pinned display identity (dictionary: uuid / name). Kept when switching back to followMouse.
    static let taskbarScreenPinned = "com.tungsten.edge.taskbarScreen.pinned"
    /// A fresh install waiting to first see multiple displays. Missing key = existing user,
    /// false = already consumed.
    static let taskbarScreenPerDisplaySeedPending = "com.tungsten.edge.taskbarScreen.perDisplaySeedPending"
    /// ⚠️ This key name is on users' disks. Renaming it = every subscribed user sees the subscription section
    /// again.
    /// ⚠️ Same as above: renaming it = every existing user is stopped by the welcome guide again on next
    /// launch.
    static let hasSeenWelcome = "com.tungsten.edge.hasSeenWelcome"
    static let nativeDockAutoHideEnabled = "com.tungsten.edge.autoHide.nativeDock.enabled"
    static let nativeDockAutoHideDelay = "com.tungsten.edge.autoHide.nativeDock.delay"
    static let nativeDockAutoHideLastEnabledDelay = "com.tungsten.edge.autoHide.nativeDock.lastEnabledDelay"
    static let edgeAutoHideEnabled = "com.tungsten.edge.autoHide.edge.enabled"
    static let edgeAutoHideDelay = "com.tungsten.edge.autoHide.edge.delay"
    static let edgeAutoHideLastEnabledDelay = "com.tungsten.edge.autoHide.edge.lastEnabledDelay"
}
