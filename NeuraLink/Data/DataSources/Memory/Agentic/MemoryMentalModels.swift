//
//  MemoryMentalModels.swift
//  NeuraLink
//
//  Mental models (docs/AGENTIC_MEMORY.md §Mental models): standing answers
//  to fixed questions — a global user profile and a per-character
//  relationship note. Prompt builders read them straight from SQLite (no
//  retrieval, no LLM). They are refreshed in delta mode after
//  consolidation: only when stale AND new memories arrived since the last
//  refresh, using recall for evidence and one LLM call.
//
//  Created by Dedicatus on 25/09/2026.
//

import Foundation

final class MemoryMentalModels: @unchecked Sendable {

    static let shared = MemoryMentalModels()

    static let userProfileSlug = "user_profile"
    static let relationshipSlug = "relationship"
    static let maxTokens = 160
    static let evidenceBudget = 900

    private let store: MemoryStore
    private let llm: MemoryLLM
    private let recall: MemoryRecall

    init(store: MemoryStore = .shared, llm: MemoryLLM = LiveMemoryLLM(), recall: MemoryRecall = .shared) {
        self.store = store
        self.llm = llm
        self.recall = recall
    }

    // MARK: - Definitions

    static func userProfileQuestion() -> String {
        "Who is the user? Summarise what is known: name, life situation, important people, preferences and current plans."
    }

    static func relationshipQuestion(character: String) -> String {
        "What is the state of the relationship between \(character.capitalized) and the user, and what should \(character.capitalized) keep in mind next time they talk?"
    }

    /// Creates the standing rows for `character` if missing.
    func ensureDefaults(character: String) {
        store.ensureMentalModel(character: "", slug: Self.userProfileSlug, question: Self.userProfileQuestion())
        guard !character.isEmpty else { return }
        store.ensureMentalModel(
            character: character, slug: Self.relationshipSlug, question: Self.relationshipQuestion(character: character))
    }

    // MARK: - Read (zero-LLM)

    /// Prompt block with every non-empty mental model for `character`.
    /// Stable across turns, so it sits in the KV-cacheable system prefix.
    func promptBlock(character: String, compact: Bool = false) -> String {
        let models = store.fetchMentalModels(character: character).filter { !$0.content.isEmpty }
        guard !models.isEmpty else { return "" }
        var out = "\n[What \(character.isEmpty ? "the assistant" : character.capitalized) knows]\n"
        for model in models {
            let label = model.slug == Self.userProfileSlug ? "About the user" : "Relationship"
            let content = compact ? String(model.content.prefix(240)) : model.content
            out += "- \(label): \(content)\n"
        }
        return out
    }

    // MARK: - Refresh (delta mode)

    func refreshStale(character: String) async {
        guard llm.tier != .none else { return }
        ensureDefaults(character: character)
        let latest = store.latestUnitID()
        for model in store.fetchMentalModels(character: character)
        where model.isStale && latest > model.lastMemoryID {
            await refresh(model, latestMemoryID: latest, character: character)
        }
    }

    /// Recall evidence for the standing question → one LLM answer.
    @discardableResult
    func refresh(_ model: MentalModel, latestMemoryID: Int64, character: String) async -> Bool {
        let hits = evidence(for: model.question)
        guard !hits.isEmpty else {
            store.updateMentalModel(id: model.id, content: "", lastMemoryID: latestMemoryID)
            return false
        }
        let evidence = MemoryRecall.bulletLines(hits).joined(separator: "\n")
        let raw = await llm.complete(
            system: Self.systemPrompt(character: character, disposition: MemoryDisposition.forCharacter(character)),
            user: "QUESTION: \(model.question)\n\nEVIDENCE:\n\(evidence)\n\nANSWER:",
            maxTokens: Self.maxTokens)
        let answer = Self.cleanAnswer(raw ?? "")
        store.updateMentalModel(id: model.id, content: answer, lastMemoryID: latestMemoryID)
        nlLogSensitive("[MentalModel] \(model.slug): \(answer)", level: .info)
        return !answer.isEmpty
    }

    /// Recall for the standing question, topped up with the newest
    /// observations and then facts. A profile question ("who is the user?")
    /// shares few words or embedding mass with concrete facts, so recall
    /// alone would under-feed the summary.
    static let evidenceTarget = 12

    private func evidence(for question: String) -> [MemoryRecallHit] {
        var hits = recall.recall(MemoryRecallQuery(
            text: question, factTypes: MemoryFactType.knowledge, maxResults: Self.evidenceTarget,
            tokenBudget: Self.evidenceBudget, preferObservations: true))
        guard hits.count < Self.evidenceTarget else { return hits }
        var seen = Set(hits.map(\.id))
        var remaining = Self.evidenceBudget - hits.reduce(0) { $0 + $1.unit.estimatedTokens }
        let covered = Set(store.fetchUnits(factTypes: [.observation]).flatMap(\.sourceIDs))
        let newest = store.fetchUnits(factTypes: [.observation]) + store.fetchUnits(factTypes: [.world, .experience])
        for unit in newest where hits.count < Self.evidenceTarget && !seen.contains(unit.id) {
            if unit.factType != .observation, covered.contains(unit.id) { continue }
            guard unit.estimatedTokens <= remaining else { continue }
            seen.insert(unit.id)
            remaining -= unit.estimatedTokens
            hits.append(MemoryRecallHit(unit: unit, score: 0, arms: []))
        }
        return hits
    }

    static func systemPrompt(character: String, disposition: MemoryDisposition) -> String {
        let name = character.isEmpty ? "the user's AI companion" : character.capitalized
        var text = """
        You are \(name), privately updating what you know. Answer the QUESTION in at most 80 words, \
        third person, using ONLY the EVIDENCE. Prefer newer evidence when facts conflict. Never invent details. \
        If the evidence does not answer the question, reply with the single word UNKNOWN.
        """
        let traits = disposition.promptDescription
        if !traits.isEmpty { text += "\nDisposition: \(traits)" }
        return text
    }

    /// Strips label echoes and the UNKNOWN sentinel.
    static func cleanAnswer(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.uppercased().hasPrefix("ANSWER:") { text = String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        if text.uppercased().hasPrefix("UNKNOWN") || text.count < 8 { return "" }
        return String(text.prefix(600))
    }
}
