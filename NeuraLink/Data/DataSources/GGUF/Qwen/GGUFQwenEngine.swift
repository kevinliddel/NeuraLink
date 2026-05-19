//
//  GGUFQwenEngine.swift
//  NeuraLink
//
//  Drop-in replacement for StatefulQwenEngine that uses llama.cpp via Metal GPU.
//
//  Created by Dedicatus on 29/04/2026.
//

import Foundation

final class GGUFQwenEngine: NSObject, @unchecked Sendable, LLMEngineProtocol {

    static let shared = GGUFQwenEngine()

    weak var delegate: LocalLLMEngineDelegate?
    private(set) var isLoaded = false

    internal var bridge: LlamaBridge?
    internal var loadTask: Task<Void, Error>?
    internal let loadLock = NSLock()

    // Same concurrency guard as GGUFLlamaEngine — see comment there.
    internal let generationLock = NSLock()
    internal var _isGenerating = false

    override private init() { super.init() }

    func loadModel() async throws {
        if isLoaded { return }

        let task: Task<Void, Error> = loadLock.withLock {
            if let existing = loadTask { return existing }
            let t = Task<Void, Error> {
                guard let url = GGUFQwenModelAccess.modelURL() else {
                    throw LLMError.modelNotFound
                }
                nlLog("[GGUFQwen] Loading \(url.lastPathComponent)…", level: .info)

                let loaded: LlamaBridge = try await withCheckedThrowingContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        // Qwen models generally have longer context windows. 
                        // Using 2048 to support slightly longer conversations.
                        if let b = LlamaBridge(
                            modelPath: url.path,
                            contextLength: 2048,
                            threads: 4,
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
                nlLog("[GGUFQwen] Ready. llama.cpp \(loaded.version)", level: .info)
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
        nlLog("[GGUFQwen] Unloaded.", level: .info)
    }

    func stop() {
        bridge?.cancel()
    }

    func applyChatTemplate(messages: [LLMChatMessage]) -> String? {
        bridge?.applyChatTemplate(messages: messages)
    }
}
