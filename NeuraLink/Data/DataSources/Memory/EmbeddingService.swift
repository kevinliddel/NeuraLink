//
//  EmbeddingService.swift
//  NeuraLink
//
//  Routes text → vector to the active embedding backend (NLEmbedding by
//  default; the downloaded multilingual GGUF model when the user enables
//  it). Every stored vector carries the backend id so recall never
//  compares vectors from different models.
//
//  Created by Dedicatus on 09/05/2026.
//

import Foundation

final class EmbeddingService {
    static let shared = EmbeddingService()

    private let nlBackend = NLEmbeddingBackend()
    private let lock = NSLock()
    private var ggufBackend: GGUFEmbeddingBackend?
    private var preferredBackendID = NLEmbeddingBackend.backendID

    private init() {
        preferredBackendID = MemorySettings.shared.embeddingBackendID
    }

    /// Backend used for new vectors and queries. Falls back to NLEmbedding
    /// when the preferred GGUF model is not available on disk.
    private var activeBackend: EmbeddingBackend {
        lock.lock()
        defer { lock.unlock() }
        if preferredBackendID == GGUFEmbeddingBackend.backendID, let gguf = ggufBackend { return gguf }
        return nlBackend
    }

    var activeModelID: String { activeBackend.id }

    /// Cosine calibration for the active backend.
    var calibration: EmbeddingCalibration { activeBackend.calibration }

    /// Switches to the GGUF backend at `modelPath` (or back to NL when nil).
    /// The model must produce a probe vector first; a backend that cannot
    /// embed is never activated, so memories keep being stored with NL.
    /// Persisted through `MemorySettings.embeddingBackendID`.
    @discardableResult
    func useGGUFModel(at modelPath: String?) -> Bool {
        if let modelPath {
            let backend = GGUFEmbeddingBackend(modelPath: modelPath)
            guard let probe = backend.embed("probe", purpose: .query), !probe.isEmpty else {
                nlLog("[EmbeddingService] GGUF backend rejected: probe embedding failed", level: .error)
                return false
            }
            lock.lock()
            ggufBackend = backend
            preferredBackendID = GGUFEmbeddingBackend.backendID
            lock.unlock()
        } else {
            lock.lock()
            ggufBackend = nil
            preferredBackendID = NLEmbeddingBackend.backendID
            lock.unlock()
        }
        MemorySettings.shared.embeddingBackendID = preferredBackendID
        EmbeddingMigrator.shared.migrateIfNeeded()
        return true
    }

    /// Re-attaches the GGUF backend chosen in settings when its model is
    /// already on disk (never downloads). Called once at launch.
    func restorePreferredBackend() async {
        guard MemorySettings.shared.embeddingBackendID == GGUFEmbeddingBackend.backendID else { return }
        guard let url = await RemoteAssetCache.shared.localURLIfAvailable(for: .embeddingModel) else {
            nlLog("[EmbeddingService] Preferred GGUF model not on disk; using NLEmbedding", level: .warning)
            return
        }
        useGGUFModel(at: url.path)
    }

    /// Generates a vector for the given text with the active backend.
    func generateVector(for text: String, purpose: EmbeddingPurpose = .document) -> [Double]? {
        activeBackend.embed(text, purpose: purpose)
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
