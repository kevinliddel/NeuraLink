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

    // One KV-cache state per body chunk (iOS 17+ stateful model).
    @available(iOS 17.0, *)
    internal var states: [MLState] = []

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

                // CPU-only: avoids ENOMEM on 4 GB devices when Apple Neural Engine mmaps weight files.
                let cfg = MLModelConfiguration()
                cfg.computeUnits = .cpuOnly

                var chunks: [MLModel] = []
                for i in 1...6 {
                    await Task.yield()  // Give the system a breather between large chunk loads
                    guard let url = LlamaModelAccess.chunkURL(index: i) else {
                        throw LLMError.modelNotFound
                    }
                    print("[LlamaEngine] Loading chunk\(i)…")
                    let chunk = try await MLModel.load(contentsOf: url, configuration: cfg)
                    chunks.append(chunk)
                    print("[LlamaEngine] Chunk \(i) ready.")
                }
                self.bodyChunks = chunks

                if let url = LlamaModelAccess.cacheProcessorURL() {
                    print("[LlamaEngine] Loading cache-processor…")
                    self.cacheProcessor = try? await MLModel.load(
                        contentsOf: url, configuration: cfg)
                    print(
                        "[LlamaEngine] Cache-processor \(self.cacheProcessor != nil ? "ready" : "skipped")."
                    )
                }

                guard let logitURL = LlamaModelAccess.logitProcessorURL() else {
                    throw LLMError.modelNotFound
                }
                print("[LlamaEngine] Loading logit-processor…")
                self.logitProcessor = try await MLModel.load(
                    contentsOf: logitURL, configuration: cfg)
                print("[LlamaEngine] Logit-processor ready.")

                if #available(iOS 17.0, *) {
                    print("[LlamaEngine] Initializing states…")
                    self.states = chunks.map { $0.makeState() }
                }

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
            throw error
        }
    }
}
