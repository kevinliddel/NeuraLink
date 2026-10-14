//
//  CompanionMilestoneTracker.swift
//  NeuraLink
//
//  Records keepsake milestones — Living Companion (docs/LIVING_COMPANION.md).
//  Event milestones are noted where they happen (song match, game start,
//  photo shared, first diary); count-based ones are re-derived whenever the
//  relationship meter refreshes. Stateless: the store serialises itself.
//
//  Created by Dedicatus on 12/10/2026.
//

import Foundation

enum CompanionMilestoneTracker {

    /// Notes an event milestone for `character` (default: the selected
    /// model's identity key, the same key the journal files under).
    static func note(_ kind: MilestoneKind, character: String? = nil, store: MemoryStore = .shared) {
        let key = character ?? RealtimeChatState.shared.selectedCharacterName
        guard !key.isEmpty else { return }
        if store.recordMilestone(character: key, kind: kind) {
            nlLog("[Milestone] \(key) collected \(kind.rawValue)", level: .info)
            KeepsakeUnlockController.shared.present(
                CompanionMilestone(kind: kind, character: key, achievedAt: Date(), celebratedAt: nil))
        }
    }

    /// Re-derives the count-based milestones (first hello, shared days)
    /// from the same totals the affinity curve reads. Only missing ones
    /// touch the database.
    static func refreshDerived(character: String? = nil, store: MemoryStore = .shared) {
        let key = character ?? RealtimeChatState.shared.selectedCharacterName
        guard !key.isEmpty else { return }
        let turns = store.countMessages(role: "user", kind: "message")
        let days = store.distinctUserMessageDays()
        let collected = Set(store.milestones(character: key).map(\.kind))
        for kind in MilestoneRules.derivedKinds(userTurns: turns, sharedDays: days)
        where !collected.contains(kind) {
            note(kind, character: key, store: store)
        }
    }

    /// Prompt line for fresh keepsakes. The first call stamps them
    /// celebrated; the line then stays for `MilestoneRules.celebrationHold`
    /// so one session sees a stable block, and is gone after that.
    static func celebrationLine(character: String, store: MemoryStore = .shared, now: Date = Date()) -> String? {
        let all = store.milestones(character: character)
        guard let line = MilestoneRules.celebrationLine(for: all, now: now) else { return nil }
        for milestone in MilestoneRules.pending(in: all, now: now) where !milestone.celebrated {
            store.markMilestoneCelebrated(character: character, kind: milestone.kind)
        }
        return line
    }
}
