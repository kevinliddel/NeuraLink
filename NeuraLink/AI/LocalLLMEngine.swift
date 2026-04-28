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
//  Inference pattern (stateful, KV-cache via MLState):
//    Prefill: run all prompt tokens except last through body chunks only.
//    Decode:  run last prefill token + each new token through body + logit-processor.
//
//  Created by Dedicatus on 23/04/2026.
//

import CoreML
import Foundation
import Tokenizers

final class LocalLLMEngine: NSObject, @unchecked Sendable, LLMEngineProtocol {
    static let shared = LocalLLMEngine()

    weak var delegate: LocalLLMEngineDelegate?

    private var bodyChunks: [MLModel] = []
    private var cacheProcessor: MLModel?
    private var logitProcessor: MLModel?
    private var tokenizer: Tokenizer?
    private var isGenerating = false

    // One KV-cache state per body chunk (iOS 17+ stateful model).
    @available(iOS 17.0, *)
    private var states: [MLState] = []

    // Tensor names discovered at load time from each model's modelDescription.
    private var chunk1TokenInputKey = "input_ids"
    private var hiddenInputKey = "hidden_states"
    private var hiddenOutputKey = "hidden_states"
    private var nextTokenOutputKey = "next_token"

    private var loadTask: Task<Void, Error>?
    private let loadLock = NSLock()

    // EOS tokens: Llama-3 <|end_of_text|>=128001, <|eot_id|>=128009
    private let eosTokens: Set<Int32> = [2, 128001, 128009]

    var isLoaded: Bool { !bodyChunks.isEmpty && logitProcessor != nil }

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

                // CPU-only: avoids ENOMEM on 4 GB devices when ANE mmaps weight files.
                let cfg = MLModelConfiguration()
                cfg.computeUnits = .cpuOnly

                var chunks: [MLModel] = []
                for i in 1...6 {
                    guard let url = LlamaModelAccess.chunkURL(index: i) else {
                        throw LLMError.modelNotFound
                    }
                    print("[LlamaEngine] Loading chunk\(i)…")
                    chunks.append(try await MLModel.load(contentsOf: url, configuration: cfg))
                }

                if let url = LlamaModelAccess.cacheProcessorURL() {
                    print("[LlamaEngine] Loading cache-processor…")
                    self.cacheProcessor = try? await MLModel.load(
                        contentsOf: url, configuration: cfg)
                }

                guard let logitURL = LlamaModelAccess.logitProcessorURL() else {
                    throw LLMError.modelNotFound
                }
                print("[LlamaEngine] Loading logit-processor…")
                self.logitProcessor = try await MLModel.load(
                    contentsOf: logitURL, configuration: cfg)

                self.bodyChunks = chunks

