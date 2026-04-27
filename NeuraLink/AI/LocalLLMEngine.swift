//
//  LocalLLMEngine.swift
//  NeuraLink
//
//  Created by Dedicatus on 23/04/2026.
//

import CoreML
import Foundation
import Hub
import Tokenizers

enum LLMError: Error {
    case modelNotFound
    case inferenceFailed
    case initializationFailed
}

/// A protocol defining the interface for local LLM inference.
protocol LocalLLMEngineDelegate: AnyObject {
    func localLLM(didGenerateToken token: String)
    func localLLM(didFinishGeneration fullText: String)
    func localLLM(didFailWithError error: Error)
}

/// Manages the execution of a Core ML stateful language model (e.g., Llama-3.2-1B)
/// optimized for the Apple Neural Engine (NPU).
final class LocalLLMEngine: NSObject, @unchecked Sendable, LLMEngineProtocol {
    static let shared = LocalLLMEngine()

    weak var delegate: LocalLLMEngineDelegate?

    private var model: MLModel?
    private var tokenizer: Tokenizer?
    private var isGenerating = false
    private var loadTask: Task<Void, Error>?
    // Guards the loadTask check-and-create so concurrent callers can't both see nil.
    private let loadLock = NSLock()

    var isLoaded: Bool { model != nil }

    // A stateful Core ML model maintains its own KV cache across predictions.
    // iOS 17+ introduced `MLState` to manage this.
    @available(iOS 17.0, *)
    private var mlState: MLState?

    // To support iPhone 11 (4GB RAM), a 1B - 3B model is recommended over 7B.
    private let modelName = "LocalChatModel_Int4"

    // EOS tokens for Llama-2 (2), Llama-3 (<|eot_id|>=128009, <|end_of_text|>=128001)
    private let eosTokens: Set<Int32> = [2, 128001, 128009]

    override private init() {
        super.init()
    }

