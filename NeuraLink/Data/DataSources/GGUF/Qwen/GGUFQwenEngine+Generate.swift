//
//  GGUFQwenEngine+Generate.swift
//  NeuraLink
//
//  Created by Dedicatus on 29/04/2026.
//

import Foundation

extension GGUFQwenEngine {

    func generate(prompt: String, maxTokens: Int) async {
        guard isLoaded, let bridge else {
            delegate?.localLLM(didFailWithError: LLMError.initializationFailed)
            return
        }

        generationLock.lock()
        let alreadyRunning = _isGenerating
        if !alreadyRunning { _isGenerating = true }
        generationLock.unlock()

        guard !alreadyRunning else {
            nlLog("[GGUFQwen] Dropped generate — already in progress", level: .info)
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

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }

                // See GGUFLlamaEngine+Generate for the bridgeLock rationale.
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
                        return true
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
                guard let self else { continuation.resume(); return }
                guard self.bridgeLock.try() else { continuation.resume(); return }
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
                guard self.bridgeLock.try() else {
                    continuation.resume(returning: false); return
                }
                defer { self.bridgeLock.unlock() }
                let bytes = bridge.saveKVState(path: path)
                if bytes > 0 {
                    nlLog("[KVCache] Saved \(bridge.kvTokenCount) tokens, \(bytes) bytes to \(URL(fileURLWithPath: path).lastPathComponent)", level: .info)
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
