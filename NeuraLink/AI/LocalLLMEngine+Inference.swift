//
//  LocalLLMEngine+Inference.swift
//  NeuraLink
//
//  Created by Dedicatus on 28/04/2026.
//

import CoreML
import Foundation

extension LocalLLMEngine {
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

    internal func throughBody(token: Int32, pos: Int) async throws {
        _ = try await runBodyChunks(token: token, pos: pos)
    }

    internal func throughBodyAndHead(token: Int32, pos: Int) async throws -> Int32 {
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

    internal func runBodyChunks(token: Int32, pos: Int) async throws -> [String: MLFeatureValue] {
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
}
