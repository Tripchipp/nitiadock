import Foundation

/// Read plan for each tick of badge polling (pure decision). Hard product constraint: **the cadence stays at
/// 0.5s while visible**. This type only decides "what to read and how" for this tick and never lengthens the
/// interval:
/// - `pause`: no readable messaging app (visible ∩ running is empty) or the taskbar is logically hidden ->
///   zero AX traffic this tick. When the resume condition appears the caller **reads once immediately**
///   (imperceptible gating, board card "pause badge polling when there is no messaging app").
/// - `fullWalk`: the Dock item element cache must be rebuilt (no cache / rewalk requested / 10s self-heal
///   due; self-heal covers pathological cases with no error signal such as a Dock icon being pinned or
///   reordered, worst-case staleness bound 10s).
/// - `targeted`: targeted reads through cached elements (1~3 AX round trips instead of 25~45 for the whole
///   Dock tree).
enum BadgeReadPlan {
    static let defaultFullWalkInterval: TimeInterval = 10

    struct Input {
        /// Apps whose badge must be read this tick: visible in the messaging zone **∩** running (kept but not
        /// running has no Dock tile).
        var messagingBundleIDs: [String]
        var taskbarVisible: Bool
        var hasCache: Bool
        var cacheAgeSeconds: TimeInterval
        var rewalkRequested: Bool
        var fullWalkInterval: TimeInterval = BadgeReadPlan.defaultFullWalkInterval
    }

    enum WalkReason: String, Equatable {
        case noCache
        case rewalkRequested
        case selfHealDue
    }

    enum Verdict: Equatable {
        case pause
        case fullWalk(WalkReason)
        case targeted([String])
    }

    static func verdict(_ input: Input) -> Verdict {
        if input.messagingBundleIDs.isEmpty || !input.taskbarVisible { return .pause }
        if !input.hasCache { return .fullWalk(.noCache) }
        if input.rewalkRequested { return .fullWalk(.rewalkRequested) }
        if input.cacheAgeSeconds >= input.fullWalkInterval { return .fullWalk(.selfHealDue) }
        return .targeted(input.messagingBundleIDs)
    }
}