    /// Loads the Core ML model and Tokenizer from the app bundle/Hub.
    /// Concurrent callers share one Task — the second caller just awaits the first.
    func loadModel() async throws {
        if model != nil { return }

        // Atomically check-and-create so two concurrent callers can't both see nil
        // and each try to mmap weight.bin at the same time (causes ENOMEM / error -14).
        let task: Task<Void, Error> = loadLock.withLock {
            if let existing = loadTask { return existing }
            let t = Task<Void, Error> {
                print("[LocalLLM] Loading tokenizer...")
                self.tokenizer = try await AutoTokenizer.from(
                    pretrained: "NousResearch/Meta-Llama-3-8B-Instruct")
                print("[LocalLLM] Tokenizer loaded successfully.")

                guard
                    let url = Bundle.main.url(
                        forResource: self.modelName, withExtension: "mlmodelc")
                else {
                    print("[LocalLLM] Error: \(self.modelName).mlmodelc not found in bundle.")
                    throw LLMError.modelNotFound
                }

                let config = MLModelConfiguration()
                // .cpuAndNeuralEngine causes Espresso to mmap weight.bin into the EIR
                // ANE plan at inference time, exhausting virtual memory on iPhone 11
                // (ENOMEM / error 12). CPU-only avoids the EIR mmap path entirely.
                config.computeUnits = .cpuOnly

                print("[LocalLLM] Loading model targeting CPU only...")
                self.model = try await MLModel.load(contentsOf: url, configuration: config)

                if #available(iOS 17.0, *), let model = self.model {
                    if !model.modelDescription.stateDescriptionsByName.isEmpty {
                        self.mlState = model.makeState()
                        print("[LocalLLM] Stateful model detected. Initialized MLState.")
                    } else {
                        print("[LocalLLM] Model is not stateful. Running full-context inference.")
                    }
                }

                // Log actual input/output shapes for debugging
                if let model = self.model {
                    print("[LocalLLM] Inputs:")
                    for (name, desc) in model.modelDescription.inputDescriptionsByName {
                        let shape = desc.multiArrayConstraint?.shape ?? []
                        print("  \(name): \(shape)")
                    }
                    print("[LocalLLM] Outputs:")
                    for (name, desc) in model.modelDescription.outputDescriptionsByName {
                        let shape = desc.multiArrayConstraint?.shape ?? []
                        print("  \(name): \(shape)")
                    }
                }

                print("[LocalLLM] Model loaded successfully.")
            }
            self.loadTask = t
            return t
        }
        try await task.value
    }

    /// Starts generating text based on the provided prompt.
    /// The model has flexible input [1, seq_len] with no KV cache, so we re-feed
    /// the full accumulated token sequence every step. Cap at 25 tokens to keep
    /// latency tolerable on CPU (each step re-processes the growing context).
    func generate(prompt: String, maxTokens: Int = 25) async {
        guard let model = self.model else {
            delegate?.localLLM(didFailWithError: LLMError.initializationFailed)
            return
        }

        isGenerating = true
        var currentText = ""

        // Full-context inference re-processes the entire sequence every step (O(N²)).
        // Without a KV cache this becomes infeasibly slow and memory-intensive for
        // long prompts on iPhone 11. Cap at 128 tokens — keep the tail so the most
        // recent user turn is always included.
        let maxContextTokens = 128
        let rawTokens = tokenize(text: prompt)
        var allTokens: [Int32] =
            rawTokens.count > maxContextTokens
            ? Array(rawTokens.suffix(maxContextTokens))
            : rawTokens
        print(
            "[LocalLLM] Generating: \(rawTokens.count) prompt tokens → capped at \(allTokens.count), max \(maxTokens) new"
        )

        do {
            for step in 0..<maxTokens {
                guard isGenerating else { break }

                let seqLen = allTokens.count

                // Feed the entire accumulated sequence each step.
                // Without a KV cache the model has no memory between calls, so
                // single-token-at-a-time inference produces incoherent output.
                let inputArray = try MLMultiArray(
                    shape: [1, NSNumber(value: seqLen)], dataType: .int32)
                for (i, token) in allTokens.enumerated() {
                    inputArray[i] = NSNumber(value: token)
                }

                // Lower-triangular causal mask: Float32 [1, 1, seqLen, seqLen].
                // 0.0 = attend, -10000.0 = masked future position.
                // The model spec requires Float32 (not Float16) for this input.
                let causalMask = try MLMultiArray(
                    shape: [1, 1, NSNumber(value: seqLen), NSNumber(value: seqLen)],
                    dataType: .float32)
                for i in 0..<seqLen {
                    for j in 0..<seqLen {
                        causalMask[i * seqLen + j] = (j <= i) ? 0.0 : -10000.0
                    }
                }

                let input = try MLDictionaryFeatureProvider(dictionary: [
                    "inputIds": inputArray,
                    "causalMask": causalMask,
                ])

                let prediction: MLFeatureProvider
                if #available(iOS 17.0, *), let state = mlState {
                    prediction = try await model.prediction(from: input, using: state)
                } else {
                    prediction = try await model.prediction(from: input)
                }

                guard let logits = prediction.featureValue(for: "logits")?.multiArrayValue else {
                    throw LLMError.inferenceFailed
                }

                // Extract next token from the LAST position's logits.
                // Previously argmax over the flat array — wrong when seqLen > 1
                // because it would scan all positions, not just the last one.
                let vocabSize = logits.shape.last!.intValue
                let nextTokenID = argmaxLastPosition(
                    logits: logits, seqLen: seqLen, vocabSize: vocabSize)

                if step == 0 {
                    print(
                        "[LocalLLM] First generated token: \(nextTokenID), vocabSize: \(vocabSize)")
                }

                if eosTokens.contains(nextTokenID) {
                    print("[LocalLLM] EOS at step \(step)")
                    break
                }

                allTokens.append(nextTokenID)
                let decodedToken = decode(tokenID: nextTokenID)
                currentText += decodedToken

                // await MainActor.run suspends the task until the callback fires on the
                // main thread — ensuring speakChunk is called before the next prediction
                // starts. DispatchQueue.main.async only queues the block and returns
                // immediately, so all callbacks were batching until generation ended.
                await MainActor.run { [weak self] in
                    self?.delegate?.localLLM(didGenerateToken: decodedToken)
                }
            }

            await MainActor.run { [weak self] in
                self?.delegate?.localLLM(didFinishGeneration: currentText)
            }

        } catch {
            print("[LocalLLM] Inference error: \(error)")
            await MainActor.run { [weak self] in
                self?.delegate?.localLLM(didFailWithError: error)
            }
        }

        isGenerating = false
    }

    func stop() {
        isGenerating = false
    }

    func unloadModel() {
        isGenerating = false
        loadLock.withLock { loadTask = nil }
        model = nil
        tokenizer = nil
        if #available(iOS 17.0, *) { mlState = nil }
        print("[LocalLLM] Model unloaded.")
    }

    // MARK: - Tokenization/Sampling

    private func tokenize(text: String) -> [Int32] {
        guard let tokenizer = self.tokenizer else {
            print("[LocalLLM] Warning: Tokenizer not loaded, using fallback.")
            return [1]
        }
        let tokens = tokenizer.encode(text: text)
        return tokens.map { Int32($0) }
    }

    private func decode(tokenID: Int32) -> String {
        guard let tokenizer = self.tokenizer else { return "" }
        return tokenizer.decode(tokens: [Int(tokenID)], skipSpecialTokens: true)
    }

    /// Argmax over the vocabulary at the last sequence position.
    private func argmaxLastPosition(logits: MLMultiArray, seqLen: Int, vocabSize: Int) -> Int32 {
        let pointer = logits.dataPointer.bindMemory(to: Float.self, capacity: logits.count)
        let offset = (seqLen - 1) * vocabSize

        var maxVal: Float = -Float.greatestFiniteMagnitude
        var maxIdx: Int32 = 0

        for i in 0..<vocabSize {
            let val = pointer[offset + i]
            if val > maxVal {
                maxVal = val
                maxIdx = Int32(i)
            }
        }
        return maxIdx
    }
}
