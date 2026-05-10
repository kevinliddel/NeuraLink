//
//  EmbeddingService.swift
//  NeuraLink
//
//  Generates vector embeddings for text chunks using Apple's NaturalLanguage framework.
//  Provides local, fast, and privacy-preserving vectorization.
//
//  Created by Antigravity on 09/05/2026.
//

import Foundation
import NaturalLanguage

final class EmbeddingService {
    static let shared = EmbeddingService()
    
    private let embedding: NLEmbedding?
    
    private init() {
        // We use the sentence embedding for English as it's well-suited for RAG context.
        self.embedding = NLEmbedding.sentenceEmbedding(for: .english)
        if embedding == nil {
            print("[EmbeddingService] Warning: Failed to load sentence embedding for English.")
        }
    }
    
    /// Generates a vector for the given text.
    /// - Parameter text: The input string.
    /// - Returns: A float array representing the vector, or nil if generation fails.
    func generateVector(for text: String) -> [Double]? {
        if let vector = embedding?.vector(for: text) {
            return vector
        }
        
        // Fallback for environments without the system model (e.g. CI/Simulators)
        // This allows RAG logic to be tested even if the vector quality is zero.
        #if DEBUG
        return Array(repeating: 0.0, count: 512)
        #else
        return nil
        #endif
    }
    
    /// Calculates the cosine similarity between two vectors.
    static func cosineSimilarity(_ v1: [Double], _ v2: [Double]) -> Double {
        guard v1.count == v2.count, !v1.isEmpty else { return 0 }
        
        var dotProduct: Double = 0
        var mag1: Double = 0
        var mag2: Double = 0
        
        for i in 0..<v1.count {
            dotProduct += v1[i] * v2[i]
            mag1 += v1[i] * v1[i]
            mag2 += v2[i] * v2[i]
        }
        
        let magnitudes = sqrt(mag1) * sqrt(mag2)
        return magnitudes == 0 ? 0 : dotProduct / magnitudes
    }
}
