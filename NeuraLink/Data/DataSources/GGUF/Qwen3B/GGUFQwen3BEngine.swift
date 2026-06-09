//
//  GGUFQwen3BEngine.swift
//  NeuraLink
//
//  LLMEngineProtocol implementation for Qwen-2.5-3B-Instruct.
//  Targets the 6 GB tier (iPhone 14 / 15 base / Plus).
//
//  Created by Dedicatus on 18/05/2026.
//

import Foundation

final class GGUFQwen3BEngine: NSObject, @unchecked Sendable, LLMEngineProtocol {

    // MARK: - Singleton

    static let shared = GGUFQwen3BEngine()

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
                guard let url = GGUFQwen3BModelAccess.modelURL() else {
                    throw LLMError.modelNotFound
                }
                nlLog("[GGUFQwen3B] Loading \(url.lastPathComponent)…", level: .info)

                let loaded: LlamaBridge = try await withCheckedThrowingContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let profile = LLMRuntimeProfile.resolve(for: .qwen3b)
                        if let b = LlamaBridge(
                            modelPath: url.path,
                            contextLength: profile.contextLength,
                            threads: profile.threads,
                            gpuLayers: profile.gpuLayers,
                            kType: profile.kType,
                            vType: profile.vType,
                            flashAttn: profile.flashAttn,
                            pldN: profile.pldN,
                            pldNDraft: profile.pldNDraft
                        ) {
                            cont.resume(returning: b)
                        } else {
                            cont.resume(throwing: LLMError.initializationFailed)
                        }
                    }
                }

                self.bridge   = loaded
                self.isLoaded = true
                nlLog("[GGUFQwen3B] Ready. llama.cpp \(loaded.version)", level: .info)
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
        nlLog("[GGUFQwen3B] Unloaded.", level: .info)
    }

    func stop() {
        bridge?.cancel()
    }

    func applyChatTemplate(messages: [LLMChatMessage]) -> String? {
        bridge?.applyChatTemplate(messages: messages)
    }
}
