//
//  MemoryTests.swift
//  NeuraLinkTests
//
//  Unit tests for the RAG memory system.
//

import XCTest
@testable import NeuraLink

final class MemoryTests: XCTestCase {

    func testEmbeddingGeneration() {
        let text = "Hello world"
        let vector = EmbeddingService.shared.generateVector(for: text)
        XCTAssertNotNil(vector)
        XCTAssertEqual(vector?.count, 512) // NLEmbedding is usually 512
    }

    func testCosineSimilarity() {
        let v1 = [1.0, 0.0, 0.0]
        let v2 = [1.0, 0.0, 0.0]
        let v3 = [0.0, 1.0, 0.0]
        
        XCTAssertEqual(EmbeddingService.cosineSimilarity(v1, v2), 1.0, accuracy: 0.001)
        XCTAssertEqual(EmbeddingService.cosineSimilarity(v1, v3), 0.0, accuracy: 0.001)
    }

    func testMemoryStorePersistence() {
        let store = MemoryStore.shared
        store.clear()
        
        let text = "Test memory"
        let vector = [0.1, 0.2, 0.3]
        
        store.insert(text: text, vector: vector)
        let memories = store.fetchAll()
        
        XCTAssertEqual(memories.count, 1)
        XCTAssertEqual(memories.first?.text, text)
        XCTAssertEqual(memories.first?.vector, vector)
    }
}
