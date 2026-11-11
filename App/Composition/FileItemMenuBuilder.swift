import AppKit
import UniformTypeIdentifiers

/// Context menu for popup cells (files/folders): hand-built NSMenu (project rule: no SwiftUI contextMenu).
///
/// Close semantics (settled in review, do not revert to "close on all" or "close on none"):
/// - Open / Open With / Show in Finder: **close the popup**
///   after the action (same as clicking a cell to open a file);
/// - Copy / Copy Path / Pin to pinned zone / Remove from Shelf: **do not close**;
/// - Move to Trash: **do not close** (DirectoryWatcher refreshes
///   the grid, and users often delete several in a row).
///
/// Deliberately not done: Quick Look (a nonactivating panel cannot be key window), Get Info, Rename.
@MainActor
enum FileItemMenuBuilder {
    struct Context {
        var url: URL
        var isDirectory: Bool
        /// Closes the popup after open-type actions (the coordinator's close callback).
        var closePopup: () -> Void
        /// "Pin to pinned zone" for directory entries; nil = hidden (not a directory, or already pinned).
        var pinFolder: (() -> Void)?
        /// "Remove from Shelf" in the shelf popup; nil = not the shelf popup.
        var removeFromShelf: (() -> Void)?
        /// Extra cleanup after a successful move to Trash (the shelf popup also removes the stashed entry).
        var onTrashed: (() -> Void)?

        init(url: URL,
             isDirectory: Bool,
             closePopup: @escaping () -> Void,
             pinFolder: (() -> Void)? = nil,
             removeFromShelf: (() -> Void)? = nil,
             onTrashed: (() -> Void)? = nil) {
            self.url = url
            self.isDirectory = isDirectory
            self.closePopup = closePopup
            self.pinFolder = pinFolder
            self.removeFromShelf = removeFromShelf
            self.onTrashed = onTrashed
        }
    }

    static func menu(for context: Context) -> NSMenu {
        let menu = NSMenu()
        let url = context.url
        let closePopup = context.closePopup

        menu.addItem(ClosureMenuItem(String(localized: "Open")) {
            NSWorkspace.shared.open(url)
            closePopup()
        })
        menu.addItem(openWithItem(url: url, closePopup: closePopup))
        menu.addItem(ClosureMenuItem(String(localized: "Show in Finder")) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            closePopup()
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(String(localized: "Copy")) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([url as NSURL])
        })
        menu.addItem(ClosureMenuItem(String(localized: "Copy Path")) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(url.path, forType: .string)
        })
        if context.pinFolder != nil || context.removeFromShelf != nil {
            menu.addItem(.separator())
            if let pinFolder = context.pinFolder {
                menu.addItem(ClosureMenuItem(String(localized: "Pin to Taskbar")) { pinFolder() })
            }
            if let removeFromShelf = context.removeFromShelf {
                menu.addItem(ClosureMenuItem(String(localized: "Remove from Shelf")) { removeFromShelf() })
            }
        }
        menu.addItem(.separator())
        let onTrashed = context.onTrashed
        menu.addItem(ClosureMenuItem(String(localized: "Move to Trash")) {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                TrashStateStore.shared.noteTrashedInApp()
                onTrashed?()
            } catch {
                NSSound.beep()   // failure (permissions, read-only volume): no alert, silent like Finder
            }
        })
        return menu
    }

    /// "Open With ▸" submenu: apps registered with the system as able to open the item, default app on top
    /// and marked. The menu is built on each right-click and the list queried on demand (urlsForApplications
    /// is a local query, milliseconds). Nothing found: one disabled "No Apps Available" item.
    private static func openWithItem(url: URL, closePopup: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "Open With"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        var apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        // Dedupe (several install paths of one app, by standardized
        // path), default app first, the rest sorted by display name.
        var seen = Set<String>()
        apps = apps.filter { seen.insert($0.standardizedFileURL.path).inserted }
        let defaultPath = defaultApp?.standardizedFileURL.path
        apps.sort { a, b in
            if a.standardizedFileURL.path == defaultPath { return true }
            if b.standardizedFileURL.path == defaultPath { return false }
            return displayName(a).localizedStandardCompare(displayName(b)) == .orderedAscending
        }

        if apps.isEmpty {
            let none = NSMenuItem(title: String(localized: "No Apps Available"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        }
        for appURL in apps {
            let isDefault = appURL.standardizedFileURL.path == defaultPath
            let title = isDefault
                ? String(format: String(localized: "%@ (default)"), displayName(appURL))
                : displayName(appURL)
            let appItem = ClosureMenuItem(title) {
                NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                        configuration: NSWorkspace.OpenConfiguration(),
                                        completionHandler: nil)
                closePopup()
            }
            // copy() before changing size: icon(forFile:) is a
            // shared cached object (AppMenuFragments convention).
            let icon = NSWorkspace.shared.icon(forFile: appURL.path).copy() as? NSImage
            icon?.size = NSSize(width: 16, height: 16)
            appItem.image = icon
            submenu.addItem(appItem)
        }
        item.submenu = submenu
        return item
    }

    private static func displayName(_ appURL: URL) -> String {
        FileManager.default.displayName(atPath: appURL.path)
    }
}
