//
//  CharacterBondTests.swift
//  NeuraLinkTests
//
//  One bond per character (docs/LIVING_COMPANION.md): turns, facts and the
//  carry-over line count only what the user shared with that character, and
//  history written before messages carried a character is attributed from
//  the diary. Shares the app-host MemoryStore under throwaway characters.
//
//  Created by Dedicatus on 21/10/2026.
//

import Foundation
import Testing

@testable import NeuraLink

@MainActor
@Suite("Character bond", .serialized)
struct CharacterBondTests {

    private let store = MemoryStore.shared
    private let tag = UUID().uuidString.prefix(8)
    private var oz: String { "bond-oz-\(tag)" }
    private var miku: String { "bond-miku-\(tag)" }

    private func say(_ count: Int, to character: String, in conversation: Int64) {
        for turn in 0..<count {
            store.insertMessage(
                conversationID: conversation, role: "user", kind: "message", content: "u\(turn)", character: character)
            store.insertMessage(
                conversationID: conversation, role: "assistant", kind: "message", content: "a\(turn)",
                character: character)
        }
    }

    @Test("Weeks with one character leave a newly met one at New")
    func meterIsPerCharacter() {
        let id = store.insertConversation(title: "bond-test")
        defer { store.deleteConversation(id: id) }
        say(5, to: oz, in: id)

        let withOz = CompanionAffinity.compute(store: store, character: oz)
        let withMiku = CompanionAffinity.compute(store: store, character: miku)
        #expect(withOz.userTurns == 5)
        #expect(withOz.score > 0 && withOz.label != "New")
        #expect(withMiku.userTurns == 0 && withMiku.score == 0 && withMiku.label == "New")
        #expect(store.distinctUserMessageDays(character: oz) == 1)
        #expect(store.distinctUserMessageDays(character: miku) == 0)
        #expect(store.lastUserMessageAt(character: oz) != nil)
        #expect(store.lastUserMessageAt(character: miku) == nil)
    }

    @Test("A fact counts toward the bond of the character it was told to")
    func factsArePerCharacter() {
        let subject = "BondTest\(tag)"
        store.insertFact(subject: subject, predicate: "likes", object: "earl grey", character: oz)
        defer {
            for fact in store.fetchAllFacts() where fact.subject == subject { store.deleteFact(id: fact.id) }
        }
        #expect(store.factCount(character: oz) == 1)
        #expect(store.factCount(character: miku) == 0)
    }

    @Test("The carry-over line never quotes another character's last words")
    func carryOverIsPerCharacter() {
        let withOz = store.insertConversation(title: "bond-oz")
        let withMiku = store.insertConversation(title: "bond-miku")
        defer {
            store.deleteConversation(id: withOz)
            store.deleteConversation(id: withMiku)
        }
        store.insertMessage(
            conversationID: withOz, role: "assistant", kind: "message", content: "Your tea, sir.", character: oz)
        store.insertMessage(
            conversationID: withMiku, role: "assistant", kind: "message", content: "Let's sing!", character: miku)

        #expect(store.lastExchange(character: oz, excludingConversation: nil)?.content == "Your tea, sir.")
        #expect(store.lastExchange(character: miku, excludingConversation: nil)?.content == "Let's sing!")
        // The active conversation is "now", not "last time".
        #expect(store.lastExchange(character: oz, excludingConversation: withOz) == nil)
    }

    @Test("History from before the character column is attributed from the diary")
    func legacyAttribution() {
        let reflected = store.insertConversation(title: "bond-legacy")
        defer {
            store.deleteConversation(id: reflected)
            store.deleteJournal(character: oz)
        }
        // Two user turns the diary covered, then one more after it.
        say(2, to: "", in: reflected)
        let covered = store.fetchMessages(conversationID: reflected).map(\.id).max() ?? 0
        _ = store.insertJournalEntry(
            character: oz, conversationID: reflected, diary: "d", opener: "", notificationLine: "",
            lastMessageID: covered)
        say(1, to: "", in: reflected)

        let attributed = store.attributeLegacyRows(fallback: miku)
        #expect(attributed.messages >= 6)
        #expect(store.userTurnCount(character: oz) == 3, "covered turns and the rest of the reflected conversation")
        #expect(store.journalEntryCount(character: oz) == 1)
    }
}
