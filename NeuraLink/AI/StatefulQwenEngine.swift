//
//  StatefulQwenEngine.swift
//  NeuraLink
//
//  Drives the mlboydaisuke/qwen3-vl-2b-stateful-coreml chunked model.
//  Text-only inference path (vision encoder not loaded).
//
//  Architecture:
//    4 body chunks (7 transformer layers each) + lm-head
//    Each body chunk carries MLState "kv_cache_0" — true O(1) decode.
//    Token embedding is a raw fp16 table mmapped from embed_weight.bin.
//
//  Requirements: iOS 18+ (MLState + ct.target.iOS18 deployment target)
//

import CoreML
import Darwin
import Foundation
import Tokenizers

@available(iOS 18.0, *)
final class StatefulQwenEngine: NSObject, @unchecked Sendable, LLMEngineProtocol {
    static let shared = StatefulQwenEngine()

    weak var delegate: LocalLLMEngineDelegate?

    // 4 body chunks (chunk_0 … chunk_3) + lm-head
    private var bodyChunks: [MLModel] = []
    private var headModel: MLModel?

    // One KV-cache state per body chunk; fresh each generation
    private var states: [MLState] = []

    // Memory-mapped fp16 embed table: vocabSize × hiddenSize × 2 bytes
    private var embedPtr: UnsafeMutableRawPointer?
    private var embedMapSize = 0
    private var embedFd: Int32 = -1

    private var tokenizer: Tokenizer?
    private var isGenerating = false

    // Reusable inference arrays (pre-allocated once per generate() call)
    private var cosArr: MLMultiArray?
    private var sinArr: MLMultiArray?
    private var maskArr: MLMultiArray?
    private var posArr: MLMultiArray?

    // Architecture constants (Qwen3-VL 2B)
    private let numChunks = 4
    private let vocabSize = 151936
    private let hiddenSize = 2048
    private let halfDim = 64        // head_dim(128) / 2
    private let ropeTheta = 5_000_000.0
    private let maxSeqLen = 2048

    // EOS: <|endoftext|>=151643, <|im_start|>=151644, <|im_end|>=151645
    private let eosTokens: Set<Int32> = [151643, 151644, 151645]

    var isLoaded: Bool { !bodyChunks.isEmpty && headModel != nil }

    // Load-task guard — same pattern as LocalLLMEngine
    private var loadTask: Task<Void, Error>?
    private let loadLock = NSLock()

    override private init() { super.init() }

    deinit {
        if let ptr = embedPtr { munmap(ptr, embedMapSize) }
        if embedFd >= 0 { close(embedFd) }
    }

    // MARK: - Load

    func loadModel() async throws {
        if isLoaded { return }

        let task: Task<Void, Error> = loadLock.withLock {
            if let existing = loadTask { return existing }
            let t = Task<Void, Error> { [self] in
                print("[QwenVL] Loading tokenizer…")
                self.tokenizer = try await AutoTokenizer.from(
                    pretrained: "Qwen/Qwen3-VL-2B-Instruct")
                print("[QwenVL] Tokenizer ready.")

                let cfg = MLModelConfiguration()
                cfg.computeUnits = .cpuAndNeuralEngine

                var loaded: [MLModel] = []
                for i in 0..<self.numChunks {
                    guard let url = Bundle.main.url(
                        forResource: "chunk_\(i)", withExtension: "mlmodelc")
                    else { throw LLMError.modelNotFound }
                    print("[QwenVL] Loading chunk_\(i)…")
                    loaded.append(try await MLModel.load(contentsOf: url, configuration: cfg))
                }

                guard let headURL = Bundle.main.url(
                    forResource: "chunk_head", withExtension: "mlmodelc")
                else { throw LLMError.modelNotFound }
                print("[QwenVL] Loading chunk_head…")
                let head = try await MLModel.load(contentsOf: headURL, configuration: cfg)

                guard let embedURL = Bundle.main.url(
                    forResource: "embed_weight", withExtension: "bin")
                else { throw LLMError.modelNotFound }

                let fd = open(embedURL.path, O_RDONLY)
                guard fd >= 0 else { throw LLMError.initializationFailed }
                let mapSize = self.vocabSize * self.hiddenSize * 2  // fp16 bytes
                let raw = mmap(nil, mapSize, PROT_READ, MAP_PRIVATE, fd, 0)
                guard UInt(bitPattern: raw) != UInt.max else {
                    close(fd)
                    throw LLMError.initializationFailed
                }
                madvise(raw, mapSize, MADV_RANDOM)

                self.bodyChunks = loaded
                self.headModel = head
                self.embedFd = fd
                self.embedPtr = raw
                self.embedMapSize = mapSize
                print("[QwenVL] Ready — embed table \(mapSize / 1_048_576) MB mmap'd.")
            }
            self.loadTask = t
            return t
        }
        try await task.value
    }

    // MARK: - Generate

