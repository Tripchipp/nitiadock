import AppKit
import ApplicationServices

/// Reads per-app badge strings from the system Dock's accessibility tree.
///
/// Apps publish unread counts by setting their Dock tile badge; there is no public
/// API to read another app's badge directly, but the Dock process exposes each icon
/// as an AX element whose `AXStatusLabel` attribute carries the badge text ("3",
/// "99+", "•"). Mapping element → app uses the Dock item's `AXURL` (the .app bundle
/// URL), which is exact (no name matching).
///
/// Requires Accessibility permission, which this app already needs. Apps only get a
/// Dock icon while running (or pinned), and messaging chips only render while the
/// app runs, so coverage is aligned by construction.
/// Product of one full tree walk: Dock process pid + bundleID -> AXDockItem element references. The
/// references are reused across ticks (a targeted read touches only these few references every 0.5s instead
/// of the whole tree); they are all invalidated and rebuilt on Dock restart, a read error, a failed identity
/// re-check or a change of the message list. AXUIElement is a thread-safe CFType; carrying it across threads
/// follows the same precedent as AXWindowSnapshot.element.
struct DockItemCache: @unchecked Sendable {
    let dockPID: pid_t
    let elementsByBundleID: [String: AXUIElement]
}

struct DockBadgeWalkOutcome {
    let badges: [String: String]
    /// nil when the Dock process was not found (the next tick does another full walk).
    let cache: DockItemCache?
    /// Persistent app path -> bundleID cache (reused across walks, saves the Bundle(url:) disk read on every
    /// tick).
    let pathToBundleID: [String: String]
}

enum DockBadgeTargetedOutcome: Equatable {
    case ok([String: String])
    /// Dock replaced / element read error / identity re-check failed: this round's result is not trustworthy.
    /// The caller must keep the last published value (a transient error must not blink the badge away) and
    /// schedule a full tree walk.
    case cacheInvalid
}

protocol DockBadgeReading: Sendable {
    func readBadges() -> [String: String]
    func fullWalk(previousPathMap: [String: String]) -> DockBadgeWalkOutcome
    func targetedRead(
        cache: DockItemCache,
        bundleIDs: [String],
        previousBadges: [String: String]
    ) -> DockBadgeTargetedOutcome
}

struct DockBadgeReader: DockBadgeReading, Sendable {
    /// Returns [bundleID: badge text] for every Dock item that currently shows a badge.
    /// Call off the main thread; AX messaging to the Dock can block briefly.
    func readBadges() -> [String: String] {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(dockElement, 0.25)

        var bundleIDByPath: [String: String] = [:]
        var result: [String: String] = [:]
        // Dock AX hierarchy: application element → AXList children → AXDockItem children.
        for list in children(of: dockElement) {
            for item in children(of: list) {
                guard let badge = stringAttribute("AXStatusLabel", of: item),
                      !badge.isEmpty,
                      let url = urlAttribute(kAXURLAttribute as String, of: item),
                      let bundleID = bundleID(forAppURL: url, cache: &bundleIDByPath) else { continue }
                result[bundleID] = badge
            }
        }
        return result
    }

    /// Full tree walk: the same tree as `readBadges()`, but it also caches the element reference of **every**
    /// app tile (one more AXURL read per item), so that each later tick reads only the one or two message app
    /// elements. The walk is infrequent (10s self-heal + list change + read error recovery) and not on the
    /// 0.5s hot path.
    func fullWalk(previousPathMap: [String: String]) -> DockBadgeWalkOutcome {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return DockBadgeWalkOutcome(badges: [:], cache: nil, pathToBundleID: previousPathMap)
        }

        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(dockElement, 0.25)

        var pathMap = previousPathMap
        var badges: [String: String] = [:]
        var elements: [String: AXUIElement] = [:]
        for list in children(of: dockElement) {
            for item in children(of: list) {
                guard let url = urlAttribute(kAXURLAttribute as String, of: item),
                      let bid = bundleID(forAppURL: url, cache: &pathMap) else { continue }
                _ = AXUIElementSetMessagingTimeout(item, 0.25)
                elements[bid] = item
                if let badge = stringAttribute("AXStatusLabel", of: item) {
                    badges[bid] = badge
                }
            }
        }
        return DockBadgeWalkOutcome(
            badges: badges,
            cache: DockItemCache(dockPID: dock.processIdentifier, elementsByBundleID: elements),
            pathToBundleID: pathMap
        )
    }

    /// Targeted read: reads AXStatusLabel only for the items in `bundleIDs` that have a cached element (1~3
    /// AX round trips per tick). Three conservative invalidations: ① Dock pid replaced; ② any read error
    /// other than "no badge"; ③ **items whose value changed** have their element's AXURL re-checked against
    /// the same bundleID before publishing (closes the silent "recycled element reports another app's count"
    /// error; zero cost in steady state, since unchanged values are not re-checked).
    func targetedRead(
        cache: DockItemCache,
        bundleIDs: [String],
        previousBadges: [String: String]
    ) -> DockBadgeTargetedOutcome {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first,
              dock.processIdentifier == cache.dockPID else { return .cacheInvalid }

        var badges: [String: String] = [:]
        for bid in bundleIDs {
            guard let item = cache.elementsByBundleID[bid] else { continue }
            switch statusLabelRead(of: item) {
            case .value(let badge): badges[bid] = badge
            case .absent: break
            case .readError: return .cacheInvalid
            }
        }
        for bid in bundleIDs where badges[bid] != previousBadges[bid] {
            guard let item = cache.elementsByBundleID[bid],
                  let url = urlAttribute(kAXURLAttribute as String, of: item),
                  Bundle(url: url)?.bundleIdentifier == bid else { return .cacheInvalid }
        }
        return .ok(badges)
    }

    // MARK: - AX helpers

    private enum AttributeRead {
        case value(String)
        /// Normal "no badge": read succeeded but empty / no value / attribute unsupported.
        case absent
        /// Other errors (invalid element, timeout, ...): must be told apart from "no badge", or a transient
        /// error blinks the badge away.
        case readError
    }

    private func statusLabelRead(of element: AXUIElement) -> AttributeRead {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, "AXStatusLabel" as CFString, &value)
        switch err {
        case .success:
            guard let text = value as? String else { return .absent }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .absent : .value(trimmed)
        case .noValue, .attributeUnsupported:
            return .absent
        default:
            return .readError
        }
    }


    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return [] }
        return elements
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func urlAttribute(_ attribute: String, of element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let url = value as? NSURL else { return nil }
        return url as URL
    }

    private func bundleID(forAppURL url: URL, cache: inout [String: String]) -> String? {
        let path = url.path
        if let cached = cache[path] { return cached }
        guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return nil }
        cache[path] = bundleID
        return bundleID
    }
}
