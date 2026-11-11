import Foundation

/// The title segment shared by several window cards of one app does nothing to tell them apart, so it is
/// removed from the label (issue #41).
///
/// With two Safari windows on the same profile the titles are "Personal — Start Page" and "Personal —
/// Bilibili". "Personal —" is identical on both cards, yet it pushes the second half, the part that actually
/// tells the windows apart, past `WindowTitleTextMetrics.maximumWidth` (140pt) where it is truncated. The
/// app-name suffix (`WindowDisplayTitle.trimmingAppNameSuffix`) is a special case of this, but it cannot
/// reach **prefix** repetition such as a profile name, nor repetition like "mio: " that is not an app name.
///
/// **Dynamic on purpose** (decided 2026-09-04): once a window on the "Work" profile opens, "Personal" starts
/// telling windows apart, so all three cards show it again. Labels therefore grow and shrink as windows open
/// and close, which is exactly "show only the part that currently distinguishes".
///
/// Called from the projection layer (`DockStripView.makeProjection`), grouped by **the cards this bar
/// actually shows**: in multi-display mode ④ each display shows only its own windows, so the common segment
/// differs per display; computing it in the data layer over the full set would strip the only card left on
/// some display of its sole distinguishing information.
enum StripSharedAffixTrim {
    /// One app's group of titles -> the titles with the common prefix / suffix removed (same order as the
    /// input).
    ///
    /// **All or nothing**: if any title would be trimmed to empty, or the common segment cannot be cut at a
    /// separator boundary, the whole group is returned unchanged. Trimming only some of the cards is the
    /// worst outcome: the user sees a row of misaligned half titles.
    static func trimmingSharedAffixes(_ titles: [String]) -> [String] {
        guard titles.count >= 2 else { return titles }

        let afterPrefix = trimmingSharedPrefix(titles)
        return trimmingSharedSuffix(afterPrefix)
    }

    // MARK: - Prefix

    private static func trimmingSharedPrefix(_ titles: [String]) -> [String] {
        guard let raw = sharedPrefix(titles), !raw.isEmpty else { return titles }
        // **Back off to the last separator boundary**. This step is required: for "mio: Notifications" and
        // "mio: New Tab" the raw common prefix is "mio: N" (both words start with N), and cutting there gives
        // "otifications".
        guard let cut = raw.range(ofLastSeparatorBoundary: separators)?.upperBound else { return titles }
        let affix = String(raw[raw.startIndex..<cut])
        guard !affix.isEmpty else { return titles }

        let trimmed = titles.map { String($0.dropFirst(affix.count)) }
        return isAcceptable(trimmed) ? trimmed.map(cleaned) : titles
    }

    private static func sharedPrefix(_ titles: [String]) -> String? {
        titles.dropFirst().reduce(titles[0]) { $0.commonPrefix(with: $1) }
    }

    // MARK: - Suffix

    private static func trimmingSharedSuffix(_ titles: [String]) -> [String] {
        let reversed = titles.map { String($0.reversed()) }
        guard let rawReversed = sharedPrefix(reversed), !rawReversed.isEmpty else { return titles }
        let raw = String(rawReversed.reversed())
        // For the suffix, find the **first** separator boundary (the leftmost one in the string before
        // reversal).
        guard let cut = raw.range(ofFirstSeparatorBoundary: separators)?.lowerBound else { return titles }
        let affix = String(raw[cut..<raw.endIndex])
        guard !affix.isEmpty else { return titles }

        let trimmed = titles.map { String($0.dropLast(affix.count)) }
        return isAcceptable(trimmed) ? trimmed.map(cleaned) : titles
    }

    // MARK: - Guardrails

    /// Every title must have something left after trimming. An empty label leaves a window card with no name.
    private static func isAcceptable(_ trimmed: [String]) -> Bool {
        trimmed.allSatisfy { !cleaned($0).isEmpty }
    }

    private static func cleaned(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Separator boundaries. Adds the colon to the `WindowDisplayTitle` table: that one only serves the
    /// trailing app name, while prefix repetition like "mio: " relies on the colon. Longer ones come first so
    /// a shorter one does not match first and cut one in half.
    static let separators = [" — ", " – ", " - ", " | ", " · ", " » ", " > ",
                            "：", ": ", "—", "–", "|", "·", "»", ">", ":", "-"]
}

private extension String {
    /// Position of the **last** separator occurrence inside this string (to back off the common prefix).
    func range(ofLastSeparatorBoundary separators: [String]) -> Range<String.Index>? {
        separators.compactMap { range(of: $0, options: .backwards) }
            .max { $0.upperBound < $1.upperBound }
    }

    /// Position of the **first** separator occurrence inside this string (to tighten the common suffix).
    func range(ofFirstSeparatorBoundary separators: [String]) -> Range<String.Index>? {
        separators.compactMap { range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }
    }
}
