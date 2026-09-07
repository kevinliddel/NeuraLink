//
//  CompanionFoundationTests.swift
//  NeuraLinkTests
//
//  Living Companion Phase 0: companion_journal / persona_traits CRUD and
//  InteractionClock. Shares the app-host MemoryStore singleton like
//  ImportedCharacterStoreTests — each test uses its own character namespace
//  and cleans up after itself.
//

import Foundation
import Testing

@testable import NeuraLink

@Suite("Living Companion Foundations")
struct CompanionFoundationTests {

    private func cleanup(_ characters: String...) {
        for character in characters {
            MemoryStore.shared.deleteJournal(character: character)
            MemoryStore.shared.deleteAllTraits(character: character)
        }
    }

    // MARK: - Journal

    @Test("Journal insert and fetch round-trips every column")
    func journalRoundTrip() {
        let character = "test_journal_roundtrip"
        cleanup(character)
        defer { cleanup(character) }

        let id = MemoryStore.shared.insertJournalEntry(
            character: character,
            conversationID: 9_991,
            diary: "We talked about the rain.",
            opener: "Did the rain ever stop?",
            notificationLine: "I've been thinking about our talk…"
        )
        #expect(id > 0)

        let entries = MemoryStore.shared.journalEntries(character: character)
        #expect(entries.count == 1)
        let entry = entries[0]
        #expect(entry.id == id)
        #expect(entry.conversationID == 9_991)
        #expect(entry.diary == "We talked about the rain.")
        #expect(entry.opener == "Did the rain ever stop?")
        #expect(entry.notificationLine == "I've been thinking about our talk…")
        #expect(!entry.notified)
        #expect(!entry.openerUsed)
        #expect(abs(entry.createdAt.timeIntervalSinceNow) < 120)
    }

    @Test("latestUnusedOpener returns newest unused and honors markOpenerUsed")
    func openerConsumption() {
        let character = "test_journal_opener"
        cleanup(character)
        defer { cleanup(character) }

        let first = MemoryStore.shared.insertJournalEntry(
            character: character, conversationID: 1,
            diary: "d1", opener: "opener one", notificationLine: "")
        let second = MemoryStore.shared.insertJournalEntry(
            character: character, conversationID: 2,
            diary: "d2", opener: "opener two", notificationLine: "")
        #expect(first > 0 && second > 0)

        // Newest wins.
        #expect(MemoryStore.shared.latestUnusedOpener(character: character)?.id == second)

        // Consuming the newest falls back to the older one.
        MemoryStore.shared.markOpenerUsed(id: second)
        #expect(MemoryStore.shared.latestUnusedOpener(character: character)?.id == first)

        // Consuming both leaves none.
        MemoryStore.shared.markOpenerUsed(id: first)
        #expect(MemoryStore.shared.latestUnusedOpener(character: character) == nil)
    }

    @Test("Empty opener is never offered as a greeting")
    func emptyOpenerSkipped() {
        let character = "test_journal_empty_opener"
        cleanup(character)
        defer { cleanup(character) }

        _ = MemoryStore.shared.insertJournalEntry(
            character: character, conversationID: 3,
            diary: "diary only", opener: "", notificationLine: "")
        #expect(MemoryStore.shared.latestUnusedOpener(character: character) == nil)
        #expect(MemoryStore.shared.latestJournalEntry(character: character) != nil)
    }

    @Test("hasJournalEntry dedupes by conversation")
    func reflectionDedupe() {
        let character = "test_journal_dedupe"
        cleanup(character)
        defer { cleanup(character) }

        #expect(!MemoryStore.shared.hasJournalEntry(conversationID: 424_242))
        _ = MemoryStore.shared.insertJournalEntry(
            character: character, conversationID: 424_242,
            diary: "d", opener: "o", notificationLine: "n")
        #expect(MemoryStore.shared.hasJournalEntry(conversationID: 424_242))
    }

    // MARK: - Traits

    @Test("Trait upsert updates weight instead of duplicating")
    func traitUpsert() {
        let character = "test_traits_upsert"
        cleanup(character)
        defer { cleanup(character) }

        MemoryStore.shared.upsertTrait(character: character, trait: "Teases about coffee", weight: 1.0)
        // Same trait, different case → update, not insert.
        MemoryStore.shared.upsertTrait(character: character, trait: "teases about coffee", weight: 2.5)

        let traits = MemoryStore.shared.traits(character: character)
        #expect(traits.count == 1)
        #expect(traits[0].weight == 2.5)
    }

    @Test("Traits are returned heaviest first and delete cleanly")
    func traitOrderingAndDelete() {
        let character = "test_traits_order"
        cleanup(character)
        defer { cleanup(character) }

        MemoryStore.shared.upsertTrait(character: character, trait: "light", weight: 0.5)
        MemoryStore.shared.upsertTrait(character: character, trait: "heavy", weight: 3.0)
        MemoryStore.shared.upsertTrait(character: character, trait: "middle", weight: 1.5)

        let traits = MemoryStore.shared.traits(character: character)
        #expect(traits.map(\.trait) == ["heavy", "middle", "light"])

        MemoryStore.shared.deleteTrait(id: traits[0].id)
        #expect(MemoryStore.shared.traits(character: character).count == 2)
    }

    // MARK: - InteractionClock

    @Test("InteractionClock tracks speech and persists last-seen")
    func interactionClock() {
        let clock = InteractionClock.shared

        clock.noteUserSpoke()
        let silence = clock.secondsSinceUserSpoke
        #expect(silence != nil)
        #expect(silence! >= 0 && silence! < 60)

        clock.markLastSeen()
        let hours = clock.hoursSinceLastSeen
        #expect(hours != nil)
        #expect(hours! >= 0 && hours! < 1)
    }
}
