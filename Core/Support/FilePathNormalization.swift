import Foundation

/// One convention for user-supplied file / folder paths: expand `~`,
/// collapse `..`, strip the trailing slash (except the root `/`).
/// Shared by the shelf (`ShelfStore`) and pinned folders (`PinnedFolderStore`),
/// so existing keys on both sides deduplicate by the same convention.
enum FilePathNormalization {
    nonisolated static func normalized(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
