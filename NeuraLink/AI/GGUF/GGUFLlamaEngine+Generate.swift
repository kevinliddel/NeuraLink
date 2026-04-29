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
}
