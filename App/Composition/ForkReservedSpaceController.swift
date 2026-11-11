import AppKit
@preconcurrency import ApplicationServices
import Foundation
import os

/// fork: enforces "Reserve screen space for the taskbar" (`ForkReservedSpace` holds the rules).
///
/// Deliberately small next to `WindowLiftAvoidanceController`, which it sits beside and does not
/// touch. The differences that keep it small:
/// - **Scope: the frontmost app's focused window only.** A background window stays where it is
///   until its app comes forward. That keeps "the app is frontmost" as the signal that a geometry
///   change is the user's doing, and means at most one window is ever being handled.
/// - **Event-driven, no polling.** It evaluates on: app activated, window created, focused window
///   changed, window moved or resized (debounced, and only once the mouse button is up, which is
///   what "move ended" means to an observer), bar shown, and a relevant setting changed.
/// - **Nothing is remembered for restoring.** Switching the setting off stops enforcing; windows
///   stay where they are. So there is no restore queue, no work at quit and no permission freeze.
///
/// Geometry comes from the same host upstream's lift uses. That host returns no context while the
/// bar auto-hides, is hidden, or its screen shows a full-screen Space, which is exactly the "only
/// while the bar is Always Visible" rule; and it is held weakly, so when the panels are torn down
/// (permission loss) this controller simply finds nothing to do.
@MainActor
final class ForkReservedSpaceController {
    private weak var host: WindowLiftAvoidanceHost?
    /// Whether upstream's "Keep maximized windows above the taskbar" is on. Windows that fill the
    /// desktop are then its business: it shrinks them and restores them later, and two controllers
    /// writing the same window would read each other's writes as the app fighting back.
    private let upstreamLiftIsEnabled: () -> Bool
    private let observer = FrontmostWindowGeometryObserver()
    private let logger = Logger(subsystem: "no.thilip.nitiadock", category: "fork-reserved-space")

    private(set) var isEnabled = false
    private var ledger = ForkReservedSpace.Ledger()
    private var activationObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var pendingEvaluation: DispatchWorkItem?
    private var evaluationInFlight = false
    private var needsTrailingEvaluation = false
    /// Bumped on every enable/disable, so work that was in flight across a toggle is dropped.
    private var generation: UInt64 = 0
    private var mouseWaitStartedAt: TimeInterval?

    /// Quiet time after the last geometry event before evaluating. Moved/resized notifications
    /// arrive continuously during a drag.
    private static let settleDelay: TimeInterval = 0.25
    private static let mouseRecheckDelay: TimeInterval = 0.15
    /// Stop waiting for a mouse-up after this long (a stuck button state must not spin forever).
    private static let mouseWaitLimit: TimeInterval = 60
    /// Read from the detached AX tasks, hence nonisolated.
    nonisolated private static let axTimeout: TimeInterval = 0.1

    init(host: WindowLiftAvoidanceHost, upstreamLiftIsEnabled: @escaping () -> Bool) {
        self.host = host
        self.upstreamLiftIsEnabled = upstreamLiftIsEnabled
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        generation &+= 1
        ledger.reset()
        pendingEvaluation?.cancel()
        pendingEvaluation = nil
        mouseWaitStartedAt = nil
        if enabled {
            start()
        } else {
            stop()
        }
    }

    /// The bar appeared, moved, or changed size; or a setting that decides whether it reserves
    /// space changed. Windows that were fine may not be any more.
    func barGeometryMayHaveChanged() {
        guard isEnabled else { return }
        // Give the panels a moment to reach their new frames and the host its new context.
        scheduleEvaluation(after: Self.settleDelay * 2)
    }

    // MARK: - Lifecycle

