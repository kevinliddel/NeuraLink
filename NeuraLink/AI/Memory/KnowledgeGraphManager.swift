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
        print("[KnowledgeGraph] Remembered: \(subject) \(predicate) \(object)")
    }
    
    /// Returns a formatted string of all known facts for injection into the AI prompt.
    func getFormattedFacts() -> String {
        let facts = store.fetchAllFacts()
        if facts.isEmpty { return "" }
        
        var summary = "\n[Long-term Personal Facts]:\n"
        for (s, p, o) in facts {
            summary += "- \(s) \(p) \(o)\n"
        }
        return summary
    }
}
