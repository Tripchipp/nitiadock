import Foundation
import os

/// Publishes [bundleID: badge text] read from the system Dock (see DockBadgeReader).
/// Polls every 0.5s off the main thread (clearing an unread badge must feel immediate:
/// the cadence while visible is a product requirement and never stretches). Since the
/// targeted-read rework the per-tick work is 1-3 AX round trips against cached AXDockItem
/// elements instead of a full Dock-tree walk, and the published dict is scoped to the
/// messaging apps that can actually show a badge (messaging **identity** ∩ running, minus
/// drawer; since 2026-08-23 the badge follows the app, not the zone: a messaging app's
/// leftmost strip card paints it whether it sits in the zone or in the live zone). A tick
/// with no readable messaging app performs zero AX traffic. Publishes only on change so
/// SwiftUI doesn't re-render chips for identical badge state.
/// Kill switch DOCK_BADGE_TARGETED=0 restores the legacy full-tree walk every tick.
@MainActor
final class BadgeStore: ObservableObject {
    @Published private(set) var badgesByBundleID: [String: String] = [:]

    private let reader: any DockBadgeReading
    private let targetedEnabled: Bool
    /// Zero-perception gating (board card "pause badge polling when there are no messaging apps"): when the
    /// readable set is empty or the taskbar is logically hidden, the timer is stopped as well; when the
    /// resume condition appears it restarts and **reads once immediately**. DOCK_BADGE_PAUSE=0 turns this off
    /// (the timer stays up, behavior returns to "empty ticks, zero AX traffic").
    private let pauseEnabled: Bool
    private let uptimeProvider: () -> TimeInterval
    private var timer: Timer?
    private var isStarted = false
    private var isReading = false
    private var itemCache: DockItemCache?
    private var cacheCapturedAt: TimeInterval = 0
    private var pathToBundleID: [String: String] = [:]
    private var rewalkRequested = false
    /// Readable set = messaging app identity ∩ running − drawer (`AppMembershipProjection.badgeEligibleIDs`,
    /// pushed in by AppDelegate).
    private var readableMessagingIDs: [String] = []
    private var taskbarVisible = true
    private let logger = Logger(subsystem: "no.thilip.nitiadock", category: "Badge")

    init(
        reader: any DockBadgeReading = DockBadgeReader(),
        targetedEnabled: Bool = DebugSwitch.badgeTargeted.isEnabled(in: ProcessInfo.processInfo.environment),
        pauseEnabled: Bool = DebugSwitch.badgePause.isEnabled(in: ProcessInfo.processInfo.environment),
        uptimeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.reader = reader
        self.targetedEnabled = targetedEnabled
        self.pauseEnabled = pauseEnabled
        self.uptimeProvider = uptimeProvider
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        reconcileTimerState()
    }

    func stop() {
        isStarted = false
        timer?.invalidate()
        timer = nil
    }

    /// Logical taskbar visibility (both hide paths in PanelCoordinator must notify this). The last published
    /// value is kept while hidden: on reappearing, chips show the old badge at once and the resume read
    /// corrects it within ~50ms, without a flicker.
    func setTaskbarVisible(_ visible: Bool) {
        guard visible != taskbarVisible else { return }
        taskbarVisible = visible
        reconcileTimerState()
    }

    private var shouldPauseTimer: Bool {
        guard targetedEnabled, pauseEnabled else { return false }
        return readableMessagingIDs.isEmpty || !taskbarVisible
    }

