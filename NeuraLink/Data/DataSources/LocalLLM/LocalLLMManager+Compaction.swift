//
//  LocalLLMManager+Compaction.swift
//  NeuraLink
//
//  Background compaction trigger: after a user-facing turn finishes, hand
//  un-retained chat turns to the agentic-memory retain step
//  (`MemoryRetain`), which runs fact extraction on the local model via
//  `runSilentGeneration` below. Extracted facts surface in Tier 3 of the
//  next prompt through `LocalLLMMemoryHierarchy` → hybrid recall.
//
//  Created by Dedicatus on 19/05/2026.
//

import Foundation

extension LocalLLMManager {

    /// Kicks the agentic-memory retain step (docs/AGENTIC_MEMORY.md
    /// §Retain). Extraction, chunking and the un-retained-turn watermark
    /// live in `MemoryRetain`; this keeps the historical call site in
    /// `handleFinishedGeneration`. The JP tier is excluded inside
    /// `LiveMemoryLLM.tier` (its prompts never inject Tier 3 anyway).
    func maybeRunCompaction() {
        guard llmEngine.isLoaded else { return }
        MemoryRetain.shared.maybeRetain()
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
