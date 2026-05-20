//
//  GGUFJapaneseLlamaEngine.swift
//  NeuraLink
//
//  LLMEngineProtocol implementation for the Japanese-oriented Llama-3.2-1B model
//  (grapevine-AI/Llama-3.2-1B-Instruct-GGUF). Uses the same llama.cpp bridge and
//  Metal GPU path as GGUFLlamaEngine — only the model file differs.
//
//  See GGUFJapaneseLlamaEngine+Generate.swift for the token generation loop.
//
//  Created by Dedicatus on 06/05/2026.
//

import Foundation

final class GGUFJapaneseLlamaEngine: NSObject, @unchecked Sendable, LLMEngineProtocol {

    // MARK: - Singleton

    static let shared = GGUFJapaneseLlamaEngine()

    // MARK: - Protocol properties

    weak var delegate: LocalLLMEngineDelegate?
    private(set) var isLoaded = false

    // MARK: - Internal state

    internal var bridge: LlamaBridge?
    internal var loadTask: Task<Void, Error>?
    internal let loadLock = NSLock()

    // Same concurrency guard as GGUFLlamaEngine — llama.cpp is NOT thread-safe.
    internal let generationLock = NSLock()
    internal var _isGenerating = false

    // See GGUFLlamaEngine.bridgeLock: serialises prefill warmup against
    // foreground generate so the two never run concurrently on the same ctx.
    internal let bridgeLock = NSLock()

    // MARK: - Init

    override private init() { super.init() }

    // MARK: - LLMEngineProtocol — load / unload

    func loadModel() async throws {
        if isLoaded { return }

        let task: Task<Void, Error> = loadLock.withLock {
            if let existing = loadTask { return existing }
            let t = Task<Void, Error> {
                guard let url = GGUFJapaneseLlamaModelAccess.modelURL() else {
                    throw LLMError.modelNotFound
                }
                nlLog("[GGUFJapaneseLlama] Loading \(url.lastPathComponent)…", level: .info)

                let loaded: LlamaBridge = try await withCheckedThrowingContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        // 4 GB devices (iPhone 11/12/13): see GGUFLlamaEngine
                        // for the threads=2 and n_ctx=1024 rationale.
                        // PLD tuned for Japanese: n=2, nDraft=3. The default
                        // n=3, nDraft=5 was calibrated on English where
                        // 3-token n-grams repeat constantly ("I think the",
                        // user names, command prefixes). Japanese subword
                        // tokens repeat less often at 3-grams, so the
                        // default wastes batch-decode cycles on misses.
                        // The `pld=hits/rounds(%)` field in `[Bench]`
                        // confirms whether this pays off.
                        if let b = LlamaBridge(
                            modelPath: url.path,
                            contextLength: 1024,
                            threads: 2,
                            gpuLayers: 999,
                            pldN: 2,
                            pldNDraft: 3,
                            label: "Llama-1B-JP"
                        ) {
                            cont.resume(returning: b)
                        } else {
                            cont.resume(throwing: LLMError.initializationFailed)
                        }
                    }
                }

                self.bridge   = loaded
                self.isLoaded = true
                nlLog("[GGUFJapaneseLlama] Ready. llama.cpp \(loaded.version)", level: .info)
            }
            self.loadTask = t
            return t
        }

        do {
            try await task.value
        } catch {
            loadLock.withLock { loadTask = nil }
            throw error
        }
    }

    func unloadModel() {
        bridge   = nil
        isLoaded = false
        loadLock.withLock { loadTask = nil }
        nlLog("[GGUFJapaneseLlama] Unloaded.", level: .info)
    }

    func stop() {
        bridge?.cancel()
    }

    func applyChatTemplate(messages: [LLMChatMessage]) -> String? {
        bridge?.applyChatTemplate(messages: messages)
    }
}