    /// Gating state machine: pause -> tear down the timer; resume -> rebuild the timer and read once
    /// immediately (this read is what meets the product requirement that badges clear promptly). start() /
    /// list changes / visibility changes all funnel here.
    private func reconcileTimerState() {
        guard isStarted else { return }
        if shouldPauseTimer {
            timer?.invalidate()
            timer = nil
            // With no readable messaging apps the dictionary is necessarily empty; the hidden state keeps the
            // old values (see setTaskbarVisible).
            if readableMessagingIDs.isEmpty, !badgesByBundleID.isEmpty { publishIfChanged([:]) }
        } else if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.readOnce() }
            }
            timer?.tolerance = 0.05
            readOnce()
        }
    }

    deinit {
        timer?.invalidate()
    }

    /// The messaging list or the running set changed: the Dock tile set changes as messaging apps
    /// launch/quit, so the cache is invalidated and re-walked. "A messaging app just launched and its new
    /// tile shows a badge" is picked up through this within ~1s (new tile = the app entered the running set).
    func updateMessagingContext(visibleMessagingIDs: [String], runningBundleIDs: Set<String>) {
        let readable = visibleMessagingIDs.filter { runningBundleIDs.contains($0) }
        guard readable != readableMessagingIDs else { return }
        readableMessagingIDs = readable
        rewalkRequested = true
        reconcileTimerState()
    }

    private func readOnce() {
        guard !isReading else { return }   // serialize: skip a tick if the last read is still running
        guard targetedEnabled else {
            performLegacyRead()
            return
        }
        switch BadgeReadPlan.verdict(.init(
            messagingBundleIDs: readableMessagingIDs,
            taskbarVisible: taskbarVisible,
            hasCache: itemCache != nil,
            cacheAgeSeconds: uptimeProvider() - cacheCapturedAt,
            rewalkRequested: rewalkRequested
        )) {
        case .pause:
            if readableMessagingIDs.isEmpty, !badgesByBundleID.isEmpty { publishIfChanged([:]) }
        case .fullWalk:
            performFullWalk()
        case .targeted(let bundleIDs):
            guard let cache = itemCache else {
                performFullWalk()
                return
            }
            performTargetedRead(cache: cache, bundleIDs: bundleIDs)
        }
    }

    private func performFullWalk() {
        isReading = true
        // Clear the rewalk flag at the start: if the list changes again during the tree walk it is set again
        // and the next tick walks again (clearing at landing would swallow it).
        rewalkRequested = false
        let reader = reader
        let pathMap = pathToBundleID
        Task.detached { [weak self] in
            let outcome = reader.fullWalk(previousPathMap: pathMap)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isReading = false
                self.itemCache = outcome.cache
                self.cacheCapturedAt = self.uptimeProvider()
                self.pathToBundleID = outcome.pathToBundleID
                self.publishIfChanged(
                    outcome.badges.filter { self.readableMessagingIDs.contains($0.key) }
                )
            }
        }
    }

    private func performTargetedRead(cache: DockItemCache, bundleIDs: [String]) {
        isReading = true
        let reader = reader
        let previous = badgesByBundleID
        Task.detached { [weak self] in
            let outcome = reader.targetedRead(
                cache: cache,
                bundleIDs: bundleIDs,
                previousBadges: previous
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isReading = false
                switch outcome {
                case .ok(let badges):
                    self.publishIfChanged(badges)
                case .cacheInvalid:
                    // A transient read error does not publish a missing value (badges must not flicker away):
                    // keep the last value and re-walk the whole tree on the next tick.
                    self.rewalkRequested = true
                }
            }
        }
    }

    /// DOCK_BADGE_TARGETED=0: the unchanged pre-rework path. Whole tree, all badges, no scope filtering.
    private func performLegacyRead() {
        isReading = true
        let reader = reader
        Task.detached { [weak self] in
            let badges = reader.readBadges()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isReading = false
                self.publishIfChanged(badges)
            }
        }
    }

    private func publishIfChanged(_ badges: [String: String]) {
        guard badges != badgesByBundleID else { return }
        badgesByBundleID = badges
        // Diagnostic: badge dict as published, logged on change only. Scoped to messaging
        // apps since the targeted-read rework (legacy kill-switch path still logs all).
        logger.info("badges-changed \(badges.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "), privacy: .public)")
    }

    #if DEBUG
    func readOnceForTesting() {
        readOnce()
    }

    var isReadingForTesting: Bool { isReading }
    var isTimerRunningForTesting: Bool { timer != nil }
    #endif
}
