//
//  GGUFQwen7BEngine.swift
//  NeuraLink
//
//  LLMEngineProtocol implementation for Qwen-2.5-7B-Instruct.
//  Targets the 8 GB tier (iPhone 15 Pro / 15 Pro Max / 16 family).
//
//  Created by Dedicatus on 18/05/2026.
//

import Foundation

final class GGUFQwen7BEngine: NSObject, @unchecked Sendable, LLMEngineProtocol {

    // MARK: - Singleton

    static let shared = GGUFQwen7BEngine()

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

    // MARK: - Init

    override private init() { super.init() }

    // MARK: - LLMEngineProtocol — load / unload

    func loadModel() async throws {
        if isLoaded { return }

        let task: Task<Void, Error> = loadLock.withLock {
            if let existing = loadTask { return existing }
            let t = Task<Void, Error> {
                guard let url = GGUFQwen7BModelAccess.modelURL() else {
                    throw LLMError.modelNotFound
                }
                nlLog("[GGUFQwen7B] Loading \(url.lastPathComponent)…", level: .info)

                let loaded: LlamaBridge = try await withCheckedThrowingContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        if let b = LlamaBridge(
                            modelPath: url.path,
                            contextLength: 2048,
                            threads: 6,
                            gpuLayers: 999
                        ) {
                            cont.resume(returning: b)
                        } else {
                            cont.resume(throwing: LLMError.initializationFailed)
                        }
                    }
                }

                self.bridge   = loaded
                self.isLoaded = true
                nlLog("[GGUFQwen7B] Ready. llama.cpp \(loaded.version)", level: .info)
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
        nlLog("[GGUFQwen7B] Unloaded.", level: .info)
    }

    func stop() {
        bridge?.cancel()
    }

    func applyChatTemplate(messages: [LLMChatMessage]) -> String? {
        bridge?.applyChatTemplate(messages: messages)
    }
}
