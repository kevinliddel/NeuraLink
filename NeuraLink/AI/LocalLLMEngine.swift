//
//  LocalLLMEngine.swift
//  NeuraLink
//
//  Chunked stateful inference for smpanaro/Llama-3.2-1B-Instruct-CoreML.
//
//  Repo layout (6 body chunks + 2 processors, all .mlmodelc at snapshot root):
//    Llama-3.2-1B-Instruct_chunk1..6.mlmodelc   body / transformer layers
//    cache-processor.mlmodelc                     position + cache tensors
//    logit-processor.mlmodelc                     hidden → next token ID
//
//  Created by Dedicatus on 27/04/2026.
//

import CoreML
import Foundation
import Tokenizers

final class LocalLLMEngine: NSObject, @unchecked Sendable, LLMEngineProtocol {
    static let shared = LocalLLMEngine()

    weak var delegate: LocalLLMEngineDelegate?

    internal var bodyChunks: [MLModel] = []
    internal var cacheProcessor: MLModel?
    internal var logitProcessor: MLModel?
    internal var tokenizer: Tokenizer?
    internal var isGenerating = false

    // NOTE: All 6 body chunks report states:[] — no MLState features exist.
    // makeState() crashes when ANE falls back to CPU (engine becomes null).
    // We use manual kvCaches exclusively; no MLState is needed.

    // Tensor names discovered at load time from each model's modelDescription.
    internal var chunk1TokenInputKey = "input_ids"
    internal var hiddenInputKey = "hidden_states"
    internal var hiddenOutputKey = "hidden_states"
    internal var nextTokenOutputKey = "next_token"

    internal var loadTask: Task<Void, Error>?
    internal let loadLock = NSLock()

    // EOS tokens: Llama-3 <|end_of_text|>=128001, <|eot_id|>=128009
    internal let eosTokens: Set<Int32> = [2, 128001, 128009]

    // Manual KV-cache management for models that require them as explicit inputs.
    internal var kvCaches: [[String: MLMultiArray]] = []

    var isLoaded: Bool { bodyChunks.count == 6 && logitProcessor != nil }

    override private init() { super.init() }

    // MARK: - Load

    func loadModel() async throws {
        if isLoaded { return }

        let task: Task<Void, Error> = loadLock.withLock {
            if let existing = loadTask { return existing }
            let t = Task<Void, Error> {
                guard let dir = LlamaModelAccess.snapshotDir() else {
                    throw LLMError.modelNotFound
                }
                print("[LlamaEngine] Loading from: \(dir.lastPathComponent)")

                print("[LlamaEngine] Loading tokenizer…")
                self.tokenizer = try await AutoTokenizer.from(
                    pretrained: LlamaModelAccess.tokenizerID)
                print("[LlamaEngine] Tokenizer ready.")

                // Memory constraint: iPhone 11 (4 GB) OOMs when body chunks are
                // loaded with cpuAndGPU — the Metal weight copy doubles DRAM usage.
                // ANE is blocked for chunks 2-5 by an H12 fp16 channel-alignment bug
                // in the smpanaro model (8 ch × 2 B = 16 B, ANE needs 64 B).
                // cpuOnly is the only safe config until the model is re-exported.
                let cpuCfg = MLModelConfiguration()
                cpuCfg.computeUnits = .cpuOnly

                // Smaller models (processors) are safe to target ANE.
                let aneCfg = MLModelConfiguration()
                aneCfg.computeUnits = .cpuAndNeuralEngine

                var chunks: [MLModel] = []
                for i in 1...6 {
                    await Task.yield()  // Yield between chunks to let the OS breathe
                    guard let url = LlamaModelAccess.chunkURL(index: i) else {
                        throw LLMError.modelNotFound
                    }
                    print("[LlamaEngine] Loading chunk\(i) (CPU)…")
                    let chunk = try await loadWithTimeout(
                        url: url, configuration: cpuCfg, label: "chunk\(i)")
                    chunks.append(chunk)
                    print("[LlamaEngine] Chunk \(i) ready.")
                }
                self.bodyChunks = chunks

                if let url = LlamaModelAccess.cacheProcessorURL() {
                    print("[LlamaEngine] Loading cache-processor…")
                    self.cacheProcessor = try? await MLModel.load(
                        contentsOf: url, configuration: aneCfg)
                    let cpStatus = self.cacheProcessor != nil ? "ready" : "skipped"
                    print("[LlamaEngine] Cache-processor \(cpStatus).")
                }

                guard let logitURL = LlamaModelAccess.logitProcessorURL() else {
                    throw LLMError.modelNotFound
                }
                print("[LlamaEngine] Loading logit-processor…")
                self.logitProcessor = try await loadWithTimeout(
                    url: logitURL, configuration: aneCfg, label: "logit-processor")
                print("[LlamaEngine] Logit-processor ready.")

                // Stateful MLState API is intentionally not used:
                // all chunks declare states:[] and makeState() crashes when
                // the ANE compiler falls back to CPU (engine = null).

                self.discoverTensorNames()
                print("[LlamaEngine] Ready — \(chunks.count) body chunks loaded.")
            }
            self.loadTask = t
            return t
        }

        do {
            try await task.value
        } catch {
            loadLock.withLock { loadTask = nil }  // Allow retry
            // A timeout almost certainly means a corrupt/incomplete bundle.
            // Clear the cached path so the next launch re-validates from disk.
            if case LLMError.loadTimeout = error {
                LlamaModelAccess.clearCache()
                print("[LlamaEngine] Cleared snapshot cache after timeout — re-download required.")
            }
            throw error
        }
    }
}
