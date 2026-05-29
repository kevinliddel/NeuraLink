//
//  GGUFLlamaEngine+Generate.swift
//  NeuraLink
//
//  Token generation loop for GGUFLlamaEngine.
//  Runs llama.cpp inference on a GCD thread so the Swift cooperative pool
//  is never blocked during a potentially long-running synchronous C call.
//
//  Created by Dedicatus on 29/04/2026.
//

import Foundation

extension GGUFLlamaEngine {

    // MARK: - LLMEngineProtocol — generate

    func generate(prompt: String, maxTokens: Int) async {
        guard isLoaded, let bridge else {
            delegate?.localLLM(didFailWithError: LLMError.initializationFailed)
            return
        }

        // Reject concurrent calls — llama.cpp crashes if two generate calls run simultaneously.
        generationLock.lock()
        let alreadyRunning = _isGenerating
        if !alreadyRunning { _isGenerating = true }
        generationLock.unlock()

        guard !alreadyRunning else {
            nlLog("[GGUFEngine] Dropped generate — already in progress", level: .info)
            Task { @MainActor [weak self] in
                self?.delegate?.localLLM(didFinishGeneration: "")
            }
            return
        }

        defer {
            generationLock.lock()
            _isGenerating = false
            generationLock.unlock()
        }

        var fullText = ""

        // llama_bridge_generate blocks the calling thread.
        // We suspend the async context and resume it in the on_finish callback.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Dispatch to a background thread — never call blocking C from the cooperative pool.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }

                // Block until any in-flight prefill warmup finishes. The
                // prefill side uses try() and steps aside on contention, so
                // this lock only ever waits on a recently-kicked warmup —
                // never another generate.
                self.bridgeLock.lock()
                defer { self.bridgeLock.unlock() }

                bridge.generate(
                    prompt: prompt,
                    maxNewTokens: Int32(maxTokens),
                    onToken: { [weak self] token in
                        guard let self else { return false }
                        fullText += token
                        Task { @MainActor [weak self] in
                            self?.delegate?.localLLM(didGenerateToken: token)
                        }
                        return true   // returning false would stop generation
                    },
                    onFinish: { [weak self] in
                        Task { @MainActor [weak self] in
                            self?.delegate?.localLLM(didFinishGeneration: fullText)
                        }
                        continuation.resume()
                    }
                )
            }
        }
    }

    // MARK: - LLMEngineProtocol — prefill (background warmup)

    func prefill(messages: [LLMChatMessage]) async {
        guard isLoaded, let bridge else { return }
        guard let prompt = bridge.applyChatTemplate(
            messages: messages, addGenerationPrompt: false
        ) else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                // try() so the warmup steps aside if a generate is already
                // running (or about to run). Never wait — a stale warmup
                // would just delay the real reply.
                guard self.bridgeLock.try() else {
                    continuation.resume()
                    return
                }
                defer { self.bridgeLock.unlock() }
                bridge.prefill(prompt: prompt)
                continuation.resume()
            }
        }
    }

    // MARK: - LLMEngineProtocol — KV cache persistence

    func saveKVCache(to path: String) async -> Bool {
        guard isLoaded, let bridge else { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { continuation.resume(returning: false); return }
                // try() — never wait. If a generate is in progress, the
                // persist attempt simply skips this turn; we'll retry on
                // the next warmup completion.
                guard self.bridgeLock.try() else {
                    nlLog("[KVCache] Save skipped — bridge busy; will retry on next warmup",
                          level: .info)
                    continuation.resume(returning: false); return
                }
                defer { self.bridgeLock.unlock() }
                let bytes = bridge.saveKVState(path: path)
                if bytes > 0 {
                    nlLog("[KVCache] Saved \(bridge.kvTokenCount) tokens, \(bytes) bytes to \(URL(fileURLWithPath: path).lastPathComponent)", level: .info)
                } else {
                    nlLog("[KVCache] Save returned 0 bytes — kvTokenCount=\(bridge.kvTokenCount)",
                          level: .warning)
                }
                continuation.resume(returning: bytes > 0)
            }
        }
    }

    func loadKVCache(from path: String) async -> Int {
        guard isLoaded, let bridge else { return 0 }
        guard FileManager.default.fileExists(atPath: path) else { return 0 }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { continuation.resume(returning: 0); return }
                // Use blocking lock() — restore is meant to happen during
                // model load when nothing else is touching the bridge yet,
                // but block defensively in case warmup raced us here.
                self.bridgeLock.lock()
                defer { self.bridgeLock.unlock() }
                let restored = bridge.loadKVState(path: path)
                if restored > 0 {
                    nlLog("[KVCache] Restored \(restored) tokens from \(URL(fileURLWithPath: path).lastPathComponent)", level: .info)
                }
                continuation.resume(returning: restored)
            }
        }
    }
}