    func generate(prompt: String, maxTokens: Int = 128) async {
        guard isLoaded, let tok = tokenizer else {
            delegate?.localLLM(didFailWithError: LLMError.initializationFailed)
            return
        }

        // Fresh KV cache for each turn
        states = bodyChunks.map { $0.makeState() }

        // Pre-allocate reusable arrays for the hot loop
        do {
            cosArr  = try MLMultiArray(shape: [1, 1, 128], dataType: .float16)
            sinArr  = try MLMultiArray(shape: [1, 1, 128], dataType: .float16)
            maskArr = try MLMultiArray(
                shape: [1, 1, 1, NSNumber(value: maxSeqLen)], dataType: .float16)
            posArr  = try MLMultiArray(shape: [1], dataType: .int32)

            // Mask starts fully blocked; positions are unmasked incrementally
            let mPtr = maskArr!.dataPointer.bindMemory(to: Float16.self, capacity: maxSeqLen)
            for i in 0..<maxSeqLen { mPtr[i] = Float16(-10000.0) }
        } catch {
            delegate?.localLLM(didFailWithError: error)
            return
        }

        isGenerating = true
        var currentText = ""

        let rawTokens = tok.encode(text: prompt).map { Int32($0) }
        let maxCtx = maxSeqLen - maxTokens - 1
        let inputTokens = rawTokens.count > maxCtx
            ? Array(rawTokens.suffix(maxCtx)) : rawTokens

        print("[QwenVL] Prefilling \(inputTokens.count) tokens, max \(maxTokens) new")

        do {
            var pos = 0

            // Prefill: all tokens except the last — update KV cache, skip head
            for token in inputTokens.dropLast() {
                guard isGenerating else { break }
                try await throughBody(token: token, pos: pos)
                pos += 1
            }

            // Last prefill token → first decode token (body + head)
            guard isGenerating, let lastPrefill = inputTokens.last else {
                await MainActor.run { [weak self] in
                    self?.delegate?.localLLM(didFinishGeneration: currentText)
                }
                isGenerating = false
                return
            }

            var nextToken = try await throughBodyAndHead(token: lastPrefill, pos: pos)
            pos += 1

            // Decode loop
            for step in 0..<maxTokens {
                guard isGenerating else { break }
                if eosTokens.contains(nextToken) {
                    print("[QwenVL] EOS at decode step \(step)")
                    break
                }

                let decoded = tok.decode(tokens: [Int(nextToken)], skipSpecialTokens: true)
                if !decoded.isEmpty {
                    currentText += decoded
                    await MainActor.run { [weak self] in
                        self?.delegate?.localLLM(didGenerateToken: decoded)
                    }
                }

                nextToken = try await throughBodyAndHead(token: nextToken, pos: pos)
                pos += 1
            }

            await MainActor.run { [weak self] in
                self?.delegate?.localLLM(didFinishGeneration: currentText)
            }

        } catch {
            print("[QwenVL] Inference error: \(error)")
            await MainActor.run { [weak self] in
                self?.delegate?.localLLM(didFailWithError: error)
            }
        }

        isGenerating = false
    }

    func stop() { isGenerating = false }

    // MARK: - Inference core

    /// Runs the token through all 4 body chunks (updates KV cache), discards hidden.
    private func throughBody(token: Int32, pos: Int) async throws {
        _ = try await runBodyChunks(token: token, pos: pos)
    }

    /// Runs the token through 4 body chunks then the lm-head; returns next token ID.
    private func throughBodyAndHead(token: Int32, pos: Int) async throws -> Int32 {
        let hiddenFV = try await runBodyChunks(token: token, pos: pos)

        let headProvider = try MLDictionaryFeatureProvider(
            dictionary: ["hidden_in": hiddenFV])
        let headOut = try await headModel!.prediction(from: headProvider)
        let arr = headOut.featureValue(for: "next_token")!.multiArrayValue!
        return arr.dataPointer.bindMemory(to: Int32.self, capacity: 1).pointee
    }

    private func runBodyChunks(token: Int32, pos: Int) async throws -> MLFeatureValue {
        updateRoPE(pos: pos)
        updateMask(pos: pos)
        posArr![0] = NSNumber(value: pos)

        var hiddenFV = try embed(token: token)

        for (i, chunk) in bodyChunks.enumerated() {
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "hidden_in":   hiddenFV,
                "cos":         MLFeatureValue(multiArray: cosArr!),
                "sin":         MLFeatureValue(multiArray: sinArr!),
                "causal_mask": MLFeatureValue(multiArray: maskArr!),
                "current_pos": MLFeatureValue(multiArray: posArr!),
            ])
            let out = try await chunk.prediction(from: provider, using: states[i])
            hiddenFV = out.featureValue(for: "hidden")!
        }

        return hiddenFV
    }

    // MARK: - Array helpers

    private func embed(token: Int32) throws -> MLFeatureValue {
        guard let ptr = embedPtr else { throw LLMError.initializationFailed }
        let hidden = try MLMultiArray(
            shape: [1, 1, NSNumber(value: hiddenSize)], dataType: .float16)
        let byteOffset = Int(token) * hiddenSize * MemoryLayout<Float16>.size
        memcpy(hidden.dataPointer, ptr.advanced(by: byteOffset),
               hiddenSize * MemoryLayout<Float16>.size)
        return MLFeatureValue(multiArray: hidden)
    }

    /// Fills cosArr/sinArr for 1-D RoPE at sequence position `pos`.
    /// Format: [cos_0, cos_1, …, cos_63, cos_0, cos_1, …, cos_63] (half-dim duplication).
    private func updateRoPE(pos: Int) {
        guard let cos = cosArr, let sin = sinArr else { return }
        let cPtr = cos.dataPointer.bindMemory(to: Float16.self, capacity: 128)
        let sPtr = sin.dataPointer.bindMemory(to: Float16.self, capacity: 128)
        for i in 0..<halfDim {
            let freq = Double(pos) / pow(ropeTheta, Double(2 * i) / 128.0)
            let c = Float16(Darwin.cos(freq))
            let s = Float16(Darwin.sin(freq))
            cPtr[i] = c;         cPtr[i + halfDim] = c
            sPtr[i] = s;         sPtr[i + halfDim] = s
        }
    }

    /// Incrementally unmasks position `pos` — O(1) per step instead of O(N).
    private func updateMask(pos: Int) {
        guard let mask = maskArr else { return }
        mask.dataPointer.bindMemory(to: Float16.self, capacity: maxSeqLen)[pos] = 0.0
    }
}
