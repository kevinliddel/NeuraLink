//
//  GGUFSpeculativeEngine.swift
//  NeuraLink
//
//  LLMEngineProtocol implementation that runs Qwen-2.5-7B (target)
//  accelerated by Qwen-2.5-1.5B (draft) via speculative decoding.
//  Typically 2–3× decode throughput vs plain Qwen-2.5-7B.
//
//  Activates only when:
//    - selected configuration is `.qwen7b`, AND
//    - both Qwen-2.5-7B and the 1.5B draft (`.qwen2b`) are downloaded.
//  Otherwise `LocalLLMManager.makeEngine` falls back to `GGUFQwen7BEngine`.
//
//  Created by Dedicatus on 19/05/2026.
//

import Foundation

final class GGUFSpeculativeEngine: NSObject, @unchecked Sendable, LLMEngineProtocol {

    // MARK: - Singleton

    static let shared = GGUFSpeculativeEngine()

    // MARK: - Protocol properties

    weak var delegate: LocalLLMEngineDelegate?
    private(set) var isLoaded = false

    // MARK: - Internal state

    internal var bridge: LlamaSpeculativeBridge?
    internal var loadTask: Task<Void, Error>?
    internal let loadLock = NSLock()

    // Same concurrency guard as the single-model engines: llama.cpp is not
    // thread-safe so we serialise generate calls.
    internal let generationLock = NSLock()
    internal var _isGenerating = false

    // MARK: - Draft-window auto-tuning (M3)

    /// UserDefaults key persisting the tuned speculative draft window so the
    /// next session starts from the converged value instead of re-learning.
    static let nDraftDefaultsKey = "nl.spec.nDraft"

    /// Bounds for the tuned window: below 2 speculative decoding stops paying
    /// for itself; above 8 the batch-verify cost eats the free-token gains.
    static let nDraftRange: ClosedRange<Int32> = 2...8

    /// Recompute the acceptance rate after this many generation turns.
    static let tuneInterval = 5

    /// Mutated only from `generate`/`tuneDraftWindow`, which the
    /// `_isGenerating` flag already serialises.
    internal var currentNDraft: Int32 = 4
    internal var tuneTurns = 0
    internal var tuneDrafted: Int32 = 0
    internal var tuneAccepted: Int32 = 0

    /// The draft window persisted by a previous session's tuning, clamped to
    /// `nDraftRange`, or the default 4 when never tuned.
    static func persistedNDraft() -> Int32 {
        let stored = UserDefaults.standard.integer(forKey: nDraftDefaultsKey)
        guard stored != 0 else { return 4 }
        return min(max(Int32(stored), nDraftRange.lowerBound), nDraftRange.upperBound)
    }

    // MARK: - Availability gate

    /// True when both the 7B target and the 1.5B draft are on disk, the
    /// gate `LocalLLMManager.makeEngine` consults before routing here.
    static var canActivate: Bool {
        GGUFQwen7BModelAccess.isDownloaded && GGUFQwenModelAccess.isDownloaded
    }

    // MARK: - Init

    override private init() { super.init() }

    // MARK: - LLMEngineProtocol — load / unload

    func loadModel() async throws {
        if isLoaded { return }

        let task: Task<Void, Error> = loadLock.withLock {
            if let existing = loadTask { return existing }
            let t = Task<Void, Error> {
                guard let targetURL = GGUFQwen7BModelAccess.modelURL(),
                      let draftURL  = GGUFQwenModelAccess.modelURL() else {
                    throw LLMError.modelNotFound
                }
                nlLog("[GGUFSpec] Loading target=\(targetURL.lastPathComponent), draft=\(draftURL.lastPathComponent)…", level: .info)

                // Start from the draft window tuned in a previous session
                // (acceptance-rate auto-tuning, see tuneDraftWindow()).
                let nDraft = Self.persistedNDraft()

                let loaded: LlamaSpeculativeBridge = try await withCheckedThrowingContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        // Target tier params (KV / flash-attn / threads / ctx)
                        // come from the shared 8 GB profile; they apply to both
                        // the target and draft contexts. `nDraft` is the
                        // speculative draft-model depth, distinct from PLD and
                        // kept local to this engine.
                        let profile = LLMRuntimeProfile.resolve(for: .qwen7b)
                        if let b = LlamaSpeculativeBridge(
                            targetPath: targetURL.path,
                            draftPath: draftURL.path,
                            contextLength: profile.contextLength,
                            threads: profile.threads,
                            gpuLayers: profile.gpuLayers,
                            nDraft: nDraft,
                            kType: profile.kType,
                            vType: profile.vType,
                            flashAttn: profile.flashAttn
                        ) {
                            cont.resume(returning: b)
                        } else {
                            cont.resume(throwing: LLMError.initializationFailed)
                        }
                    }
                }

                self.bridge        = loaded
                self.currentNDraft = nDraft
                self.isLoaded      = true
                nlLog("[GGUFSpec] Ready (1.5B draft + 7B target).", level: .info)
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
        nlLog("[GGUFSpec] Unloaded.", level: .info)
    }

    func stop() {
        bridge?.cancel()
    }

    func applyChatTemplate(messages: [LLMChatMessage]) -> String? {
        bridge?.applyChatTemplate(messages: messages)
    }
}
