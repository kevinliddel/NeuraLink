//
//  CharacterStoryProvider.swift
//  NeuraLink
//
//  Where a character's own life is read from — Inner life
//  (docs/Companion/LIVING_COMPANION.md). Bundled characters have an
//  authored sheet (CharacterLoreCatalogue); an imported one has the sheet
//  generated from its persona prompt and edited by the user
//  (`character_story`). On top of the sheet come the things the character
//  has said about itself (`companion_self_facts`) and the arc's current
//  beat. Answers the `recall_own_story` tool, stamps a story shared when
//  the tool hands it over, and builds the session's [About yourself] block.
//
//  Created by Dedicatus on 10/11/2026.
//

import Foundation

final class CharacterStoryProvider {
    static let shared = CharacterStoryProvider()

    private let store: MemoryStore

    init(store: MemoryStore = .shared) {
        self.store = store
    }

    // MARK: - The sheet

    /// The character's sheet: authored for a bundled character, stored for
    /// an imported one, empty when nothing has been written yet.
    func sheet(for character: String) -> CharacterStorySheet {
        let authored = CharacterLoreCatalogue.sheet(for: character)
        return authored.isEmpty ? storedSheet(for: character) : authored
    }

    func fragments(for character: String) -> [LoreFragment] {
        sheet(for: character).fragments
    }

    /// Whether the sheet can be edited: only a stored one can.
    func isEditable(_ character: String) -> Bool {
        CharacterLoreCatalogue.sheet(for: character).isEmpty
    }

    /// Stores an imported character's sheet (generated or edited).
    func save(_ sheet: CharacterStorySheet, for character: String) {
        var rows: [(kind: String, text: String)] = []
        rows += sheet.everyday.map { ("everyday", $0) }
        rows += sheet.tastes.map { ("taste", $0) }
        rows += sheet.people.map { ("person", $0) }
        rows += sheet.arc.map { ("arc", $0) }
        for tier in LoreTier.allCases {
            rows += sheet.fragments.filter { $0.tier == tier }.map { (tier.rawValue, $0.text) }
        }
        store.replaceStory(character: character, rows: rows.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    func delete(character: String) {
        store.deleteStory(character: character)
        store.deleteSelfFacts(character: character)
    }

    private func storedSheet(for character: String) -> CharacterStorySheet {
        let rows = store.storyRows(character: character)
        guard !rows.isEmpty else { return CharacterStorySheet() }
        func texts(_ kind: String) -> [String] { rows.filter { $0.kind == kind }.map(\.text) }
        let key = character.lowercased()
        let fragments = LoreTier.allCases.flatMap { tier in
            texts(tier.rawValue).enumerated().map { index, text in
                LoreFragment(id: "\(key).\(tier.rawValue).\(index + 1)", tier: tier, text: text)
            }
        }
        return CharacterStorySheet(
            everyday: texts("everyday"), tastes: texts("taste"), people: texts("person"), fragments: fragments,
            arc: texts("arc"))
    }

    // MARK: - Now

    /// The relationship stage with this character.
    func stage(character: String) -> String {
        CompanionAffinity.compute(store: store, character: character).label
    }

    /// The storyline's beat this week, counted from the first hello.
    func arcBeat(character: String, now: Date = Date()) -> String? {
        let firstMet = store.milestones(character: character).first { $0.kind == .firstConversation }?.achievedAt
        return StoryRecall.arcBeat(sheet(for: character).arc, firstMetAt: firstMet, now: now)
    }

    /// The [About yourself] block of the OpenAI session instructions.
    func promptBlock(character: String) -> String {
        let sheet = sheet(for: character)
        return SelfTalkRules.promptBlock(
            voice: sheet.voice[stage(character: character)], arcBeat: arcBeat(character: character),
            examples: sheet.examples)
    }

    // MARK: - Recall

    /// What the `recall_own_story` tool returns for `topic`. A story the
    /// stage has unlocked is stamped shared when it is handed over, so the
    /// journal's "Their stories" follows what the persona was given
    /// (`stamp` is off for the developer probe).
    func recall(topic: String, character: String, stamp: Bool = true) -> String {
        let told = Set(store.loreReveals(character: character).map(\.fragmentID))
        let candidates = StoryRecall.candidates(
            sheet: sheet(for: character), stage: stage(character: character),
            said: store.selfFacts(character: character), arcBeat: arcBeat(character: character))
        let items = StoryRecall.recall(topic: topic, candidates: candidates, told: told, similarity: Self.similarity)
        for item in items where stamp && item.kind == .story {
            if let id = item.fragmentID { store.recordLoreReveal(character: character, fragmentID: id) }
        }
        return StoryRecall.resultText(items, told: told)
    }

    /// Sentence-embedding similarity, 0 when the device has no embedding
    /// asset (a fresh simulator returns zero vectors).
    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        guard let query = EmbeddingService.shared.generateVector(for: lhs, purpose: .query),
              let document = EmbeddingService.shared.generateVector(for: rhs, purpose: .document),
              query.contains(where: { $0 != 0 }), document.contains(where: { $0 != 0 })
        else { return 0 }
        return EmbeddingService.cosineSimilarity(query, document)
    }
}
