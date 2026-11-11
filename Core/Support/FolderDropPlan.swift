import Foundation

/// Eligibility filter before external files are moved into a pinned
/// folder. Only judges path and resource facts, never touches the disk.
enum FolderDropPlan {
    private struct Candidate {
        let original: URL
        let canonical: URL
        let isDirectory: Bool
        let isSymbolicLink: Bool
        let caseSensitive: Bool
    }

    static func eligibleSources(_ sources: [URL], destination: URL) -> [URL] {
        let destination = destination.standardizedFileURL.resolvingSymlinksInPath()
        let destinationCaseSensitive = volumeIsCaseSensitive(destination)

        var unique: [Candidate] = []
        for source in sources {
            let candidate = makeCandidate(source)
            let caseSensitive = candidate.caseSensitive && destinationCaseSensitive

            guard !pathsEqual(candidate.canonical, destination, caseSensitive: caseSensitive) else { continue }
            guard !pathsEqual(candidate.canonical.deletingLastPathComponent(), destination,
                              caseSensitive: caseSensitive) else { continue }
            if candidate.isDirectory, !candidate.isSymbolicLink,
               isDescendant(destination, of: candidate.canonical, caseSensitive: caseSensitive) {
                continue
            }
            guard !unique.contains(where: {
                pathsEqual($0.canonical, candidate.canonical,
                           caseSensitive: $0.caseSensitive && candidate.caseSensitive)
            }) else { continue }
            unique.append(candidate)
        }

        // When a parent directory and items inside it are selected in the same batch,
        // move only the parent, so child sources do not go stale after the parent moves.
        return unique.filter { candidate in
            !unique.contains { possibleParent in
                guard possibleParent.canonical != candidate.canonical,
                      possibleParent.isDirectory,
                      !possibleParent.isSymbolicLink else { return false }
                return isDescendant(candidate.canonical, of: possibleParent.canonical,
                                    caseSensitive: candidate.caseSensitive && possibleParent.caseSensitive)
            }
        }.map(\.original)
    }

    private static func makeCandidate(_ source: URL) -> Candidate {
        let original = source.standardizedFileURL
        let canonicalParent = original.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        // Resolve only the parent path and keep the leaf: dragging
        // in a symlink moves the link itself, not its target.
        let canonical = canonicalParent
            .appendingPathComponent(original.lastPathComponent)
            .standardizedFileURL
        let values = try? original.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return Candidate(
            original: original,
            canonical: canonical,
            isDirectory: values?.isDirectory ?? false,
            isSymbolicLink: values?.isSymbolicLink ?? false,
            caseSensitive: volumeIsCaseSensitive(canonicalParent)
        )
    }

    private static func volumeIsCaseSensitive(_ url: URL) -> Bool {
        // When unreadable, treat as case-insensitive: the eligibility
        // filter should over-reject rather than miss self-nesting.
        (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames ?? false
    }

    private static func pathsEqual(_ lhs: URL, _ rhs: URL, caseSensitive: Bool) -> Bool {
        componentsEqual(lhs.pathComponents, rhs.pathComponents, caseSensitive: caseSensitive)
    }

    private static func isDescendant(_ child: URL, of parent: URL, caseSensitive: Bool) -> Bool {
        let childComponents = child.pathComponents
        let parentComponents = parent.pathComponents
        guard childComponents.count > parentComponents.count else { return false }
        return componentsEqual(Array(childComponents.prefix(parentComponents.count)),
                               parentComponents,
                               caseSensitive: caseSensitive)
    }

    private static func componentsEqual(_ lhs: [String], _ rhs: [String], caseSensitive: Bool) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            if caseSensitive { return left == right }
            return left.compare(right, options: [.caseInsensitive, .literal]) == .orderedSame
        }
    }
}
