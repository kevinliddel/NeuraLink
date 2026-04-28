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

        if #available(iOS 17.0, *) {
            states = bodyChunks.map { $0.makeState() }
        }
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

            // Prefill: all tokens except the last — update KV cache, skip logit head.
            let prefillTokens = Array(tokens.dropLast())
            for (idx, token) in prefillTokens.enumerated() {
                guard isGenerating else { break }
                try await throughBody(token: token, pos: pos)
                pos += 1
                if (idx + 1) % 10 == 0 || idx == prefillTokens.count - 1 {
                    print("[LlamaEngine] Prefill \(idx + 1)/\(prefillTokens.count)…")
                }
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
        _ = try await runBodyChunks(token: token, pos: pos, includeHead: false)
    }

    internal func throughBodyAndHead(token: Int32, pos: Int) async throws -> Int32 {
        let accumulatedFeatures = try await runBodyChunks(token: token, pos: pos, includeHead: true)

        guard let logit = logitProcessor else { throw LLMError.inferenceFailed }
        let provider = try MLDictionaryFeatureProvider(dictionary: accumulatedFeatures)
        let out = try await coreMLPredict(model: logit, input: provider)

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

    internal func runBodyChunks(
        token: Int32, pos: Int, includeHead: Bool
    ) async throws -> [String: MLFeatureValue] {
        let posInputs = buildPositionInputs(from: pos)
        var accumulatedFeatures: [String: MLFeatureValue] = posInputs

        // Skip chunk6 (logit head) during prefill — logits aren't needed until decode.
        let activeChunks = includeHead ? bodyChunks : Array(bodyChunks.dropLast())

        for (i, chunk) in activeChunks.enumerated() {
            var dict: [String: MLFeatureValue] = accumulatedFeatures
            let requiredInputs = chunk.modelDescription.inputDescriptionsByName.keys

            if i == 0 {
                // Model expects a fixed-size sequence input of [1, 64].
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
