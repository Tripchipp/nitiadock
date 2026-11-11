import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// DockStripView · Hover ownership and name bubble requests (one tracking area for the whole bar).
// Split out of DockStripView.swift as an extension on 2026-09-05, moved without changes.
extension DockStripView {
    // MARK: - Hover ownership (one tracking area for the whole bar)

    /// Re-evaluates "which card is the pointer on", and **writes `@State` only when the result changed**.
    /// The decision is the pure function `StripHoverResolution`: in a gap the nearer card edge wins, and
    /// boundaries don't depend on approach direction.
    ///
    /// Frames and origin are passed in explicitly rather than read from `self`: they are `@State` too, and
    /// inside `onChange` /
    /// `onPreferenceChange` closures they read as the old values.
    func refreshHoveredEntry(frames: [String: CGRect], origin: CGRect) {
        // **Frozen in place** for the first frame or two of a drag: the carrier is laid over the card in the
        // slot's current "hover × press" pose,
        // and clearing hover now would start the card settling back, so the two would no longer match (the
        // 2026-08-19 "vertical ghosting").
        guard !dragController.hoverFrozen else { return }
        let resolved: String? = {
            // No hover evaluation while something is held, and after landing **hold first and evaluate only
            // once the pointer really moves**. Three reasons:
            // ① lighting up whatever the pointer sweeps over mid-drag, with name bubbles, was wrong anyway;
            // ② the release position is always on the card that just landed. The carrier draws the
            //    **non-hover** state,
            //    but the card would reappear already hovered (quiet mode also scales to 1.10), so the sizes
            //    differ
            //    and the handoff frame pops;
            // ③ re-evaluating hover right after the card rests at 1.0 makes quiet mode grow it to 1.10 on the
            //    spot: the icon moves again just after settling,
            //    which is the "landing jitter" reported 2026-08-19. AppKit itself also waits for the mouse to
            //    move after a drag ends
            //    before sending mouseEntered. The hold period is managed by `DragController.hoverHoldPayload`.
            guard !dragController.hoverSuppressed else { return nil }
            // Experiment B: no hover evaluation during an external drag (dragged in from Finder) either.
            // Reason ① above applies verbatim:
            // lighting up whatever is swept over while holding something, with name bubbles, was wrong
            // anyway; and the bubble is a
            // floating panel, so whether repeated order front / out mid-drag disturbs the system's drop
            // target is exactly what is being tested.
            guard !externalDropHoverActive else { return nil }
            guard let pointer = pointerBox.value, origin != .zero else { return nil }
            let point = CGPoint(x: pointer.x - origin.minX, y: origin.maxY - pointer.y)
            let hit = StripHoverResolution.chip(
                at: point,
                frames: frames,
                gapBridge: ForkAppearanceModel.current.resolvedHoverGapBridge() * dockScale   // fork: was defaultGapBridge
            )
            // Only the **one** card flying back / just landed and still waiting for the pointer to move gets
            // no hover; other cards behave normally
            // (2026-08-19: no hover effect on other icons while an icon was in flight). Reason in
            // `DragController.hoverExemptPayload`.
            if let exempt = dragController.hoverExemptPayload,
               carriedStripEntryID(for: exempt) == hit { return nil }
            return hit
        }()
        if resolved != hoveredEntryID {
            hoveredEntryID = resolved
            ForkHaptics.hoverChanged(to: resolved)   // fork
        }
    }

    /// Bubble text for this entry. `nil` = this kind of chip shows no bubble.
    ///
    /// **It shows the app name, not the window title** (2026-08-17; the native Dock's label is always the app
    /// name only).
    /// Pinned folders show none: their name is permanently below the cover; dividers are not chips.
    private func bubbleTitle(for entry: StripEntry) -> String? {
        switch entry {
        case let .window(item):
            return appBubbleName(bundleID: item.bundleIdentifier, fallback: item.appID)
        case let .messagingApp(bid, _):
            return appBubbleName(bundleID: bid, fallback: bid)
        case let .keptApp(bid):
            return appBubbleName(bundleID: bid, fallback: bid)
        case .trash:
            return String(localized: "Trash")
        case .shelf:
            let count = shelfStore.itemPaths.count
            return count > 0
                ? String(format: String(localized: "Shelf · %d"), count)
                : String(localized: "Shelf")
        case .pinnedFolder, .divider, .externalDropGhost:
            // The gap never reports a hover frame, so it can't get here; the hardcoded nil is a second gate.
            return nil
        }
    }

    private func appBubbleName(bundleID: String?, fallback: String) -> String {
        let name = bundleID.map(AppDisplayNameResolver.displayName(for:)) ?? fallback
        return WindowDisplayTitle.resolve(rawTitle: nil, fallbackName: name)
    }

    /// What to give the bubble panel this frame. `nil` = dismiss the bubble.
    ///
    /// Derived as a whole from "pointer position + card geometry + tier", so anchor drift, app name changes
    /// and tier switches
    /// all follow automatically, with no per-card `.refresh` resend; that "content-driven resend" is gone
    /// along with its
    /// ownership guard, because now **only one party** can occupy this panel.
    ///
    /// Quiet mode shows no bubble (`hoverStyle.isExpressive`), same threshold as the pre-change `showsHover`.
    func bubbleRequest(projection: StripProjection) -> WindowTitleTooltipRequest? {
        guard hoverStyle.isExpressive,
              let id = hoveredEntryID,
              let frame = stripHoverFrames[id],
              stripRootScreenRect != .zero,
              let entry = projection.entries.first(where: { $0.id == id }),
              let title = bubbleTitle(for: entry) else { return nil }
        return WindowTitleTooltipRequest(chipID: id,
                                         title: title,
                                         anchorVisibleRect: stripFrameToScreen(frame))
    }

    /// Whether right-clicking the taskbar backplate should pop up the NitiaDock menu. The decision itself is
    /// in the pure `StripContextMenuZone`;
    /// this only converts coordinates and gathers the frames of the four zones (message zone / pinned folder
    /// / shelf frames each have their own
    /// PreferenceKey and are never merged into `chipFrames`).
    func taskbarMenuZoneClaims(atScreen global: CGPoint) -> Bool {
        guard let point = stripPoint(from: global) else { return false }
        var frames = Array(chipFrames.values)
        frames.append(contentsOf: folderChipFrames.values)
        frames.append(contentsOf: messagingChipFrames.values)
        if shelfFrame != .zero { frames.append(shelfFrame) }
        if settingsStore.showTrash, trashFrame != .zero { frames.append(trashFrame) }
        return StripContextMenuZone.claims(
            point: point,
            chipFrames: frames,
            bounds: CGRect(origin: .zero, size: stripRootScreenRect.size),
            minimumGapWidth: ForkAppearanceModel.current.resolvedContextMenuGapThreshold() * dockScale   // fork: was defaultMinimumGapWidth
        )
    }
}
