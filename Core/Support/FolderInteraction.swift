import Foundation

/// Switchable policy for the pinned folder's "primary left-click action".
///
/// Reserved for A/B: to switch between "left click previews" and "left click opens a Finder
/// window" later, change only this (or wire `primaryAction` to settings and return the
/// user's choice). **All left-click call sites go through `DockStripView.folderPrimaryTap`**
/// rather than hardcoding behavior in each place, to avoid scattering.
enum FolderPrimaryAction {
    /// Left click = open a Finder window for this path.
    case openFinderWindow
    /// Left click = open the contents preview popover.
    case preview
}

enum FolderInteraction {
    /// Currently pinned folder left click = contents preview (2026-07-09:
    /// left click should feel like a "click to open, click to close" toggle;
    /// opening a real Finder window moved to the right-click
    /// "Open in Finder"). For an A/B, change only this place.
    static var primaryAction: FolderPrimaryAction { .preview }
}
