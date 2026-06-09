//
//  GGUFLlamaEngine.swift
//  NeuraLink
//
//  Drop-in replacement for LocalLLMEngine that uses llama.cpp via Metal GPU.
//  Conforms to LLMEngineProtocol — LocalLLMManager.makeEngine() returns this
//  when the user selects the Llama-3.2-1B model configuration.
//
//  Responsibilities (this file):
//    - Protocol conformance surface
//    - Model loading / unloading lifecycle
//    - Shared singleton
//
//  See GGUFLlamaEngine+Generate.swift for the token generation loop.
//
//  Created by Dedicatus on 29/04/2026.
//

import Foundation

final class GGUFLlamaEngine: NSObject, @unchecked Sendable, LLMEngineProtocol {

    // MARK: - Singleton

    static let shared = GGUFLlamaEngine()

    // MARK: - Protocol properties

    weak var delegate: LocalLLMEngineDelegate?
    private(set) var isLoaded = false

    // MARK: - Internal state

    internal var bridge: LlamaBridge?
    internal var loadTask: Task<Void, Error>?
    internal let loadLock = NSLock()

    // Prevents concurrent llama_decode calls on the same context.
    // llama.cpp is NOT thread-safe: two simultaneous decode calls corrupt
    // internal buffers and crash with GGML_ASSERT(buffer) failed.
    internal let generationLock = NSLock()
    internal var _isGenerating = false

    // Held for the duration of any llama.cpp work (generate OR prefill) so
    // background warmup never collides with the foreground generate call.
    // Generate blocks on this lock; prefill `try()`s and skips on contention.
    internal let bridgeLock = NSLock()

    // MARK: - Init

    override private init() { super.init() }

    // MARK: - LLMEngineProtocol — load / unload

    func loadModel() async throws {
        if isLoaded { return }

        let task: Task<Void, Error> = loadLock.withLock {
            if let existing = loadTask { return existing }
            let t = Task<Void, Error> {
                guard let url = GGUFModelAccess.modelURL() else {
                    throw LLMError.modelNotFound
                }
                nlLog("[GGUFEngine] Loading \(url.lastPathComponent)…", level: .info)

                // llama_bridge_create is synchronous and potentially slow (~3-5 s).
                // Run on a dedicated thread so the Swift cooperative pool stays free.
                let loaded: LlamaBridge = try await withCheckedThrowingContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        // 4 GB devices (iPhone 11/12/13): A13 has 2 performance
                        // cores + 4 efficiency cores. Pinning to 2 threads keeps
                        // work on the P-cores; spilling to E-cores at threads=4
                        // measurably hurts decode tok/s on CPU-only paths.
                        // n_ctx=1024 (halved from 2048): the 3-tier hierarchy
                        // compacts older turns into RAG facts well before we
                        // approach the limit on a 1B; halving the KV cache
                        // saves ~50 MB of RSS and shortens per-token attention
                        // cost (linear in cached length). Must match the
                        // `nCtx` passed to `fitToBudget` in the hierarchy.
                        let profile = LLMRuntimeProfile.resolve(for: .llama1b)
                        if let b = LlamaBridge(
                            modelPath: url.path,
                            contextLength: profile.contextLength,
                            threads: profile.threads,
                            gpuLayers: profile.gpuLayers,
                            kType: profile.kType,
                            vType: profile.vType,
                            flashAttn: profile.flashAttn,
                            pldN: profile.pldN,
                            pldNDraft: profile.pldNDraft,
                            label: "Llama-1B"
                        ) {
                            cont.resume(returning: b)
                        } else {
                            cont.resume(throwing: LLMError.initializationFailed)
                        }
                    }
                }

                self.bridge   = loaded
                self.isLoaded = true
                nlLog("[GGUFEngine] Ready. llama.cpp \(loaded.version)", level: .info)
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
        nlLog("[GGUFEngine] Unloaded.", level: .info)
    }

    func stop() {
        bridge?.cancel()
    }

    func applyChatTemplate(messages: [LLMChatMessage]) -> String? {
        bridge?.applyChatTemplate(messages: messages)
    }
}
