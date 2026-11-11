import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI
import os

// PanelCoordinator · Desktops (Spaces): repair of all-desktops membership (issue #19) and pinning into the
// private Space.
// Split out of PanelCoordinator.swift as an extension on 2026-09-05, moved without changes.
extension PanelCoordinator {
    /// Reads membership back and restores panels that "should be on all desktops but are left on the current
    /// one only".
    ///
    /// For the mechanism and why only this shape works, see `AllSpacesMembership`. None of the three steps
    /// here can be skipped:
    /// ① read back before deciding whether to act: zero side effects when healthy; ② the swapped value must
    /// be assigned back one runloop pass later, reverting within the same pass is the same as not changing
    /// it; ③ read once more after assigning back, **a single repair is not guaranteed to succeed**.
    func repairAllSpacesMembershipIfNeeded(attempt: Int = 1) {
        guard Self.spaceMembershipRepairEnabled, !isSuspendedForPermissionLoss else { return }
        if attempt == 1 && spaceMembershipRepairInFlight { return }
        guard let dock = dockPanel else { return }
        // A panel pinned into the private Space is on no desktop, so this repair would treat it as "lost
        // membership" and keep clearing and reassigning; repair only the unpinned ones (when the host is
        // unavailable = all of them, same as the old behavior).
        let repairCandidates = allSpacesPanels.filter { panel in
            !(overlaySpaceHost?.isPinned(windowNumber: panel.windowNumber) ?? false)
        }
        guard !repairCandidates.isEmpty else {
            spaceMembershipRepairInFlight = false
            return
        }

        guard let uuid = DisplayIdentity.uuidString(for: panelCurrentScreen(panel: dock)),
              let layout = ManagedSpaceLayoutReader.layout(forDisplayUUID: uuid) else {
            spaceMembershipRepairInFlight = false
            return
        }
        let desktops = layout.orderedSpaceIDs.filter { !layout.fullscreenSpaceIDs.contains($0) }

        let broken = repairCandidates.filter { panel in
            guard let owned = WindowSpaceMembershipReader.spaceIDs(forWindowNumber: panel.windowNumber)
            else { return false }   // unreadable = unknown, must not count as "lost"
            return !AllSpacesMembership.missingSpaceIDs(
                windowSpaceIDs: owned,
                desktopSpaceIDs: desktops
            ).isEmpty
        }
        guard !broken.isEmpty else {
            if attempt > 1 {
                logger.info("[space-membership] repaired attempts=\(attempt - 1, privacy: .public)")
            }
            spaceMembershipRepairInFlight = false
            return
        }
        guard AllSpacesMembership.shouldRetry(attempt: attempt - 1) else {
            logger.error("[space-membership] give up after \(attempt - 1, privacy: .public) attempts")
            spaceMembershipRepairInFlight = false
            return
        }

        spaceMembershipRepairInFlight = true
        for panel in broken { panel.collectionBehavior = [] }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for panel in broken { panel.collectionBehavior = PanelCollectionBehavior.standard }
            DispatchQueue.main.asyncAfter(deadline: .now() + AllSpacesMembership.verifyDelay) { [weak self] in
                self?.repairAllSpacesMembershipIfNeeded(attempt: attempt + 1)
            }
        }
    }

    // MARK: - Permanent panels pinned into the private Space (backplate does not turn gray while swiping between desktops)

    /// Pins the taskbar / glass backplate / capsule into the process's single private Space. Mechanism and
    /// measured limits in `OverlaySpaceHost`.
    func pinResidentPanelsIfNeeded() {
        guard let host = overlaySpaceHost, !isSuspendedForPermissionLoss else { return }
        let windowNumbers = allSpacesPanels.map(\.windowNumber)
        guard !windowNumbers.isEmpty else { return }
        if !host.pin(windowNumbers: windowNumbers) {
            logger.error("[overlay-space] pin failed windows=\(windowNumbers, privacy: .public)")
        }
    }

    /// Transient panels (drawer / popup / name tooltip) **must be pinned into the same Space too**: they all
    /// overlap the extent of the taskbar's windows (including the 20pt transparent shadow margin), and
    /// windows left in a desktop Space are composited **below** the private Space regardless of `level`:
    /// the drawer's bottom row darkens where it sits in the capsule window's shadow margin and brightens
    /// again when the launch bounce lifts it (2026-09-03, confirmed by A/B with `DOCK_OVERLAY_SPACE=0`).
    /// Re-pinned after every order front; for an already pinned panel that is just a cheap read-back.
    func pinOverlappingPanelIfNeeded(_ panel: NSPanel) {
        guard let host = overlaySpaceHost, !isSuspendedForPermissionLoss, panel.windowNumber > 0 else { return }
        if !host.pin(windowNumbers: [panel.windowNumber]) {
            logger.error("[overlay-space] pin failed window=\(panel.windowNumber, privacy: .public)")
        }
    }
}
