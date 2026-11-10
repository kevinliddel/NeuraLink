//
//  CharacterStoryTests.swift
//  NeuraLinkTests
//
//  The character's own life (docs/Companion/LIVING_COMPANION.md): the
//  recall behind `recall_own_story` answers the topic, keeps gated stories
//  behind the stage and hands over one at a time; the arc moves a beat a
//  week; a generated sheet parses, is stored and edited; what the
//  character said about itself is kept. Shares the app-host MemoryStore;
//  every test namespaces its character and cleans up.
//
//  Created by Dedicatus on 10/11/2026.
//

import Foundation
import Testing

@testable import NeuraLink

@MainActor
@Suite("Character story")
struct CharacterStoryTests {

    private let sonya = CharacterLoreCatalogue.sheet(for: "sonya")

    private func candidates(stage: String, said: [String] = []) -> [SelfKnowledge] {
        StoryRecall.candidates(sheet: sonya, stage: stage, said: said, arcBeat: sonya.arc[0])
    }

    // MARK: - Recall

    @Test("Gated stories stay behind the stage; the open material is always there")
    func gating() {
        let new = candidates(stage: "New")
        #expect(!new.contains { $0.kind == .story })
        #expect(new.contains { $0.kind == .everyday } && new.contains { $0.kind == .taste } && new.contains { $0.kind == .person })
        #expect(candidates(stage: "Friends").filter { $0.kind == .story }.count == 3)
        #expect(candidates(stage: "Close").filter { $0.kind == .story }.count == 9)
    }

    @Test("The topic picks what comes back: music finds the taste, the cat finds the Minister")
    func topical() {
        let music = StoryRecall.recall(topic: "what music do you like, jazz?", candidates: candidates(stage: "New"), told: [])
        #expect(music.first?.kind == .taste && music.first?.text.contains("Jazz") == true)
        let cat = StoryRecall.recall(topic: "do you have a cat", candidates: candidates(stage: "New"), told: [])
        #expect(cat.first?.text.contains("Minister") == true)
        #expect(music.count <= StoryRecall.limit)
    }

    @Test("One story per call, an untold one first; a vague topic gets the arc, two everyday facts and a story")
    func oneStory() {
        let friends = candidates(stage: "Friends")
        let chess = StoryRecall.recall(topic: "chess cards books bookshelf cats", candidates: friends, told: [])
        #expect(chess.filter { $0.kind == .story }.count == 1)

        // Two stories match "chess"/"cats" equally; the told one steps back.
        let told: Set<String> = ["sonya.friends.2"]
        let pick = StoryRecall.recall(topic: "chess cats", candidates: friends, told: told).first { $0.kind == .story }
        #expect(pick?.fragmentID == "sonya.friends.3")

        let vague = StoryRecall.recall(topic: "yourself", candidates: friends, told: [])
        #expect(vague.map(\.kind) == [.arc, .everyday, .everyday, .story])
        #expect(StoryRecall.recall(topic: "", candidates: candidates(stage: "New"), told: []).map(\.kind) == [.arc, .everyday, .everyday])
    }

    @Test("Meaning counts when embeddings are there, and what it said before comes back marked")
    func similarityAndSaid() {
        let said = ["I once got locked in the bookshop overnight and read by torchlight."]
        let items = StoryRecall.recall(
            topic: "frightening night", candidates: candidates(stage: "New", said: said), told: [],
            similarity: { _, text in text.contains("torchlight") ? 0.9 : 0 })
        #expect(items.first?.kind == .said)
        let text = StoryRecall.resultText(items, told: [])
        #expect(text.contains("you told them this before; stay consistent"))
        #expect(StoryRecall.resultText([], told: []).contains("Say little rather than invent"))
        let story = SelfKnowledge(kind: .story, text: "A story.", fragmentID: "x.friends.1")
        #expect(StoryRecall.resultText([story], told: []).contains("have not told them yet"))
        #expect(StoryRecall.resultText([story], told: ["x.friends.1"]).contains("have told them before"))
    }