    private func start() {
        let center = NSWorkspace.shared.notificationCenter
        activationObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { self?.frontmostApplicationChanged(pid: pid) }
        }
        terminationObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier else { return }
            MainActor.assumeIsolated { self?.ledger.forget(pid: pid) }
        }
        observer.onEvent = { [weak self] _ in self?.scheduleEvaluation(after: Self.settleDelay) }
        observer.start(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        scheduleEvaluation(after: Self.settleDelay)
    }

    private func stop() {
        let center = NSWorkspace.shared.notificationCenter
        if let activationObserver { center.removeObserver(activationObserver) }
        if let terminationObserver { center.removeObserver(terminationObserver) }
        activationObserver = nil
        terminationObserver = nil
        observer.stop()
    }

    private func frontmostApplicationChanged(pid: pid_t?) {
        guard isEnabled else { return }
        observer.activate(pid: pid)
        scheduleEvaluation(after: Self.settleDelay)
    }

    // MARK: - Evaluation

    private func scheduleEvaluation(after delay: TimeInterval) {
        guard isEnabled else { return }
        pendingEvaluation?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        pendingEvaluation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func evaluate() {
        pendingEvaluation = nil
        guard isEnabled else { return }
        guard let host else {
            // Panels were torn down (permission loss). Nothing to enforce against; go quiet.
            setEnabled(false)
            return
        }

        // A pressed button means a drag or resize may be in progress. Never move a window out from
        // under the user's pointer: wait for the release, then look again.
        if NSEvent.pressedMouseButtons != 0 {
            let now = ProcessInfo.processInfo.systemUptime
            let startedAt = mouseWaitStartedAt ?? now
            mouseWaitStartedAt = startedAt
            if now - startedAt < Self.mouseWaitLimit { scheduleEvaluation(after: Self.mouseRecheckDelay) }
            return
        }
        mouseWaitStartedAt = nil

        guard !evaluationInFlight else {
            needsTrailingEvaluation = true
            return
        }
        let contexts = host.windowLiftAvoidanceContexts()
        guard !contexts.isEmpty,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              // Regular apps only: the Dock, Control Centre, Notification Centre, Spotlight and other
              // system UI agents are accessory/prohibited processes and are never touched.
              app.activationPolicy == .regular,
              !app.isTerminated else { return }

        evaluationInFlight = true
        let pid = app.processIdentifier
        let skipDesktopFillingWindows = upstreamLiftIsEnabled()
        let startedGeneration = generation
        Task.detached { [weak self] in
            let probe = Self.probeFocusedWindow(
                pid: pid, contexts: contexts, skipDesktopFillingWindows: skipDesktopFillingWindows
            )
            await MainActor.run { [weak self] in
                self?.finishProbe(probe, generation: startedGeneration)
            }
        }
    }

    private func finishProbe(_ probe: Probe?, generation startedGeneration: UInt64) {
        guard isEnabled, generation == startedGeneration, let probe else {
            finishEvaluation()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        // The button may have gone down while the probe ran.
        guard NSEvent.pressedMouseButtons == 0 else {
            finishEvaluation()
            scheduleEvaluation(after: Self.mouseRecheckDelay)
            return
        }
        guard ledger.shouldAct(on: probe.key, now: now) else {
            if ledger.hasGivenUp(on: probe.key) {
                logger.notice("giving up on window \(probe.key.cgWindowID, privacy: .public) of pid \(probe.key.pid, privacy: .public): it came back into the reserved band twice")
            }
            finishEvaluation()
            return
        }

        Task.detached { [weak self] in
            let outcome = Self.write(probe)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.generation == startedGeneration {
                    switch outcome {
                    case .cleared, .stillInBand:
                        self.ledger.recordAction(on: probe.key, now: ProcessInfo.processInfo.systemUptime,
                                                 cleared: outcome == .cleared)
                    case .windowMovedMeanwhile:
                        // Not a disagreement, just bad timing. Look again once things settle.
                        self.needsTrailingEvaluation = true
                    }
                }
                self.finishEvaluation()
            }
        }
    }

    private func finishEvaluation() {
        evaluationInFlight = false
        if needsTrailingEvaluation {
            needsTrailingEvaluation = false
            scheduleEvaluation(after: Self.settleDelay)
        }
    }

    // MARK: - Accessibility (off the main thread)

    private struct Probe: @unchecked Sendable {
        let key: WindowLiftAvoidance.WindowKey
        let element: AXUIElement
        let currentQuartz: CGRect
        let targetQuartz: CGRect
    }

    /// Reads the frontmost app's focused window and decides. `nil` = nothing to do.
    nonisolated private static func probeFocusedWindow(
        pid: pid_t,
        contexts: [WindowLiftAvoidanceContext],
        skipDesktopFillingWindows: Bool
    ) -> Probe? {
        // Own windows are left alone; AX against our own process must not run off the main thread.
        guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        let reader = AXWindowReader()
        guard let window = reader.focusedWindow(forPID: pid) else { return nil }
        _ = AXUIElementSetMessagingTimeout(window, Float(axTimeout))

        // Ordinary document-style windows only. Sheets, dialogs, popovers, floating panels,
        // system dialogs and the like either follow their parent or place themselves on purpose.
        guard reader.stringAttribute(kAXRoleAttribute as CFString, from: window, maxAttempts: 1) == (kAXWindowRole as String),
              reader.stringAttribute(kAXSubroleAttribute as CFString, from: window, maxAttempts: 1)
                == (kAXStandardWindowSubrole as String),
              reader.boolAttribute("AXFullScreen" as CFString, from: window, maxAttempts: 1) != true,
              reader.boolAttribute(kAXMinimizedAttribute as CFString, from: window, maxAttempts: 1) != true,
              let quartz = reader.frame(of: window, maxAttempts: 1),
              let cgWindowID = reader.cgWindowID(for: window, maxAttempts: 1) else { return nil }

        guard let index = WindowLiftAvoidance.owningContextIndex(
            for: quartz, screenCGFrames: contexts.map(\.screenCGFrame)
        ) else { return nil }
        let context = contexts[index]
        let appKit = WindowLiftAvoidance.appKitFrame(fromQuartz: quartz, primaryScreenHeight: context.primaryScreenHeight)
        if skipDesktopFillingWindows, context.geometry.fillsVisibleFrame(appKit) { return nil }

        let decision = ForkReservedSpace.decision(
            window: appKit,
            screenFrame: context.geometry.screenFrame,
            visibleFrame: context.geometry.visibleFrame,
            barTop: context.geometry.taskbarTop
        )
        guard let target = decision.target else { return nil }
        return Probe(
            key: .init(pid: pid, cgWindowID: cgWindowID),
            element: window,
            currentQuartz: quartz,
            targetQuartz: WindowLiftAvoidance.quartzFrame(fromAppKit: target, primaryScreenHeight: context.primaryScreenHeight)
        )
    }

    private enum WriteOutcome: Sendable {
        /// The window verifiably ended up at the target.
        case cleared
        /// Written, but the app clamped, refused or moved it: it is not at the target.
        case stillInBand
        /// Nothing was written: the window was no longer where the probe saw it.
        case windowMovedMeanwhile
    }

    /// Writes the target frame.
    ///
    /// `onlyIfCurrentMatches` makes the write conditional on the window still being where the probe
    /// saw it: if the user grabbed it in between, nothing is written. `AXWindowReader.setFrame`
    /// writes size before position, the safe order here: a too-tall window first shrinks in place
    /// (top fixed) and then slides up, so no intermediate frame leaves the screen. There is no
    /// rollback on failure: a clamped window is left wherever the app put it, and the ledger's
    /// second strike stops further attempts.
    nonisolated private static func write(_ probe: Probe) -> WriteOutcome {
        let result = AXWindowReader().setFrame(
            probe.targetQuartz,
            for: probe.element,
            messagingTimeout: axTimeout,
            verificationTolerance: WindowLiftAvoidance.verificationTolerance,
            onlyIfCurrentMatches: probe.currentQuartz
        )
        switch result {
        case .success:
            return .cleared
        case .failure(reason: .initialFrameMismatch, rollback: _), .failure(reason: .initialFrameUnavailable, rollback: _):
            return .windowMovedMeanwhile
        case .failure:
            return .stillInBand
        }
    }
}
