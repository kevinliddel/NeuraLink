//
//  MemoryTests.swift
//  NeuraLinkTests
//
//  Unit tests for the RAG memory system.
//

import Testing
import Foundation
@testable import NeuraLink

@Suite("Memory and RAG Tests")
struct MemoryTests {

    @Test("Embedding generation returns 512-dim vector")
    func testEmbeddingGeneration() {
        let text = "Hello world"
        let vector = EmbeddingService.shared.generateVector(for: text)
        
        #expect(vector != nil)
        #expect(vector?.count == 512)
    }

    @Test("Cosine similarity calculations")
    func testCosineSimilarity() {
        let v1 = [1.0, 0.0, 0.0]
        let v2 = [1.0, 0.0, 0.0]
        let v3 = [0.0, 1.0, 0.0]
        
        #expect(EmbeddingService.cosineSimilarity(v1, v2) == 1.0)
        #expect(EmbeddingService.cosineSimilarity(v1, v3) == 0.0)
    }

    @Test("Memory store persistence and retrieval")
    func testMemoryStorePersistence() {
        let store = MemoryStore.shared
        store.clear()
        
        let text = "Test memory"
        let vector = [0.1, 0.2, 0.3]
        
        store.insert(text: text, vector: vector)
        let memories = store.fetchAll()
        
        #expect(memories.count == 1)
        #expect(memories.first?.text == text)
        #expect(memories.first?.vector == vector)
    }
}
