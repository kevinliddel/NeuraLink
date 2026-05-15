//
//  EmbeddingService.swift
//  NeuraLink
//
//  Generates vector embeddings for text chunks using Apple's NaturalLanguage framework.
//  Provides local, fast, and privacy-preserving vectorization.
//
//  Created by Dedicatus on 09/05/2026.
//

import Foundation
import NaturalLanguage

final class EmbeddingService {
    static let shared = EmbeddingService()
    
    private let lock = NSLock()
    private var embeddingCache: [NLLanguage: NLEmbedding] = [:]
    private let fallbackLanguage: NLLanguage = .english
    
    private init() {
        if NLEmbedding.sentenceEmbedding(for: fallbackLanguage) == nil {
            print("[EmbeddingService] Warning: Failed to load sentence embedding for English.")
        }
    }
    
    /// Generates a vector for the given text.
    /// - Parameter text: The input string.
    /// - Returns: A float array representing the vector, or nil if generation fails.
    func generateVector(for text: String) -> [Double]? {
        let language = detectLanguage(for: text) ?? fallbackLanguage
        let embedding = embeddingForLanguage(language) ?? embeddingForLanguage(fallbackLanguage)
        if let vector = embedding?.vector(for: text) { return vector }
        
        // Fallback for environments without the system model (e.g. CI/Simulators)
        // This allows RAG logic to be tested even if the vector quality is zero.
        #if DEBUG
        return Array(repeating: 0.0, count: 512)
        #else
        return nil
        #endif
    }

    private func detectLanguage(for text: String) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage
    }

    private func embeddingForLanguage(_ language: NLLanguage) -> NLEmbedding? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = embeddingCache[language] { return cached }
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else { return nil }
        embeddingCache[language] = embedding
        return embedding
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
