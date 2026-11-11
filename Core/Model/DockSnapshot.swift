import Foundation

/// Snapshot of the window list the taskbar reads: published by `AppTracker`, consumed by `AppRuntime`, the
/// app-wide source of truth for windows. Split out of `DockState.swift` on 2026-09-05: that file's other half
/// (the `DockState` container) was used only by the old observation pipeline of the diagnostic tool
/// window-lab and moved with the pipeline to `Tools/WindowLab/Pipeline/`.
struct DockSnapshot: Equatable, Sendable {
    var windows: [WindowID: WindowRecord]
    var orderedWindowIDs: [WindowID]

    static let empty = DockSnapshot(windows: [:], orderedWindowIDs: [])
}
