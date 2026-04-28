//
//  LocalLLMEngine+Inference.swift
//  NeuraLink
//
//  Created by Dedicatus on 28/04/2026.
//

import CoreML
import Foundation
import Tokenizers

extension LocalLLMEngine {
    // MARK: - Generate

    func generate(prompt: String, maxTokens: Int = 30) async {
        guard isLoaded, logitProcessor != nil else {
            delegate?.localLLM(didFailWithError: LLMError.initializationFailed)
            return
        }

        let generationStartNs = DispatchTime.now().uptimeNanoseconds

        // KV state is managed via manual kvCaches (see prepareManualCaches).
        // makeState() is intentionally omitted: all chunks declare states:[],
        // and calling it when ANE falls back to CPU crashes with NSInternalInconsistencyException.
        prepareManualCaches()

        isGenerating = true
        var currentText = ""
        // 64 is this model's native input-chunk size; more tokens make prefill impractically
        // slow on CPU (each forward pass takes ~100–300 ms and must run once per token).
        let maxCtx = 64
        let rawTokens = tokenize(text: prompt)
        let tokens: [Int32] =
            rawTokens.count > maxCtx
            ? Array(rawTokens.suffix(maxCtx)) : rawTokens

        print(
            "[LlamaEngine] Generating: \(rawTokens.count) prompt tokens → \(tokens.count) capped, max \(maxTokens) new"
        )

        do {
            var pos = 0
            let prefillStartNs = DispatchTime.now().uptimeNanoseconds
            var prefillCount = 0

            // Prefill: all tokens except the last — update KV cache, skip logit head.
            let prefillTokens = Array(tokens.dropLast())
            for (idx, token) in prefillTokens.enumerated() {
                guard isGenerating else { break }
                try await throughBody(token: token, pos: pos)
                pos += 1
                prefillCount += 1
                if (idx + 1) % 10 == 0 || idx == prefillTokens.count - 1 {
                    print("[LlamaEngine] Prefill \(idx + 1)/\(prefillTokens.count)…")
                }
            }

            let prefillElapsedMs = Double(DispatchTime.now().uptimeNanoseconds - prefillStartNs) / 1_000_000.0
            if prefillCount > 0 {
                print(
                    "[LlamaEngine] Prefill timing: \(String(format: "%.1f", prefillElapsedMs)) ms total, \(String(format: "%.1f", prefillElapsedMs / Double(prefillCount))) ms/token"
                )
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
            var lastToken: Int32? = nil
            var repeatedTokenStreak = 0
            var emptyDecodeStreak = 0
            let decodeStartNs = DispatchTime.now().uptimeNanoseconds
            var decodeStepCount = 0
            var emittedTokenCount = 0

            // Decode loop.
            for step in 0..<maxTokens {
                guard isGenerating else { break }
                if eosTokens.contains(nextToken) {
                    print("[LlamaEngine] EOS at step \(step)")
                    break
                }
                decodeStepCount += 1

                if nextToken == lastToken {
                    repeatedTokenStreak += 1
                } else {
                    repeatedTokenStreak = 0
                }
                lastToken = nextToken

                if repeatedTokenStreak >= 12 {
                    print("[LlamaEngine] Stopping decode: repeated token \(nextToken) x\(repeatedTokenStreak + 1)")
                    break
                }

                let decoded = decode(tokenID: nextToken)
                if decoded.isEmpty {
                    emptyDecodeStreak += 1
                    if emptyDecodeStreak >= 16 {
                        print("[LlamaEngine] Stopping decode: too many empty decoded tokens")
                        break
                    }
                } else {
                    emptyDecodeStreak = 0
                    emittedTokenCount += 1
                    currentText += decoded
                    await MainActor.run { [weak self] in
                        self?.delegate?.localLLM(didGenerateToken: decoded)
                    }
                }

                nextToken = try await throughBodyAndHead(token: nextToken, pos: pos)
                pos += 1
            }

            let decodeElapsedMs = Double(DispatchTime.now().uptimeNanoseconds - decodeStartNs) / 1_000_000.0
            if decodeStepCount > 0 {
                print(
                    "[LlamaEngine] Decode timing: \(String(format: "%.1f", decodeElapsedMs)) ms total, \(String(format: "%.1f", decodeElapsedMs / Double(decodeStepCount))) ms/step, emitted \(emittedTokenCount)"
                )
            }
            let totalElapsedMs = Double(DispatchTime.now().uptimeNanoseconds - generationStartNs) / 1_000_000.0
            print("[LlamaEngine] Total generation timing: \(String(format: "%.1f", totalElapsedMs)) ms")

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
        kvCaches = []
        print("[LlamaEngine] Unloaded.")
    }

    // MARK: - Inference core

    internal func throughBody(token: Int32, pos: Int) async throws {
        _ = try await runBodyChunks(token: token, pos: pos)
    }

    internal func throughBodyAndHead(token: Int32, pos: Int) async throws -> Int32 {
        let accumulatedFeatures = try await runBodyChunks(token: token, pos: pos)

        guard let logit = logitProcessor else { throw LLMError.inferenceFailed }
        let provider = try MLDictionaryFeatureProvider(dictionary: accumulatedFeatures)
        let out = try await coreMLPredict(model: logit, input: provider)

        // Try common output names for the next token.
        for key in [nextTokenOutputKey, "next_token", "next_token_id", "argmax_token", "argmax"] {
            if let arr = out.featureValue(for: key)?.multiArrayValue {
                if let token = scalarToken(from: arr) {
                    print("[LlamaEngine] Next token candidate (\(key)): \(token)")
                    return token
                }
                return argmax(logits: arr)
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

    internal func runBodyChunks(
        token: Int32, pos: Int
    ) async throws -> [String: MLFeatureValue] {
        let posInputs = buildPositionInputs(from: pos)
        var accumulatedFeatures: [String: MLFeatureValue] = posInputs

        // All 6 chunks are transformer body layers; logit projection is a separate model.
        // Prefill must run through every body chunk so KV caches stay aligned.
        let activeChunks = bodyChunks

        for (i, chunk) in activeChunks.enumerated() {
            var dict: [String: MLFeatureValue] = accumulatedFeatures
            let requiredInputs = chunk.modelDescription.inputDescriptionsByName.keys

            if i == 0 {
                // chunk1 receives the current token at slot 0 of the [1,64] input_ids array.
                // full_sequence_length (set above) tells the model the causal position
                // for RoPE and the attention mask — the token slot is always 0.
                let tokenArr = try MLMultiArray(shape: [1, 64], dataType: .int32)
                for j in 0..<64 { tokenArr[j] = 0 }
                tokenArr[0] = NSNumber(value: token)
                dict[chunk1TokenInputKey] = MLFeatureValue(multiArray: tokenArr)
            }

            if requiredInputs.contains("full_sequence_length") {
                let fslArr = try MLMultiArray(shape: [1], dataType: .int32)
                fslArr[0] = NSNumber(value: Int32(pos + 1))
                dict["full_sequence_length"] = MLFeatureValue(multiArray: fslArr)
            }

            if requiredInputs.contains(hiddenInputKey) && dict[hiddenInputKey] == nil {
                dict[hiddenInputKey] = accumulatedFeatures["x"] ?? accumulatedFeatures["new_x"]
            }

            if requiredInputs.contains("x") && dict["x"] == nil {
                dict["x"] = accumulatedFeatures["x"] ?? accumulatedFeatures["new_x"]
            }

            if i < kvCaches.count {
                for (key, cache) in kvCaches[i] {
                    if requiredInputs.contains(key) {
                        dict[key] = MLFeatureValue(multiArray: cache)
                    }
                }
            }

            let provider = try MLDictionaryFeatureProvider(dictionary: dict)

            for req in requiredInputs {
                if dict[req] == nil && !req.contains("cache") {
                    print("[LlamaEngine] CRITICAL: Chunk \(i+1) missing required input: \(req)")
                }
            }

            // Use GCD-wrapped sync prediction to avoid a deadlock in the iOS 17
            // prediction(from:using:) API when called on models that have no MLState
            // features (all chunks report states: [] at load time).
            let out = try await coreMLPredict(model: chunk, input: provider)

            for key in out.featureNames {
                if let val = out.featureValue(for: key) {
                    accumulatedFeatures[key] = val

                    if key.contains("new_") && key.contains("cache") {
                        let baseKey = key.replacingOccurrences(of: "new_", with: "")
                        if i < kvCaches.count, let multiArray = val.multiArrayValue {
                            let expectedShape =
                                bodyChunks[i].modelDescription.inputDescriptionsByName[baseKey]?
                                .multiArrayConstraint?.shape ?? []

                            if multiArray.shape == expectedShape {
                                kvCaches[i][baseKey] = multiArray
                            } else {
                                if let updated = slidingWindowUpdate(
                                    old: kvCaches[i][baseKey], new: multiArray,
                                    expected: expectedShape) {
                                    kvCaches[i][baseKey] = updated
                                }
                            }
                        }
                    }

                    if key == "new_x" {
                        accumulatedFeatures["x"] = val
                    }

                    if key.lowercased().contains("hidden") {
                        accumulatedFeatures[hiddenOutputKey] = val
                    }
                }
            }
        }

        return accumulatedFeatures
    }

    // MARK: - CoreML prediction helper

    /// Runs a synchronous CoreML prediction on a GCD thread so the cooperative
    /// thread pool isn't blocked and the iOS 17 stateful-prediction API (which
    /// can hang with an empty MLState on non-stateful models) is avoided entirely.
    internal func coreMLPredict(
        model: MLModel, input: MLFeatureProvider
    ) async throws -> MLFeatureProvider {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try model.prediction(from: input))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
