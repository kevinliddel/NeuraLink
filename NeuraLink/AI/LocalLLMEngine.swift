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

    // Manual KV-cache management for models that require them as explicit inputs.
    private var kvCaches: [[String: MLMultiArray]] = []

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

                // CPU-only: avoids ENOMEM on 4 GB devices when Apple Neural Enginemmaps weight files.
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

    // MARK: - Generate

    func generate(prompt: String, maxTokens: Int = 30) async {
        guard isLoaded, logitProcessor != nil else {
            delegate?.localLLM(didFailWithError: LLMError.initializationFailed)
            return
        }

        // Reset states and manual KV caches for each new generation.
        if #available(iOS 17.0, *) {
            states = bodyChunks.map { $0.makeState() }
        }
        prepareManualCaches()

        isGenerating = true
        var currentText = ""
        let maxCtx = 256
        let rawTokens = tokenize(text: prompt)
        let tokens: [Int32] =
            rawTokens.count > maxCtx
            ? Array(rawTokens.suffix(maxCtx)) : rawTokens

        print(
            "[LlamaEngine] Generating: \(rawTokens.count) prompt tokens → \(tokens.count) capped, max \(maxTokens) new"
        )

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
        let accumulatedFeatures = try await runBodyChunks(token: token, pos: pos)

        guard let logit = logitProcessor else { throw LLMError.inferenceFailed }
        let provider = try MLDictionaryFeatureProvider(dictionary: accumulatedFeatures)
        let out = try await logit.prediction(from: provider)

        // Try common output names for the next token.
        for key in [nextTokenOutputKey, "next_token", "next_token_id", "argmax_token", "argmax"] {
            if let arr = out.featureValue(for: key)?.multiArrayValue {
                let token = arr.dataPointer.bindMemory(to: Int32.self, capacity: 1).pointee
                print("[LlamaEngine] Next token candidate (\(key)): \(token)")
                return token
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

    private func runBodyChunks(token: Int32, pos: Int) async throws -> [String: MLFeatureValue] {
        // Optional: run cache-processor to build position tensors.
        let posInputs = buildPositionInputs(from: pos)
        var accumulatedFeatures: [String: MLFeatureValue] = posInputs

        for (i, chunk) in bodyChunks.enumerated() {
            var dict: [String: MLFeatureValue] = accumulatedFeatures

            // Provide inputs required by this chunk
            let requiredInputs = chunk.modelDescription.inputDescriptionsByName.keys

            if i == 0 {
                // This specific model expects a fixed-size sequence input of [1, 64].
                let tokenArr = try MLMultiArray(shape: [1, 64], dataType: .int32)
                // Initialize with 0s and place the current token at index 0.
                for j in 0..<64 { tokenArr[j] = 0 }
                tokenArr[0] = NSNumber(value: token)
                dict[chunk1TokenInputKey] = MLFeatureValue(multiArray: tokenArr)
            }

            if requiredInputs.contains("full_sequence_length") {
                let fslArr = try MLMultiArray(shape: [1], dataType: .int32)
                fslArr[0] = NSNumber(value: Int32(pos + 1))
                dict["full_sequence_length"] = MLFeatureValue(multiArray: fslArr)
            }

            // If the chunk expects hidden_states but we have a different output name (like 'x' from chunk1),
            // try to map it if hiddenInputKey is expected.
            if requiredInputs.contains(hiddenInputKey) && dict[hiddenInputKey] == nil {
                dict[hiddenInputKey] = accumulatedFeatures["x"] ?? accumulatedFeatures["new_x"]
            }

            // Explicitly pass 'x' if required and available
            if requiredInputs.contains("x") && dict["x"] == nil {
                dict["x"] = accumulatedFeatures["x"] ?? accumulatedFeatures["new_x"]
            }

            // Provide manual KV caches if required by this specific chunk.
            if i < kvCaches.count {
                for (key, cache) in kvCaches[i] {
                    if requiredInputs.contains(key) {
                        dict[key] = MLFeatureValue(multiArray: cache)
                    }
                }
            }

            let provider = try MLDictionaryFeatureProvider(dictionary: dict)

            // Diagnostic: check for missing inputs
            for req in requiredInputs {
                if dict[req] == nil && !req.contains("cache") {  // Caches are handled above
                    print("[LlamaEngine] CRITICAL: Chunk \(i+1) missing required input: \(req)")
                }
            }

            let out: MLFeatureProvider
            if #available(iOS 17.0, *), i < states.count {
                out = try await chunk.prediction(from: provider, using: states[i])
            } else {
                out = try await chunk.prediction(from: provider)
            }

            // Accumulate all outputs and update manual caches
            for key in out.featureNames {
                if let val = out.featureValue(for: key) {
                    accumulatedFeatures[key] = val

                    // Update manual KV cache if this is a 'new_k_cache' or 'new_v_cache'
                    if key.contains("new_") && key.contains("cache") {
                        let baseKey = key.replacingOccurrences(of: "new_", with: "")
                        if i < kvCaches.count, let multiArray = val.multiArrayValue {
                            let expectedShape =
                                bodyChunks[i].modelDescription.inputDescriptionsByName[baseKey]?
                                .multiArrayConstraint?.shape ?? []

                            if multiArray.shape == expectedShape {
                                kvCaches[i][baseKey] = multiArray
                            } else {
                                // Sliding window update: concatenate old + new and shift.
                                // Expected is [1, 448, ...], New is [1, 64, ...]
                                if let updated = slidingWindowUpdate(
                                    old: kvCaches[i][baseKey], new: multiArray,
                                    expected: expectedShape) {
                                    kvCaches[i][baseKey] = updated
                                }
                            }
                        }
                    }

                    // Map new_x to x for the next chunk
                    if key == "new_x" {
                        accumulatedFeatures["x"] = val
                    }

                    // Also update the generic hidden state if this key looks like one.
                    if key.lowercased().contains("hidden") {
                        accumulatedFeatures[hiddenOutputKey] = val
                    }
                }
            }
        }

        return accumulatedFeatures
    }

    private func prepareManualCaches() {
        kvCaches = []
        for chunk in bodyChunks {
            var chunkCaches: [String: MLMultiArray] = [:]
            let inputs = chunk.modelDescription.inputDescriptionsByName
            for (name, desc) in inputs {
                if name.contains("cache") || name == "old_k_cache" || name == "old_v_cache",
                    let constraint = desc.multiArrayConstraint {
                    let dataType = constraint.dataType
                    if let arr = try? MLMultiArray(shape: constraint.shape, dataType: dataType) {
                        zeroFill(arr)
                        chunkCaches[name] = arr
                    }
                }
            }
            kvCaches.append(chunkCaches)
        }
        print(
            "[LlamaEngine] Initialized manual KV caches for \(kvCaches.filter { !$0.isEmpty }.count) chunks."
        )
    }

    private func zeroFill(_ arr: MLMultiArray) {
        if arr.dataType == .float16 {
            let ptr = arr.dataPointer.bindMemory(to: Float16.self, capacity: arr.count)
            for j in 0..<arr.count { ptr[j] = 0 }
        } else if arr.dataType == .float32 {
            let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: arr.count)
            for j in 0..<arr.count { ptr[j] = 0 }
        }
    }

    private func slidingWindowUpdate(old: MLMultiArray?, new: MLMultiArray, expected: [NSNumber])
        -> MLMultiArray? {
        guard let old = old else { return nil }
        // For Llama 3.2 1B: Old is [1, 448, 1, 512], New is [1, 64, 1, 512]
        // We shift 'old' by 64 and append 'new' to get the next 'old' of size 448?
        // Wait, if next input is 448, and we just got 64, the next 448 should be the LAST 448 of (old + new).
        // Total tokens = 448 + 64 = 512. Last 448 = (old[64...448] + new[0...64]).

        do {
            let result = try MLMultiArray(shape: expected, dataType: old.dataType)
            let oldSize = old.count
            let newSize = new.count
            let expectedSize = result.count

            // This is a simplified flat-copy for the head-dim flattened tensors.
            // Shift old: copy from index newSize of old into 0 of result.
            let shiftAmount = newSize
            let copyFromOldCount = oldSize - shiftAmount

            if old.dataType == .float16 {
                let oldPtr = old.dataPointer.bindMemory(to: Float16.self, capacity: oldSize)
                let newPtr = new.dataPointer.bindMemory(to: Float16.self, capacity: newSize)
                let resPtr = result.dataPointer.bindMemory(to: Float16.self, capacity: expectedSize)

                for i in 0..<copyFromOldCount {
                    resPtr[i] = oldPtr[i + shiftAmount]
                }
                for i in 0..<newSize {
                    resPtr[i + copyFromOldCount] = newPtr[i]
                }
            }
            return result
        } catch {
            return nil
        }
    }

    /// Queries the cache-processor (if loaded) for position tensors.
    /// Returns an empty dict if the processor is unavailable — chunks using
    /// MLState will derive position from their own state.
    private func buildPositionInputs(from pos: Int) -> [String: MLFeatureValue] {
        guard let proc = cacheProcessor else { return [:] }

        let posKey = "full_sequence_length"  // Standard for smpanaro models
        let posArr = try! MLMultiArray(shape: [1], dataType: .int32)
        posArr[0] = NSNumber(value: Int32(pos + 1))

        var dict: [String: MLFeatureValue] = [posKey: MLFeatureValue(multiArray: posArr)]

        // If the cache processor itself requires cache inputs, provide them.
        let inputs = proc.modelDescription.inputDescriptionsByName
        for (name, desc) in inputs {
            if name.contains("old_") || name.contains("cache") {
                if let constraint = desc.multiArrayConstraint {
                    if let arr = try? MLMultiArray(
                        shape: constraint.shape, dataType: constraint.dataType) {
                        zeroFill(arr)
                        dict[name] = MLFeatureValue(multiArray: arr)
                        if pos == 0 {
                            print(
                                "[LlamaEngine] Cache-processor requested \(name) with shape \(constraint.shape)"
                            )
                        }
                    }
                }
            } else if dict[name] == nil && !name.contains("position")
                && !name.contains("full_sequence_length") {
                print("[LlamaEngine] Cache-processor missing input: \(name)")
            }
        }

        let provider = try? MLDictionaryFeatureProvider(dictionary: dict)
        guard let p = provider, let result = try? proc.prediction(from: p) else {
            // Even if prediction fails, return the manual caches we prepared
            return dict
        }

        var out: [String: MLFeatureValue] = dict  // Start with inputs (cos/sin might be here too)
        for name in result.featureNames {
            if let val = result.featureValue(for: name) {
                out[name] = val
            }
        }
        return out
    }

    // MARK: - Tensor name discovery

    /// Inspects each model's interface once at load time and stores the tensor
    /// names used during inference. Logs the full interface for debugging.
    private func discoverTensorNames() {
        for (i, chunk) in bodyChunks.enumerated() {
            let inputs = chunk.modelDescription.inputDescriptionsByName
            let outputs = chunk.modelDescription.outputDescriptionsByName
            print("[LlamaEngine] chunk\(i+1) inputs: \(inputs.keys.sorted())")
            print("[LlamaEngine] chunk\(i+1) outputs: \(outputs.keys.sorted())")
            if #available(iOS 17.0, *) {
                let states = chunk.modelDescription.stateDescriptionsByName
                print("[LlamaEngine] chunk\(i+1) states: \(states.keys.sorted())")
            }

            if i == 0 {
                chunk1TokenInputKey =
                    inputs.keys.first { $0.lowercased().contains("id") }
                    ?? inputs.keys.first { !$0.lowercased().contains("hidden") }
                    ?? "input_ids"
                hiddenInputKey =
                    inputs.keys.first { $0.lowercased().contains("hidden") }
                    ?? "hidden_states"
                hiddenOutputKey =
                    outputs.keys.first { $0.lowercased().contains("hidden") }
                    ?? "hidden_states"
            }
        }

        if let proc = cacheProcessor {
            print(
                "[LlamaEngine] cache-processor inputs: \(proc.modelDescription.inputDescriptionsByName.keys.sorted())"
            )
            print(
                "[LlamaEngine] cache-processor outputs: \(proc.modelDescription.outputDescriptionsByName.keys.sorted())"
            )
        }

        if let logit = logitProcessor {
            let inputs = logit.modelDescription.inputDescriptionsByName
            let outputs = logit.modelDescription.outputDescriptionsByName
            print("[LlamaEngine] logit-processor inputs: \(inputs.keys.sorted())")
            print("[LlamaEngine] logit-processor outputs: \(outputs.keys.sorted())")

            nextTokenOutputKey =
                outputs.keys.first { $0.lowercased().contains("token") }
                ?? outputs.keys.first { !$0.lowercased().contains("logit") }
                ?? "next_token"
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
            if ptr[i] > maxVal {
                maxVal = ptr[i]
                maxIdx = Int32(i)
            }
        }
        return maxIdx
    }
}
