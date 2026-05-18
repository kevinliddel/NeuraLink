//
//  RAGManager.swift
//  NeuraLink
//
//  Orchestrates Retrieval-Augmented Generation.
//  Coordinates embedding generation, memory storage, and similarity search.
//
//  Created by Dedicatus on 09/05/2026.
//

import Foundation

final class RAGManager {
    static let shared = RAGManager()
    
    private let store = MemoryStore.shared
    private let embedder = EmbeddingService.shared
    private let settings = MemorySettings.shared
    
    private init() {}
    
    /// Records a new interaction in the long-term memory.
    func store(text: String, source: String) {
        guard settings.isEnabled else { return }
        if source == "ai", settings.storeAIResponses == false { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        // We run this in a background task to avoid blocking the main/audio threads
        Task.detached(priority: .background) {
            if let vector = self.embedder.generateVector(for: text) {
                self.store.insert(text: text, vector: vector, source: source)
                print("[RAGManager] Stored new memory: \"\(text.prefix(30))...\"")
            }
            
            let days = self.settings.autoForgetDays
            if days > 0 {
                let cutoff = Date().addingTimeInterval(-Double(days) * 86_400.0)
                self.store.pruneMemories(olderThan: cutoff)
                self.store.pruneChatEvents(olderThan: cutoff)
            }
        }
    }
    
    /// Fetches the most relevant past memories for a given query.
    /// - Parameters:
    ///   - query: The current user input.
    ///   - limit: Max number of memories to return.
    /// - Returns: A formatted string of memories to be injected into the prompt.
    func fetchContext(for query: String, limit: Int = 3) async -> String {
        let rankedMemories = rankedMemories(for: query, limit: limit, sourceFilter: nil)
        if rankedMemories.isEmpty { return "" }
        var context = "\n[Long-term Memory Context]\n"
        for memory in rankedMemories {
            context += "- \(memory.text)\n"
        }
        context += "[End of Context]\n"
        return context
    }

    // MARK: - Facts (extracted by LocalLLMFactExtractor)

    /// Persists `text` as a compacted-out atomic fact. Stored in the same
    /// `memories` table as other entries but tagged with `source = "fact"`
    /// so it can be retrieved separately by `fetchFacts(relevantTo:limit:)`.
    /// Used by the 3-tier memory hierarchy to preserve user-stated facts
    /// after their original conversation turns age out of the verbatim
    /// window.
    func storeFact(_ text: String) {
        store(text: text, source: "fact")
    }

    /// Returns the top-`limit` facts most semantically relevant to `query`,
    /// ranked by the same cosine-similarity + recency formula used for
    /// general memory retrieval, but filtered to only `source = "fact"`
    /// entries.
    func fetchFacts(relevantTo query: String, limit: Int = 3) -> [String] {
        rankedMemories(for: query, limit: limit, sourceFilter: "fact")
            .map(\.text)
    }

    // MARK: - Shared ranking helper

    /// Scores every stored memory against `query` by cosine similarity,
    /// weighted by a 14-day recency half-life and a 1.15× boost for pinned
    /// entries. Filters out vectors with the wrong dimensionality and
    /// similarity scores below 0.5 (irrelevant garbage). Optionally
    /// restricts the candidate pool to a single `source` tag.
    private func rankedMemories(
        for query: String,
        limit: Int,
        sourceFilter: String?
    ) -> [MemoryItem] {
        guard let queryVector = embedder.generateVector(for: query) else { return [] }
        let candidates = store.fetchAll().filter { memory in
            guard memory.vector.count == queryVector.count else { return false }
            if let source = sourceFilter, memory.source != source { return false }
            return true
        }
        let now = Date()
        let scored: [(MemoryItem, Double)] = candidates.compactMap { memory in
            let sim = EmbeddingService.cosineSimilarity(queryVector, memory.vector)
            guard sim > 0.5 else { return nil }
            let ageDays = max(0, now.timeIntervalSince(memory.timestamp) / 86_400.0)
            let recency = exp(-ageDays / 14.0)
            let pinBoost = memory.pinned ? 1.15 : 1.0
            return (memory, sim * (0.75 + 0.25 * recency) * pinBoost)
        }
        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }
}
