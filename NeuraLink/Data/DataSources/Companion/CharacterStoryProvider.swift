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

    /// Stores an imported character's sheet (generated or edited), all or
    /// nothing. Each story keeps its id, so its "shared on" date stays with
    /// it when another story is edited or removed. False when storage refused.
    @discardableResult
    func save(_ sheet: CharacterStorySheet, for character: String) -> Bool {
        var rows: [MemoryStore.StoryRow] = []
        rows += sheet.everyday.map { MemoryStore.StoryRow(kind: "everyday", text: $0) }
        rows += sheet.tastes.map { MemoryStore.StoryRow(kind: "taste", text: $0) }
        rows += sheet.people.map { MemoryStore.StoryRow(kind: "person", text: $0) }
        rows += sheet.arc.map { MemoryStore.StoryRow(kind: "arc", text: $0) }
        for tier in LoreTier.allCases {
            rows += sheet.fragments.filter { $0.tier == tier }
                .map { MemoryStore.StoryRow(kind: tier.rawValue, text: $0.text, fragmentID: $0.id) }
        }
        return store.replaceStory(
            character: character, rows: rows.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    /// Everything a deleted character leaves behind here: its sheet, what
    /// it said about itself and which stories it had shared, so a slug used
    /// again starts clean.
    func delete(character: String) {
        store.deleteStory(character: character)
        store.deleteSelfFacts(character: character)
        store.deleteLoreReveals(character: character)
    }

    /// A new id for a story of `character` in `tier`, never reused.
    static func newFragmentID(character: String, tier: LoreTier) -> String {
        "\(character.lowercased()).\(tier.rawValue).\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// `sheet` with every story given a new id: a freshly written sheet
    /// must not inherit the reveal dates of the stories it replaces.
    static func withFreshIDs(_ sheet: CharacterStorySheet, character: String) -> CharacterStorySheet {
        var fresh = sheet
        fresh.fragments = sheet.fragments.map {
            LoreFragment(id: newFragmentID(character: character, tier: $0.tier), tier: $0.tier, text: $0.text)
        }
        return fresh
    }

    private func storedSheet(for character: String) -> CharacterStorySheet {
        let rows = store.storyRows(character: character)
        guard !rows.isEmpty else { return CharacterStorySheet() }
        func texts(_ kind: String) -> [String] { rows.filter { $0.kind == kind }.map(\.text) }
        let key = character.lowercased()
        let fragments = LoreTier.allCases.flatMap { tier in
            rows.filter { $0.kind == tier.rawValue }.enumerated().map { index, row in
                // Rows from before stories had ids keep their positional one.
                LoreFragment(
                    id: row.fragmentID.isEmpty ? "\(key).\(tier.rawValue).\(index + 1)" : row.fragmentID,
                    tier: tier, text: row.text)
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

    /// The [About yourself] block of the OpenAI session instructions. With
    /// Inner life off it keeps the rule and the honest answer only.
    func promptBlock(character: String) -> String {
        guard PresenceSettings.shared.innerLifeEnabled else {
            return SelfTalkRules.promptBlock(voice: nil, arcBeat: nil, examples: [], innerLife: false)
        }
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
        let items = StoryRecall.recall(topic: topic, candidates: candidates, told: told, similarity: similarity(to: topic))
        for item in items where stamp && item.kind == .story {
            if let id = item.fragmentID { store.recordLoreReveal(character: character, fragmentID: id) }
        }
        return StoryRecall.resultText(items, told: told)
    }

    /// How close a line is to `topic` by sentence embeddings, or nil when
    /// the device has none (a fresh simulator returns zero vectors). The
    /// topic is embedded once per recall, and a line's vector is kept: the
    /// sheet's lines are the same on every call.
    private func similarity(to topic: String) -> ((String) -> Double)? {
        guard !topic.isEmpty, let query = EmbeddingService.shared.generateVector(for: topic, purpose: .query),
              query.contains(where: { $0 != 0 })
        else { return nil }
        return { [weak self] text in
            guard let self, let document = self.vector(for: text) else { return 0 }
            return EmbeddingService.cosineSimilarity(query, document)
        }
    }

    private var lineVectors: [String: [Double]] = [:]

    private func vector(for text: String) -> [Double]? {
        if let known = lineVectors[text] { return known }
        guard let vector = EmbeddingService.shared.generateVector(for: text, purpose: .document),
              vector.contains(where: { $0 != 0 })
        else { return nil }
        if lineVectors.count > 200 { lineVectors.removeAll() }
        lineVectors[text] = vector
        return vector
    }
}
