//
//  CompanionMilestoneTests.swift
//  NeuraLinkTests
//
//  Keepsake milestones (docs/LIVING_COMPANION.md): the pure unlock rules,
//  the once-only celebration line, and the store's idempotent record.
//  Shares the app-host MemoryStore singleton under a throwaway character.
//

import Foundation
import Testing

@testable import NeuraLink

@MainActor
@Suite("Companion Milestones")
struct CompanionMilestoneTests {

    private let character = "test-keepsakes-\(UUID().uuidString.prefix(8))"

    private func cleanup() {
        MemoryStore.shared.deleteMilestones(character: character)
    }

    private func milestone(_ kind: MilestoneKind, ageDays: Double, shownHoursAgo: Double? = nil) -> CompanionMilestone {
        CompanionMilestone(
            kind: kind, character: character,
            achievedAt: Date().addingTimeInterval(-ageDays * 86_400),
            celebratedAt: shownHoursAgo.map { Date().addingTimeInterval(-$0 * 3_600) })
    }

    // MARK: - Pure rules

    @Test("First hello needs one turn; day keepsakes unlock at 7 / 30 / 100 shared days")
    func derivedKinds() {
        #expect(MilestoneRules.derivedKinds(userTurns: 0, sharedDays: 0).isEmpty)
        #expect(MilestoneRules.derivedKinds(userTurns: 1, sharedDays: 1) == [.firstConversation])
        #expect(MilestoneRules.derivedKinds(userTurns: 9, sharedDays: 7) == [.firstConversation, .sevenDays])
        #expect(
            MilestoneRules.derivedKinds(userTurns: 9, sharedDays: 30)
                == [.firstConversation, .sevenDays, .thirtyDays])
        #expect(MilestoneRules.derivedKinds(userTurns: 9, sharedDays: 100).contains(.hundredDays))
    }

    @Test("Celebration line names fresh keepsakes: never shown, or shown within the hold")
    func celebrationLine() {
        let fresh = milestone(.firstSharedSong, ageDays: 0.5)
        let held = milestone(.firstDiary, ageDays: 1, shownHoursAgo: 0.5)
        let stale = milestone(.firstGame, ageDays: 10)
        let done = milestone(.firstPhoto, ageDays: 1, shownHoursAgo: 3)
        let line = MilestoneRules.celebrationLine(for: [stale, done, fresh, held])
        #expect(line?.contains("First shared song") == true)
        #expect(line?.contains("First diary entry") == true)
        #expect(line?.contains("First game together") == false)
        #expect(line?.contains("First photo shared") == false)
        #expect(MilestoneRules.celebrationLine(for: [stale, done]) == nil)
    }

    @Test("Every kind carries a title, a detail line and a symbol")
    func copyIsComplete() {
        for kind in MilestoneKind.allCases {
            #expect(!kind.title.isEmpty)
            #expect(!kind.detail.isEmpty)
            #expect(!kind.symbol.isEmpty)
        }
        #expect(MilestoneKind.allCases.map(\.rawValue).count == Set(MilestoneKind.allCases.map(\.rawValue)).count)
    }

    // MARK: - Store

    @Test("A keepsake is recorded once per character and read back oldest-first")
    func recordOnce() {
        defer { cleanup() }
        #expect(MemoryStore.shared.recordMilestone(character: character, kind: .firstGame))
        #expect(!MemoryStore.shared.recordMilestone(character: character, kind: .firstGame))
        MemoryStore.shared.recordMilestone(character: character, kind: .firstPhoto)

        let rows = MemoryStore.shared.milestones(character: character)
        #expect(rows.map(\.kind) == [.firstGame, .firstPhoto])
        #expect(rows.allSatisfy { !$0.celebrated && $0.character == character })
        #expect(MemoryStore.shared.milestones(character: character + "-other").isEmpty)
    }

    @Test("The tracker's celebration line holds for one session, then goes quiet for good")
    func trackerCelebratesOnce() {
        defer { cleanup() }
        CompanionMilestoneTracker.note(.firstSharedSong, character: character)
        CompanionMilestoneTracker.note(.firstSharedSong, character: character)

        let first = CompanionMilestoneTracker.celebrationLine(character: character)
        #expect(first?.contains("First shared song") == true)
        #expect(MemoryStore.shared.milestones(character: character).first?.celebrated == true)
        // Same session: the block stays stable (KV prefix / instruction refresh).
        #expect(CompanionMilestoneTracker.celebrationLine(character: character) == first)
        // Next session, after the hold: nothing left to celebrate.
        let later = Date().addingTimeInterval(MilestoneRules.celebrationHold + 60)
        #expect(CompanionMilestoneTracker.celebrationLine(character: character, now: later) == nil)
    }

    @Test("Derived refresh records the first hello once the user has spoken to this character")
    func derivedRefresh() {
        defer { cleanup() }
        // Nothing said to this character yet: no first hello, whoever else you talk to.
        CompanionMilestoneTracker.refreshDerived(character: character)
        #expect(MemoryStore.shared.milestones(character: character).isEmpty)

        let id = MemoryStore.shared.insertConversation(title: "keepsake-test")
        defer { MemoryStore.shared.deleteConversation(id: id) }
        MemoryStore.shared.insertMessage(
            conversationID: id, role: "user", kind: "message", content: "hello", character: character)
        CompanionMilestoneTracker.refreshDerived(character: character)
        let kinds = Set(MemoryStore.shared.milestones(character: character).map(\.kind))
        #expect(kinds.contains(.firstConversation))
        #expect(kinds.isDisjoint(with: [.firstSharedSong, .firstGame, .firstPhoto, .firstDiary]))
    }
}
