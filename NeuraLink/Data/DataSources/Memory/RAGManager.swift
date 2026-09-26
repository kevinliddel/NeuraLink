//
//  RAGManager.swift
//  NeuraLink
//
//  Facade over the agentic memory layer (docs/AGENTIC_MEMORY.md). Keeps the
//  historical call sites — `store`, `fetchContext`, `storeFact`,
//  `fetchFacts` — while routing them through MemoryRetain (ingest) and
//  MemoryRecall (hybrid retrieval) instead of the old single-signal
//  cosine × recency ranking.
//
//  Created by Dedicatus on 09/05/2026.
//

import Foundation

final class RAGManager {
    static let shared = RAGManager()

    private let store = MemoryStore.shared
    private let settings = MemorySettings.shared
    private let retain = MemoryRetain.shared
    private let recall = MemoryRecall.shared

    private init() {}

    /// Records a dialogue turn verbatim in long-term memory (no LLM).
    /// Runs off the calling thread; also applies auto-forget pruning.
    func store(text: String, source: String) {
        guard settings.isEnabled else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        Task.detached(priority: .background) {
            let id = self.retain.retainRaw(text: text, source: source)
            if id > 0 {
                nlLog("[RAGManager] Stored raw memory (source=\(source), \(text.count) chars)", level: .info)
                nlLogSensitive("[RAGManager] Memory body: \(text)", level: .info)
            }
            let days = self.settings.autoForgetDays
            if days > 0 {
                let cutoff = Date().addingTimeInterval(-Double(days) * 86_400.0)
                self.store.pruneMemories(olderThan: cutoff)
                self.store.pruneConversations(olderThan: cutoff)
            }
        }
    }

    /// Top memories relevant to `query` (knowledge first, dialogue as
    /// fallback) formatted as a `[Long-term Memory Context]` block.
    func fetchContext(for query: String, limit: Int = 3, tokenBudget: Int = 400) async -> String {
        var hits = recall.recall(MemoryRecallQuery(
            text: query, factTypes: MemoryFactType.knowledge, maxResults: limit, tokenBudget: tokenBudget))
        if hits.count < limit {
            let seen = Set(hits.map(\.id))
            let raw = recall.recall(MemoryRecallQuery(
                text: query, factTypes: [.raw], maxResults: limit - hits.count, tokenBudget: tokenBudget / 2,
                preferObservations: false))
            hits.append(contentsOf: raw.filter { !seen.contains($0.id) })
        }
        guard !hits.isEmpty else { return "" }
        return "\n[Long-term Memory Context]\n" + MemoryRecall.bulletLines(hits).joined(separator: "\n")
            + "\n[End of Context]\n"
    }

    // MARK: - Facts

    /// Persists `text` as a timeless world fact about the user.
    func storeFact(_ text: String) {
        retain.retainFact(ExtractedFact(text: text), source: "fact")
    }

    /// Top-`limit` knowledge units (observations preferred, then facts)
    /// relevant to `query`, as bullet-ready lines.
    func fetchFacts(relevantTo query: String, limit: Int = 3, tokenBudget: Int = 300) -> [String] {
        let hits = recall.recall(MemoryRecallQuery(
            text: query, factTypes: MemoryFactType.knowledge, maxResults: limit, tokenBudget: tokenBudget))
        return MemoryRecall.bulletLines(hits).map { String($0.dropFirst(2)) }
    }
}
