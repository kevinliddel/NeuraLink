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
                print("[GGUFJapaneseLlama] Loading \(url.lastPathComponent)…")

                let loaded: LlamaBridge = try await withCheckedThrowingContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
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
                print("[GGUFJapaneseLlama] Ready. llama.cpp \(loaded.version)")
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
        print("[GGUFJapaneseLlama] Unloaded.")
    }

    func stop() {
        bridge?.cancel()
    }
}
