//
//  CompanionLore.swift
//  NeuraLink
//
//  What the companion tells about itself as the friendship deepens — Inner
//  life (docs/Companion/LIVING_COMPANION.md). Authored fragments
//  (CharacterLoreCatalogue) sit in three tiers that the relationship stage
//  unlocks; one is offered per visit, untold ones first, and a told story
//  rests before it may come up again.
//
//  Framework-free and unit-tested.
//
//  Created by Dedicatus on 05/11/2026.
//

import Foundation

/// The three doors the relationship stage opens, in order.
nonisolated enum LoreTier: String, CaseIterable, Sendable {
    case friends, goodFriends, close

    /// The relationship stage (`CompanionAffinity` label) that opens it.
    var stage: String {
        switch self {
        case .friends: return "Friends"
        case .goodFriends: return "Good Friends"
        case .close: return "Close"
        }
    }

    var title: String {
        switch self {
        case .friends: return "Quirks and stories"
        case .goodFriends: return "Worries and hopes"
        case .close: return "The harder things"
        }
    }

    var symbol: String {
        switch self {
        case .friends: return "face.smiling"
        case .goodFriends: return "cloud.sun"
        case .close: return "heart"
        }
    }

    /// Every tier open at a stage, lowest first; none before Friends.
    static func unlocked(atStage label: String) -> [LoreTier] {
        switch label {
        case "Friends": return [.friends]
        case "Good Friends": return [.friends, .goodFriends]
        case "Close": return allCases
        default: return []
        }
    }
}

/// One thing the companion may share about itself.
struct LoreFragment: Identifiable, Equatable, Sendable {
    /// Stable key, "<character>.<tier>.<n>"; the reveal table stores it.
    let id: String
    let tier: LoreTier
    let text: String
}

/// A fragment that has been offered to the persona, and when.
struct LoreReveal: Equatable, Sendable {
    let fragmentID: String
    let revealedAt: Date
}

nonisolated enum LoreRules {

    /// A told story is not offered again before this long.
    static let retellAfter: TimeInterval = 3 * 86_400

    /// The fragment to offer this visit: an untold one from the highest
    /// open tier (`roll` in 0..<1 picks among them), else the one told
    /// longest ago once it has rested for `retellAfter`, else nil.
    static func offer(
        from fragments: [LoreFragment], stage: String, reveals: [LoreReveal], now: Date, roll: Double
    ) -> LoreFragment? {
        let open = Set(LoreTier.unlocked(atStage: stage))
        guard !open.isEmpty else { return nil }
        let told = Dictionary(reveals.map { ($0.fragmentID, $0.revealedAt) }, uniquingKeysWith: max)
        let available = fragments.filter { open.contains($0.tier) }

        for tier in LoreTier.allCases.reversed() where open.contains(tier) {
            let untold = available.filter { $0.tier == tier && told[$0.id] == nil }
            guard !untold.isEmpty else { continue }
            let index = min(Int(min(max(roll, 0), 0.999_999) * Double(untold.count)), untold.count - 1)
            return untold[index]
        }

        let rested = available
            .compactMap { fragment in told[fragment.id].map { (fragment, $0) } }
            .min { $0.1 < $1.1 }
        guard let rested, now.timeIntervalSince(rested.1) >= retellAfter else { return nil }
        return rested.0
    }

    /// The Companion State line carrying a fragment.
    static func promptLine(for fragment: LoreFragment) -> String {
        "Something of your own you may share this session, when there is a natural opening "
            + "(never as an announcement, never more than once): \"\(fragment.text)\""
    }

    /// Guidance added once stories are open: disclosure goes both ways.
    static let mutualSharingGuidance =
        "When the user shares something personal or vulnerable, answer with something real of your own "
        + "at this stage of the friendship, not generic sympathy."
}
