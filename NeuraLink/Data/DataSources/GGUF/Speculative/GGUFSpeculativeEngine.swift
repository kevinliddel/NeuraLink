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

                let loaded: LlamaSpeculativeBridge = try await withCheckedThrowingContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        if let b = LlamaSpeculativeBridge(
                            targetPath: targetURL.path,
                            draftPath: draftURL.path,
                            contextLength: 2048,
                            threads: 6,
                            gpuLayers: 999,
                            nDraft: 4
                        ) {
                            cont.resume(returning: b)
                        } else {
                            cont.resume(throwing: LLMError.initializationFailed)
                        }
                    }
                }

                self.bridge   = loaded
                self.isLoaded = true
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
