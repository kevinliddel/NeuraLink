//
//  EmbeddingBackend.swift
//  NeuraLink
//
//  Pluggable sentence-embedding backends (docs/CHAT_LLM_IMPROVEMENT_PLAN.md
//  §C2): Apple's NLEmbedding (always available, English-strong) and a GGUF
//  encoder run through llama.cpp (multilingual, downloaded on demand). Each
//  backend has an id that is stored next to every vector so recall only
//  compares like with like, and a cosine calibration.
//
//  Created by Dedicatus on 26/09/2026.
//

import Foundation
import NaturalLanguage

/// What the text is for — e5-style models expect a prefix per role.
enum EmbeddingPurpose: Sendable {
    case query
    case document
}

protocol EmbeddingBackend: AnyObject {
    /// Stable id persisted in `memories.vector_model`.
    var id: String { get }
    var calibration: EmbeddingCalibration { get }
    func embed(_ text: String, purpose: EmbeddingPurpose) -> [Double]?
}

// MARK: - Apple NLEmbedding

final class NLEmbeddingBackend: EmbeddingBackend {

    static let backendID = "nl"

    let id = NLEmbeddingBackend.backendID
    let calibration = EmbeddingCalibration.appleNL

    /// Concurrent queue guarding `embeddingCache`: reads run concurrently,
    /// writes go through `.barrier`. The slow model load happens outside
    /// the queue so a JP load never blocks EN cache hits.
    private let cacheQueue = DispatchQueue(label: "com.neuralink.embedding.cache", attributes: .concurrent)
    private var embeddingCache: [NLLanguage: NLEmbedding] = [:]
    private let fallbackLanguage: NLLanguage = .english

    init() {
        if NLEmbedding.sentenceEmbedding(for: fallbackLanguage) == nil {
            nlLog("[EmbeddingService] Warning: Failed to load sentence embedding for English.", level: .error)
        }
    }

    func embed(_ text: String, purpose: EmbeddingPurpose) -> [Double]? {
        let language = detectLanguage(for: text) ?? fallbackLanguage
        let embedding = embeddingForLanguage(language) ?? embeddingForLanguage(fallbackLanguage)
        if let vector = embedding?.vector(for: text) { return vector }
        // Environments without the system model (CI simulators): a zero
        // vector keeps the store/recall code paths testable.
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
        if let cached = cacheQueue.sync(execute: { embeddingCache[language] }) { return cached }
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else { return nil }
        cacheQueue.async(flags: .barrier) { self.embeddingCache[language] = embedding }
        return embedding
    }
}

// MARK: - GGUF encoder via llama.cpp

final class GGUFEmbeddingBackend: EmbeddingBackend {

    /// EmbeddingGemma-300M, Q8_0 (768-dim, 100+ languages). The id changes
    /// if the model changes, which orphans stored vectors into the re-embed
    /// queue.
    static let backendID = "embeddinggemma-300m-q8"
    static let idleUnloadSeconds: TimeInterval = 60

    let id = GGUFEmbeddingBackend.backendID
    let calibration = EmbeddingCalibration.embeddingGemma

    private let modelPath: String
    private let lock = NSLock()
    private var bridge: LlamaEmbedBridge?
    private var lastUse = Date.distantPast
    private var unloadTask: Task<Void, Never>?

    init(modelPath: String) {
        self.modelPath = modelPath
    }

    func embed(_ text: String, purpose: EmbeddingPurpose) -> [Double]? {
        lock.lock()
        defer { lock.unlock() }
        if bridge == nil {
            let started = Date()
            bridge = LlamaEmbedBridge(modelPath: modelPath)
            guard bridge != nil else {
                nlLog("[EmbeddingService] Failed to load GGUF embedding model", level: .error)
                return nil
            }
            nlLog("[EmbeddingService] Loaded \(id) in \(Int(Date().timeIntervalSince(started) * 1000)) ms", level: .info)
        }
        lastUse = Date()
        scheduleIdleUnload()
        // EmbeddingGemma's documented prompt formats.
        let prefixed = purpose == .query ? "task: search result | query: \(text)" : "title: none | text: \(text)"
        return bridge?.embed(prefixed)
    }

    /// Frees the model after a quiet period; it reloads on the next call
    /// (~100 ms). Keeps the 4 GB tier's headroom when memory is idle.
    private func scheduleIdleUnload() {
        unloadTask?.cancel()
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleUnloadSeconds))
            guard !Task.isCancelled, let self else { return }
            self.unloadIfIdle()
        }
    }

    private func unloadIfIdle() {
        lock.withLock {
            guard Date().timeIntervalSince(lastUse) >= Self.idleUnloadSeconds - 1 else { return }
            bridge = nil
            nlLog("[EmbeddingService] Unloaded idle \(id)", level: .info)
        }
    }
}
