//
//  GGUFSpeculativeEngine+Generate.swift
//  NeuraLink
//
//  Token generation loop for the speculative engine. Mirrors the structure
//  of the single-model engines' +Generate extensions: dispatch the blocking
//  C call to a GCD thread, stream tokens through the delegate via
//  withCheckedContinuation, drop concurrent calls per the engine's
//  generationLock.
//
//  Created by Dedicatus on 19/05/2026.
//

import Foundation

extension GGUFSpeculativeEngine {

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
            nlLog("[GGUFSpec] Dropped generate — already in progress", level: .info)
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
}
