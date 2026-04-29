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
                print("[GGUFEngine] Loading \(url.lastPathComponent)…")

                // llama_bridge_create is synchronous and potentially slow (~3-5 s).
                // Run on a dedicated thread so the Swift cooperative pool stays free.
                let loaded: LlamaBridge = try await withCheckedThrowingContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        // 4 GB devices: n_ctx=256, 4 threads, all layers on Metal GPU.
                        if let b = LlamaBridge(
                            modelPath: url.path,
                            contextLength: 256,
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
                print("[GGUFEngine] Ready. llama.cpp \(loaded.version)")
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
        print("[GGUFEngine] Unloaded.")
    }

    func stop() {
        bridge?.cancel()
    }
}
