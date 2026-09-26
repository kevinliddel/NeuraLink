//
//  KnowledgeGraphManager.swift
//  NeuraLink
//
//  Orchestrates structured fact storage and retrieval for personal AI memory.
//

import Foundation

final class KnowledgeGraphManager {
    static let shared = KnowledgeGraphManager()
    
    private let store = MemoryStore.shared
    
    private init() {}
    
    /// Stores a new fact in the structured memory.
    func remember(subject: String, predicate: String, object: String) {
        store.insertFact(subject: subject, predicate: predicate, object: object)
        CompanionStateStore.shared.refresh()
        OpenAIRealtimeManager.postInstructionsChanged(reason: "remember_fact")
        // Mirror into agentic memory so the entity graph and recall see it.
        let sentence = "\(subject) \(predicate.replacingOccurrences(of: "_", with: " ")) \(object)."
        Task.detached(priority: .background) {
            MemoryRetain.shared.retainFact(
                ExtractedFact(text: sentence, entities: [subject, object]), source: "tool")
        }
        nlLog("֎ [KnowledgeGraph] Inserted into knowledge_graph: \(subject) — \(predicate) — \(object)", level: .info)
    }
    
    /// Returns a formatted string of all known facts for injection into the AI prompt.
    func getFormattedFacts() -> String {
        let facts = store.fetchAllFacts()
        if facts.isEmpty { return "" }
        
        var summary = "\n[Long-term Personal Facts]:\n"
        for f in facts {
            summary += "- \(f.subject) \(f.predicate) \(f.object)\n"
        }
        return summary
    }
}
