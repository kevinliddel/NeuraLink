//
//  RAGManager.swift
//  NeuraLink
//
//  Orchestrates Retrieval-Augmented Generation.
//  Coordinates embedding generation, memory storage, and similarity search.
//
//  Created by Antigravity on 09/05/2026.
//

import Foundation

final class RAGManager {
    static let shared = RAGManager()
    
    private let store = MemoryStore.shared
    private let embedder = EmbeddingService.shared
    
    private init() {}
    
    /// Records a new interaction in the long-term memory.
    func store(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        
        // We run this in a background task to avoid blocking the main/audio threads
        Task.detached(priority: .background) {
            if let vector = self.embedder.generateVector(for: text) {
                self.store.insert(text: text, vector: vector)
                print("[RAGManager] Stored new memory: \"\(text.prefix(30))...\"")
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
        let rankedMemories = allMemories.map { memory -> (MemoryItem, Double) in
            let score = EmbeddingService.cosineSimilarity(queryVector, memory.vector)
            return (memory, score)
        }
        .filter { $0.1 > 0.5 } // Threshold to avoid irrelevant garbage
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
