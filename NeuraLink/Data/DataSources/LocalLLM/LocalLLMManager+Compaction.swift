//
//  LocalLLMManager+Compaction.swift
//  NeuraLink
//
//  Background compaction trigger: after a user-facing turn finishes, kick
//  off a detached Task that asks the local LLM to summarise aged-out chat
//  events into atomic facts via `LocalLLMFactExtractor`. Results are stored
//  in `RAGManager` (source = "fact") and surfaced into Tier 3 of the next
//  prompt by `LocalLLMMemoryHierarchy`.
//
//  Part of Phase 2B in docs/local_llm_memory_plan.md.
//
//  Created by Dedicatus on 19/05/2026.
//

import Foundation

extension LocalLLMManager {

    /// Fires a background task that extracts facts from any chat events
    /// that have aged out of the verbatim window since the last
    /// compaction. No-ops when:
    ///   - the active engine isn't loaded,
    ///   - the active model is `.llama1b` (too small to summarise reliably —
    ///     mostly hallucinates) or `.japaneseGemma2b` (the JP tier doesn't
    ///     inject Tier 3 facts into prompts anyway, so the output would be
    ///     pure waste),
    ///   - there are no new candidates beyond the verbatim window, or
    ///   - a previous compaction is still running.
    func maybeRunCompaction() {
        guard llmEngine.isLoaded else { return }
        let config = LocalModelDownloadManager.shared.selectedConfig
        if config == .llama1b || config == .japaneseGemma2b { return }

        let hierarchy = LocalLLMMemoryHierarchy.shared
        let candidates = hierarchy.compactionCandidates()
        guard !candidates.isEmpty else { return }
        guard hierarchy.tryBeginCompaction() else { return }

        Task.detached(priority: .background) { [weak self] in
            defer { hierarchy.endCompaction() }
            guard let self else { return }

            let generator: LocalLLMSilentGenerator = { [weak self] prompt, maxTokens in
                guard let self else { return "" }
                return await self.runSilentGeneration(
                    prompt: prompt, maxTokens: maxTokens)
            }

            let facts = await LocalLLMFactExtractor.shared.extractAndStore(
                from: candidates, using: generator)
            hierarchy.markCompacted(candidates)

            if !facts.isEmpty {
                nlLog("[LocalLLM] Compacted \(candidates.count) chat events → \(facts.count) facts", level: .info)
            }
        }
    }

    /// One-shot generation that bypasses the manager's delegate methods.
    /// Tokens are collected into a captive `SilentLLMDelegate` rather than
    /// being streamed through the live UI/transcript/TTS pipeline, so the
    /// user sees and hears nothing during background fact extraction.
    ///
    /// Serialised via the engine's existing `generationLock`, so a silent
    /// run can never overlap a user-facing generation (or vice versa).
    func runSilentGeneration(prompt: String, maxTokens: Int) async -> String {
        let originalDelegate = llmEngine.delegate
        let silent = SilentLLMDelegate()
        llmEngine.delegate = silent
        defer { llmEngine.delegate = originalDelegate }

        await llmEngine.generate(prompt: prompt, maxTokens: maxTokens)
        return silent.fullText
    }
}

/// Captures token output during a silent (background) generation so the
/// engine's regular delegate doesn't observe the run. Each LLMEngine's
/// `delegate` property is `weak`, so the caller of
/// `LocalLLMManager.runSilentGeneration` must hold the strong reference
/// to this instance until the awaited call returns — which it does, since
/// the instance is held in a local `let`.
final class SilentLLMDelegate: LocalLLMEngineDelegate {

    /// Final, full text accumulated from `didFinishGeneration`. Per-token
    /// callbacks are intentionally discarded — we don't need them and they
    /// would compete with the engine's token-streaming closure for the
    /// brief window the silent run holds.
    private(set) var fullText: String = ""

    func localLLM(didGenerateToken token: String) {
        // Intentionally empty: silent runs only consume the final aggregate.
    }

    func localLLM(didFinishGeneration text: String) {
        fullText = text
    }

    func localLLM(didFailWithError error: Error) {
        // Best-effort: leave `fullText` empty so the FactExtractor's
        // `NONE`-handling path treats this as "no facts extractable".
    }
}
