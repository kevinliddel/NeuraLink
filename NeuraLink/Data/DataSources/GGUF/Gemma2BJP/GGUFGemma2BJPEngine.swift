//
//  GGUFGemma2BJPEngine.swift
//  NeuraLink
//
//  LLMEngineProtocol implementation for the Japanese local model
//  (grapevine-AI/gemma-2-2b-jpn-it-gguf — Google's Gemma 2 2B, JP-tuned).
//  Uses the same llama.cpp bridge and Metal GPU path as GGUFLlamaEngine —
//  only the model file differs. The Gemma chat template is read from the
//  GGUF metadata by LlamaBridge.applyChatTemplate, so no prompt-format
//  changes are needed despite the architecture switch.
//
//  See GGUFGemma2BJPEngine+Generate.swift for the token generation loop.
//
//  Created by Dedicatus on 06/05/2026.
//

import Foundation

final class GGUFGemma2BJPEngine: NSObject, @unchecked Sendable, LLMEngineProtocol {

    // MARK: - Singleton

    static let shared = GGUFGemma2BJPEngine()

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
                guard let url = GGUFGemma2BJPModelAccess.modelURL() else {
                    throw LLMError.modelNotFound
                }
                nlLog("[GGUFGemma2BJP] Loading \(url.lastPathComponent)…", level: .info)

                let loaded: LlamaBridge = try await withCheckedThrowingContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        // 4 GB devices (iPhone 11/12/13): see GGUFLlamaEngine
                        // for the threads=2 and n_ctx=1024 rationale. NOTE:
                        // the JP slot now hosts LLM-jp-3 1.8B at Q3_K_M
                        // (~0.96 GB), loaded non-mmap so it stays resident (the
                        // gemma 2B streamed from flash on this tier). The
                        // conservative 1024-ctx / 2-thread profile is kept to
                        // hold the footprint down; non-mmap means peak RSS = the
                        // full model size, so jetsam headroom is tight here.
                        // PLD tuned for Japanese: n=2, nDraft=3. The default
                        // n=3, nDraft=5 was calibrated on English where
                        // 3-token n-grams repeat constantly ("I think the",
                        // user names, command prefixes). Japanese subword
                        // tokens repeat less often at 3-grams, so the
                        // default wastes batch-decode cycles on misses.
                        // The `pld=hits/rounds(%)` field in `[Bench]`
                        // confirms whether this pays off.
                        let profile = LLMRuntimeProfile.resolve(for: .japaneseGemma2b)
                        if let b = LlamaBridge(
                            modelPath: url.path,
                            contextLength: profile.contextLength,
                            threads: profile.threads,
                            gpuLayers: profile.gpuLayers,
                            kType: profile.kType,
                            vType: profile.vType,
                            flashAttn: profile.flashAttn,
                            // PLD disabled: device `[Bench]` showed pld=0/8
                            // (0% hits) on short JP replies — JP subword
                            // n-grams rarely repeat, so every draft batch is
                            // wasted decode work, which hurts most under
                            // thermal throttling. Re-enable (promptLookup:true
                            // + profile.pldN/NDraft) only if a measured hit
                            // rate justifies it.
                            promptLookup: false,
                            pldN: profile.pldN,
                            pldNDraft: profile.pldNDraft,
                            label: "LLM-jp-3-1.8B"
                        ) {
                            cont.resume(returning: b)
                        } else {
                            cont.resume(throwing: LLMError.initializationFailed)
                        }
                    }
                }

                self.bridge   = loaded
                self.isLoaded = true
                nlLog("[GGUFGemma2BJP] Ready. llama.cpp \(loaded.version)", level: .info)
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
        nlLog("[GGUFGemma2BJP] Unloaded.", level: .info)
    }

    func stop() {
        bridge?.cancel()
    }

    func applyChatTemplate(messages: [LLMChatMessage]) -> String? {
        bridge?.applyChatTemplate(messages: messages)
    }
}
