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
        guard let queryVector = embedder.generateVector(for: query) else { return "" }
        
        let allMemories = store.fetchAll()
        
        // Calculate similarities and sort
        let scored: [(MemoryItem, Double)] = allMemories.map { memory in
            let score = EmbeddingService.cosineSimilarity(queryVector, memory.vector)
            return (memory, score)
        }
        
        let filtered = scored
            .filter { $0.0.vector.count == queryVector.count }
            .filter { $0.1 > 0.5 }  // Threshold to avoid irrelevant garbage
        
        let now = Date()
        let rankedMemories = filtered
            .map { pair -> (MemoryItem, Double) in
                let ageDays = max(0, now.timeIntervalSince(pair.0.timestamp) / 86_400.0)
                // 14-day half-life keeps recent context relevant but not dominant.
                let recency = exp(-ageDays / 14.0)
                let pinBoost = pair.0.pinned ? 1.15 : 1.0
                let final = pair.1 * (0.75 + 0.25 * recency) * pinBoost
                return (pair.0, final)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
        
        if rankedMemories.isEmpty { return "" }
        
        var context = "\n[Long-term Memory Context]\n"
        for (memory, _) in rankedMemories {
            context += "- \(memory.text)\n"
        }
        context += "[End of Context]\n"
        
        return context
    }
}
