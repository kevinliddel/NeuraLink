//
//  EmbeddingMigrator.swift
//  NeuraLink
//
//  Re-embeds stored memories whose vectors came from a different backend
//  than the active one (docs/CHAT_LLM_IMPROVEMENT_PLAN.md §C2). Runs in
//  small batches at background priority and is resumable: it simply asks
//  the store for rows whose `vector_model` differs.
//
//  Created by Dedicatus on 26/09/2026.
//

import Foundation

final class EmbeddingMigrator: @unchecked Sendable {

    static let shared = EmbeddingMigrator()

    static let batchSize = 50
    /// Pause between batches so a long backlog never monopolises the CPU.
    static let batchPause: Duration = .milliseconds(200)

    private let store: MemoryStore
    private let embedder: EmbeddingService
    private let lock = NSLock()
    private var inFlight = false

    init(store: MemoryStore = .shared, embedder: EmbeddingService = .shared) {
        self.store = store
        self.embedder = embedder
    }

    /// Kicks a background migration if any rows are stale. Safe to call often.
    func migrateIfNeeded() {
        let model = embedder.activeModelID
        guard store.countUnits(notEmbeddedWith: model) > 0 else { return }
        lock.lock()
        guard !inFlight else { lock.unlock(); return }
        inFlight = true
        lock.unlock()

        Task { [self] in
            let migrated = await migrateAll(to: model)
            lock.withLock { inFlight = false }
            nlLog("[EmbeddingMigrator] Re-embedded \(migrated) memories with \(model)", level: .info)
        }
    }

    /// Re-embeds every stale row. Returns how many rows were updated.
    func migrateAll(to model: String) async -> Int {
        var total = 0
        while true {
            let batch = store.fetchUnits(notEmbeddedWith: model, limit: Self.batchSize)
            guard !batch.isEmpty else { break }
            let done = await embedBatch(batch, model: model)
            total += done
            // A row that fails to embed would loop forever; stop on a batch with no progress.
            if done == 0 { break }
            try? await Task.sleep(for: Self.batchPause)
        }
        return total
    }

    /// Embeds one batch off the main thread (same continuation-on-GCD
    /// pattern as the LLM engines). Returns how many rows were updated.
    private func embedBatch(_ batch: [MemoryUnit], model: String) async -> Int {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            DispatchQueue.global(qos: .background).async { [self] in
                var done = 0
                for unit in batch {
                    guard let vector = embedder.generateVector(for: unit.text, purpose: .document) else { continue }
                    store.updateVector(id: unit.id, vector: vector, model: model)
                    done += 1
                }
                continuation.resume(returning: done)
            }
        }
    }
}