                if #available(iOS 17.0, *) {
                    self.states = chunks.map { $0.makeState() }
                }

                self.discoverTensorNames()
                print("[LlamaEngine] Ready — \(chunks.count) body chunks loaded.")
            }
            self.loadTask = t
            return t
        }
        try await task.value
    }

    // MARK: - Generate

    func generate(prompt: String, maxTokens: Int = 30) async {
        guard isLoaded, logitProcessor != nil else {
            delegate?.localLLM(didFailWithError: LLMError.initializationFailed)
            return
        }

        // Reset KV cache state for each new generation.
        if #available(iOS 17.0, *) {
            states = bodyChunks.map { $0.makeState() }
        }

        isGenerating = true
        var currentText = ""
        let maxCtx = 256
        let rawTokens = tokenize(text: prompt)
        let tokens: [Int32] = rawTokens.count > maxCtx
            ? Array(rawTokens.suffix(maxCtx)) : rawTokens

        print("[LlamaEngine] Generating: \(rawTokens.count) prompt tokens → \(tokens.count) capped, max \(maxTokens) new")

        do {
            var pos = 0

            // Prefill: all tokens except the last — update KV cache, skip logit head.
            for token in tokens.dropLast() {
                guard isGenerating else { break }
                try await throughBody(token: token, pos: pos)
                pos += 1
            }

            // Last prefill token → first generated token.
            guard isGenerating, let lastPrefill = tokens.last else {
                await MainActor.run { [weak self] in
                    self?.delegate?.localLLM(didFinishGeneration: currentText)
                }
                isGenerating = false
                return
            }

            var nextToken = try await throughBodyAndHead(token: lastPrefill, pos: pos)
            pos += 1

            // Decode loop.
            for step in 0..<maxTokens {
                guard isGenerating else { break }
                if eosTokens.contains(nextToken) {
                    print("[LlamaEngine] EOS at step \(step)")
                    break
                }
                let decoded = decode(tokenID: nextToken)
                currentText += decoded
                await MainActor.run { [weak self] in
                    self?.delegate?.localLLM(didGenerateToken: decoded)
                }
                nextToken = try await throughBodyAndHead(token: nextToken, pos: pos)
                pos += 1
            }

            await MainActor.run { [weak self] in
                self?.delegate?.localLLM(didFinishGeneration: currentText)
            }
        } catch {
            print("[LlamaEngine] Inference error: \(error)")
            await MainActor.run { [weak self] in
                self?.delegate?.localLLM(didFailWithError: error)
            }
        }

        isGenerating = false
    }

    func stop() { isGenerating = false }

    func unloadModel() {
        isGenerating = false
        loadLock.withLock { loadTask = nil }
        bodyChunks = []
        cacheProcessor = nil
        logitProcessor = nil
        tokenizer = nil
        if #available(iOS 17.0, *) { states = [] }
        print("[LlamaEngine] Unloaded.")
    }

    // MARK: - Inference core

    private func throughBody(token: Int32, pos: Int) async throws {
        _ = try await runBodyChunks(token: token, pos: pos)
    }

    private func throughBodyAndHead(token: Int32, pos: Int) async throws -> Int32 {
        let hiddenFV = try await runBodyChunks(token: token, pos: pos)

        guard let logit = logitProcessor else { throw LLMError.inferenceFailed }
        let provider = try MLDictionaryFeatureProvider(
            dictionary: [hiddenInputKey: hiddenFV])
        let out = try await logit.prediction(from: provider)

        // Try common output names for the next token.
        for key in [nextTokenOutputKey, "next_token", "next_token_id", "argmax_token"] {
            if let arr = out.featureValue(for: key)?.multiArrayValue {
                return arr.dataPointer.bindMemory(to: Int32.self, capacity: 1).pointee
            }
        }
        // Fall back to argmax over logits if no direct token output is found.
        for key in ["logits", "output_logits"] {
            if let arr = out.featureValue(for: key)?.multiArrayValue {
                return argmax(logits: arr)
            }
        }
        throw LLMError.inferenceFailed
    }

    private func runBodyChunks(token: Int32, pos: Int) async throws -> MLFeatureValue {
        // Optional: run cache-processor to build position tensors.
        let posInputs = buildPositionInputs(from: pos)

        var hiddenFV: MLFeatureValue? = nil

        for (i, chunk) in bodyChunks.enumerated() {
            var dict: [String: MLFeatureValue] = posInputs

            if i == 0 {
                // First chunk takes the token ID directly.
                let tokenArr = try MLMultiArray(shape: [1, 1], dataType: .int32)
                tokenArr[0] = NSNumber(value: token)
                dict[chunk1TokenInputKey] = MLFeatureValue(multiArray: tokenArr)
            } else if let hidden = hiddenFV {
                dict[hiddenInputKey] = hidden
            }

            let provider = try MLDictionaryFeatureProvider(dictionary: dict)
            let out: MLFeatureProvider
            if #available(iOS 17.0, *), i < states.count {
                out = try await chunk.prediction(from: provider, using: states[i])
            } else {
                out = try await chunk.prediction(from: provider)
            }

            hiddenFV = out.featureValue(for: hiddenOutputKey)
        }

        guard let result = hiddenFV else { throw LLMError.inferenceFailed }
        return result
    }

    /// Queries the cache-processor (if loaded) for position tensors.
    /// Returns an empty dict if the processor is unavailable — chunks using
    /// MLState will derive position from their own state.
    private func buildPositionInputs(from pos: Int) -> [String: MLFeatureValue] {
        guard let proc = cacheProcessor else { return [:] }
        guard let posArr = try? MLMultiArray(shape: [1], dataType: .int32) else { return [:] }
        posArr[0] = NSNumber(value: pos)
        let inputKeys = proc.modelDescription.inputDescriptionsByName.keys
        let posKey = inputKeys.first { $0.lowercased().contains("pos") } ?? "position"
        let provider = try? MLDictionaryFeatureProvider(
            dictionary: [posKey: MLFeatureValue(multiArray: posArr)])
        guard let p = provider, let result = try? proc.prediction(from: p) else { return [:] }
        var dict: [String: MLFeatureValue] = [:]
        for key in result.featureNames {
            if let val = result.featureValue(for: key) { dict[key] = val }
        }
        return dict
    }

    // MARK: - Tensor name discovery

    /// Inspects each model's interface once at load time and stores the tensor
    /// names used during inference. Logs the full interface for debugging.
    private func discoverTensorNames() {
        if let first = bodyChunks.first {
            let inputs = first.modelDescription.inputDescriptionsByName
            let outputs = first.modelDescription.outputDescriptionsByName
            chunk1TokenInputKey = inputs.keys.first { $0.lowercased().contains("id") }
                ?? inputs.keys.first { !$0.lowercased().contains("hidden") }
                ?? "input_ids"
            hiddenInputKey = inputs.keys.first { $0.lowercased().contains("hidden") }
                ?? "hidden_states"
            hiddenOutputKey = outputs.keys.first { $0.lowercased().contains("hidden") }
                ?? "hidden_states"
            print("[LlamaEngine] chunk1 inputs: \(inputs.keys.sorted())")
            print("[LlamaEngine] chunk1 outputs: \(outputs.keys.sorted())")
        }
        if let logit = logitProcessor {
            let outputs = logit.modelDescription.outputDescriptionsByName
            nextTokenOutputKey = outputs.keys.first { $0.lowercased().contains("token") }
                ?? outputs.keys.first { !$0.lowercased().contains("logit") }
                ?? "next_token"
            print("[LlamaEngine] logit-processor inputs: \(logit.modelDescription.inputDescriptionsByName.keys.sorted())")
            print("[LlamaEngine] logit-processor outputs: \(outputs.keys.sorted())")
        }
    }

    // MARK: - Helpers

    private func tokenize(text: String) -> [Int32] {
        guard let tok = tokenizer else { return [1] }
        return tok.encode(text: text).map { Int32($0) }
    }

    private func decode(tokenID: Int32) -> String {
        tokenizer?.decode(tokens: [Int(tokenID)], skipSpecialTokens: true) ?? ""
    }

    private func argmax(logits: MLMultiArray) -> Int32 {
        let ptr = logits.dataPointer.bindMemory(to: Float.self, capacity: logits.count)
        var maxVal: Float = -.greatestFiniteMagnitude
        var maxIdx: Int32 = 0
        for i in 0..<logits.count {
            if ptr[i] > maxVal { maxVal = ptr[i]; maxIdx = Int32(i) }
        }
        return maxIdx
    }
}
