//
//  GGUFJapaneseLlamaEngine+Generate.swift
//  NeuraLink
//
//  Token generation loop for GGUFJapaneseLlamaEngine.
//  Identical flow to GGUFLlamaEngine+Generate — blocking C call dispatched
//  to a GCD thread so the Swift cooperative pool stays free.
//
//  Created by Dedicatus on 06/05/2026.
//

import Foundation

extension GGUFJapaneseLlamaEngine {

    // MARK: - LLMEngineProtocol — generate

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
            print("[GGUFJapaneseLlama] Dropped generate — already in progress")
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
