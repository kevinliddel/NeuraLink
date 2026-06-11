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

        // Fold this turn's acceptance telemetry into the auto-tuner while
        // `_isGenerating` is still held — `setNDraft` must not race a
        // concurrent generate call.
        tuneDraftWindow()
    }

    // MARK: - Draft-window auto-tuning (M3)

    /// Folds the last turn's `(drafted, accepted)` telemetry into the running
    /// counters and, every `tuneInterval` turns, adjusts the draft depth N:
    /// acceptance > 80 % → the target is rubber-stamping drafts, a longer
    /// window yields more free tokens per target pass (raise toward 8);
    /// acceptance < 50 % → most draft steps are wasted work (lower toward 2).
    /// The tuned value persists via UserDefaults so the next session starts
    /// from the converged window.
    internal func tuneDraftWindow() {
        guard let bridge else { return }
        let stats = bridge.draftStats
        guard stats.drafted > 0 else { return }
        tuneDrafted  += stats.drafted
        tuneAccepted += stats.accepted
        tuneTurns    += 1
        guard tuneTurns >= Self.tuneInterval else { return }

        let rate = Double(tuneAccepted) / Double(tuneDrafted)
        var newN = currentNDraft
        if rate > 0.8 {
            newN = min(currentNDraft + 2, Self.nDraftRange.upperBound)
        } else if rate < 0.5 {
            newN = max(currentNDraft - 2, Self.nDraftRange.lowerBound)
        }

        if newN != currentNDraft {
            nlLog(
                "[GGUFSpec] Draft acceptance \(Int(rate * 100))% over \(tuneTurns) turns — n_draft \(currentNDraft) → \(newN)",
                level: .info)
            bridge.setNDraft(newN)
            currentNDraft = newN
            UserDefaults.standard.set(Int(newN), forKey: Self.nDraftDefaultsKey)
        } else {
            nlLog(
                "[GGUFSpec] Draft acceptance \(Int(rate * 100))% over \(tuneTurns) turns — n_draft stays \(currentNDraft)",
                level: .debug)
        }

        tuneTurns    = 0
        tuneDrafted  = 0
        tuneAccepted = 0
    }
}
