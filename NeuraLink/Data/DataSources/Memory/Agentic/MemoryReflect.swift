//
//  MemoryReflect.swift
//  NeuraLink
//
//  Reflect (docs/AGENTIC_MEMORY.md §Reflect): Hindsight's retrieval ladder
//  — fresh mental models first, then observations, then raw facts — with
//  the descent stopping as soon as enough evidence exists. `evidence(for:)`
//  is the zero-LLM ladder used by the `search_memory` tool so the main
//  model can query memory agentically mid-conversation; `reflect(question:)`
//  adds one synthesis call for callers that need a finished answer.
//
//  Created by Dedicatus on 25/09/2026.
//

import Foundation

final class MemoryReflect: @unchecked Sendable {

    static let shared = MemoryReflect()

    /// Observation hits at which the ladder stops descending to raw facts.
    static let enoughObservations = 3
    static let maxTokens = 200

    private let store: MemoryStore
    private let llm: MemoryLLM
    private let recall: MemoryRecall

    init(store: MemoryStore = .shared, llm: MemoryLLM = LiveMemoryLLM(), recall: MemoryRecall = .shared) {
        self.store = store
        self.llm = llm
        self.recall = recall
    }

    // MARK: - Ladder (no LLM)

    /// Evidence block for `question`, or an empty string when memory holds
    /// nothing relevant. `tokenBudget` bounds the recalled units.
    func evidence(for question: String, character: String, tokenBudget: Int = 500) -> String {
        var lines: [String] = []

        // Rung 1: fresh mental models (a DB read).
        for model in store.fetchMentalModels(character: character)
        where !model.isStale && !model.content.isEmpty {
            let label: String
            switch model.slug {
            case MemoryMentalModels.userProfileSlug: label = "About the user"
            case MemoryMentalModels.weeklyRecapSlug: label = "This week"
            default: label = "Relationship"
            }
            lines.append("- \(label): \(model.content)")
        }

        // Rung 2: observations.
        let observations = recall.recall(MemoryRecallQuery(
            text: question, factTypes: [.observation], maxResults: 5, tokenBudget: tokenBudget / 2))
        lines.append(contentsOf: MemoryRecall.bulletLines(observations))

        // Rung 3: raw facts + dialogue, only when observations were thin.
        if observations.count < Self.enoughObservations {
            let facts = recall.recall(MemoryRecallQuery(
                text: question, factTypes: [.world, .experience, .raw], maxResults: 6,
                tokenBudget: tokenBudget / 2, preferObservations: false))
            let seen = Set(observations.map(\.id))
            lines.append(contentsOf: MemoryRecall.bulletLines(facts.filter { !seen.contains($0.id) }))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Reflect (one LLM call)

    /// Ladder + synthesis. Nil when there is no evidence or no engine.
    func reflect(question: String, character: String) async -> String? {
        let evidence = evidence(for: question, character: character, tokenBudget: 800)
        guard !evidence.isEmpty, llm.tier != .none else { return nil }
        let name = character.isEmpty ? "the user's AI companion" : character.capitalized
        var system = """
        You are \(name). Answer the question about your user using ONLY the evidence below. \
        Cite nothing that is not in the evidence; say what you do not know. Two sentences at most.
        """
        let traits = MemoryDisposition.forCharacter(character).promptDescription
        if !traits.isEmpty { system += "\nDisposition: \(traits)" }
        let raw = await llm.complete(
            system: system, user: "EVIDENCE:\n\(evidence)\n\nQUESTION: \(question)\nANSWER:", maxTokens: Self.maxTokens)
        let answer = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return answer.isEmpty ? nil : answer
    }
}
