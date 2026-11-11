import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// Hover hit frames (`StripEntry.id` -> frame in the "strip" coordinate space). **Cards from all four zones
/// go into this one map**: it answers "which card is the pointer over", which is zone-agnostic. Also kept
/// separate from the other three: those feed reorder, popover anchors and release resolution respectively;
/// different semantics, and merging them cross-contaminates (old lesson from review P1).
struct StripHoverFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Folder chip frames (popover anchor + routing of external drag-in pins). Separate from
/// ChipFramePreferenceKey: that one is the input for drag reorder / landing hit-testing in the live window
/// zone, and folder ids mixed in would be treated as landing targets (review P1).
struct FolderChipFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Messaging zone chip frames (bundleID -> frame). Separate from ChipFramePreferenceKey for the same reason
/// as folder chips: mixed into the live reorder / landing hit-test input, window drags would hit the
/// messaging zone and the landing would be a no-op.
struct MessagingChipFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Shelf frame (single value). Separate from FolderChipFramePreferenceKey (review: no sentinel in the folder
/// frame dictionary).
struct ShelfFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

struct TrashFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

// MARK: - Drag-reorder preference (taskbar drag reorder, route A: self-drawn drag)

/// Collects live chip frames by id in the `"strip"` space. Feeds the floating drag copy's
/// position and the left/right-half landing decision (replaces the old width-only key + the
/// SwiftUI DropDelegates, now that the drag is a self-rendered in-app gesture).
struct ChipFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
