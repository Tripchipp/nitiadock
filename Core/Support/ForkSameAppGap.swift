import Foundation

/// fork: which strip entries sit right after a window card of the same app, so the gap before them
/// can be set separately (`ForkAppearance.sameAppSpacing`).
///
/// The strip is one flat row with a uniform gap; cards of one app are usually next to each other
/// (a new window is placed after its app's last card) but there is no group. A pair is "same app"
/// only when two real window cards are adjacent: a divider, an icon, another app or a windowless
/// app-level card in between breaks it.
enum ForkSameAppGap {
    struct Entry: Equatable {
        let id: String
        /// nil / empty for anything that is not a real window card.
        let windowBundleID: String?
    }

    /// Ids of the entries that follow a card of the same app.
    static func followerIDs(in entries: [Entry]) -> Set<String> {
        var followers: Set<String> = []
        for (previous, current) in zip(entries, entries.dropFirst()) {
            guard let bundleID = current.windowBundleID, !bundleID.isEmpty,
                  previous.windowBundleID == bundleID else { continue }
            followers.insert(current.id)
        }
        return followers
    }
}