    // MARK: - Arc

    @Test("The arc starts at the first hello, moves a beat a week and holds its last")
    func arc() {
        let met = Date(timeIntervalSince1970: 1_800_000_000)
        let arc = ["one", "two", "three"]
        #expect(StoryRecall.arcBeat(arc, firstMetAt: nil, now: met) == "one")
        #expect(StoryRecall.arcBeat(arc, firstMetAt: met, now: met.addingTimeInterval(6 * 86_400)) == "one")
        #expect(StoryRecall.arcBeat(arc, firstMetAt: met, now: met.addingTimeInterval(8 * 86_400)) == "two")
        #expect(StoryRecall.arcBeat(arc, firstMetAt: met, now: met.addingTimeInterval(400 * 86_400)) == "three")
        #expect(StoryRecall.arcBeat([], firstMetAt: met, now: met) == nil)
    }

    // MARK: - A generated sheet

    @Test("Labelled lines parse into a sheet; junk, short lines and extras are dropped")
    func parse() {
        let raw = """
        EVERYDAY: I live above a noodle shop and the steam fogs my window every morning.
        Everyday: "I never learned to ride a bicycle and I refuse to discuss it."
        TASTE: Pineapple belongs on pizza and I will defend it to anyone.
        PERSON: My neighbour Jun borrows my umbrella and returns a different one each time.
        FRIENDS: I once followed the wrong tour group for an hour and learned a lot about bridges.
        GOOD FRIENDS: I worry that I talk too much because silence makes me feel invisible.
        CLOSE: I still keep the last message my father sent me, and I have never answered it.
        ARC: I've started learning the harmonica from a book with half its pages missing.
        ARC: too short
        NOTES: this label does not exist and should be ignored entirely.
        """
        let sheet = StoryRecall.parseSheet(raw, character: "Mika")
        #expect(sheet.everyday.count == 2 && sheet.everyday[1].hasPrefix("I never learned"))
        #expect(sheet.tastes.count == 1 && sheet.people.count == 1 && sheet.arc.count == 1)
        #expect(sheet.fragments.map(\.id) == ["mika.friends.1", "mika.goodFriends.1", "mika.close.1"])
        #expect(StoryRecall.parseSheet("nothing useful here", character: "mika").isEmpty)
        let extra = (1...6).map { "EVERYDAY: line number \($0) is long enough to keep." }.joined(separator: "\n")
        #expect(StoryRecall.parseSheet(extra, character: "mika").everyday.count == 4)
        for (label, _) in StoryRecall.sheetLabels { #expect(StoryRecall.sheetInstruction(name: "Mika").contains("\(label):")) }
    }

    @Test("An imported character's sheet is stored, read back in order, replaced and deleted")
    func storedSheet() {
        let character = "story-test-imported"
        let provider = CharacterStoryProvider.shared
        defer { provider.delete(character: character) }
        #expect(provider.sheet(for: character).isEmpty && provider.isEditable(character))
        #expect(!provider.isEditable("sonya"))

        var sheet = CharacterStorySheet(
            everyday: ["I live above a noodle shop.", "I never learned to ride a bicycle."], tastes: ["Pineapple belongs on pizza."],
            people: ["My neighbour Jun."],
            fragments: [
                LoreFragment(id: "\(character).friends.1", tier: .friends, text: "The wrong tour group."),
                LoreFragment(id: "\(character).close.1", tier: .close, text: "My father's last message.")
            ],
            arc: ["I've started the harmonica.", "I can play one song."])
        provider.save(sheet, for: character)
        #expect(provider.sheet(for: character) == sheet)
        #expect(provider.fragments(for: character).map(\.id) == ["\(character).friends.1", "\(character).close.1"])

        sheet.everyday = ["I moved across town."]
        provider.save(sheet, for: character)
        #expect(provider.sheet(for: character).everyday == ["I moved across town."])
        provider.delete(character: character)
        #expect(provider.sheet(for: character).isEmpty)
    }

    // MARK: - What it said about itself

    @Test("Self facts are kept once each, newest first, capped, and wiped by reset")
    func selfFacts() {
        let character = "story-test-said"
        let store = MemoryStore.shared
        defer { store.deleteSelfFacts(character: character) }
        store.addSelfFact(character: character, text: "I broke my wrist skating at nine.")
        store.addSelfFact(character: character, text: "I broke my wrist skating at nine.")
        store.addSelfFact(character: character, text: "My first job was in a bakery.")
        #expect(store.selfFacts(character: character) == ["My first job was in a bakery.", "I broke my wrist skating at nine."])
        for index in 0..<(MemoryStore.selfFactCap + 5) { store.addSelfFact(character: character, text: "Fact number \(index).") }
        let kept = store.selfFacts(character: character)
        #expect(kept.count == MemoryStore.selfFactCap && kept.first == "Fact number \(MemoryStore.selfFactCap + 4).")
        store.deleteSelfFacts(character: character)
        #expect(store.selfFacts(character: character).isEmpty)
    }

    @Test("The provider's recall hands over one unlocked story and stamps it shared, unless told not to")
    func providerRecall() {
        // A fresh character is "New": nothing gated comes back and nothing is stamped.
        let character = "story-test-recall"
        let store = MemoryStore.shared
        defer {
            store.deleteLoreReveals(character: character)
            store.deleteSelfFacts(character: character)
        }
        store.addSelfFact(character: character, text: "I keep a jar of sea glass on my desk.")
        let text = CharacterStoryProvider.shared.recall(topic: "sea glass jar", character: character)
        #expect(text.contains("sea glass") && text.contains("stay consistent"))
        #expect(store.loreReveals(character: character).isEmpty)
        #expect(CharacterStoryProvider.shared.promptBlock(character: character).contains("recall_own_story"))
    }

    // MARK: - Reflection

    @Test("The OpenAI reflection asks for SELF and ties AWAY to the arc; the local prompt stays as it was")
    func reflection() {
        let local = ReflectionManager.systemInstruction(character: "sonya", userName: "Kevin")
        #expect(!local.contains("SELF:") && !local.contains("going on in your life"))
        let cloud = ReflectionManager.systemInstruction(
            character: "sonya", userName: "Kevin", extended: true, arcBeat: "The shelf is two shelves.")
        #expect(cloud.contains("SELF:") && cloud.contains("The shelf is two shelves."))
        let parsed = ReflectionManager.parse("""
        DIARY: We talked about books.
        MOOD: playful
        SELF: I told them I broke my wrist skating when I was nine.
        TRAIT: They like being teased.
        """)
        #expect(parsed?.selfFact == "I told them I broke my wrist skating when I was nine.")
        #expect(ReflectionManager.parse("DIARY: We talked.")?.selfFact == "")
    }

    @Test("With the story tool a visit volunteers a story only now and then")
    func volunteering() {
        let character = "story-test-volunteer"
        let store = MemoryStore.shared
        defer { store.deleteLoreReveals(character: character) }
        let fragment = LoreFragment(id: "test.friends.1", tier: .friends, text: "A story of my own, long enough to count.")
        let quiet = CompanionInnerLife(store: store, fragments: { _ in [fragment] })
        let none = quiet.lines(character: character, stage: "Friends", absent: false, compact: false, storiesByTool: true, volunteerRoll: 0.9)
        #expect(!none.contains { $0.contains("A story of my own") })
        let chatty = CompanionInnerLife(store: store, fragments: { _ in [fragment] })
        let some = chatty.lines(character: character, stage: "Friends", absent: false, compact: false, storiesByTool: true, volunteerRoll: 0.1)
        #expect(some.contains { $0.contains("A story of my own") })
    }
}
