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

    /// How long the companion must have been idle (not listening, thinking
    /// or speaking) before a background generation starts, and how long to
    /// wait for that before giving up — the caller retries on its next
    /// trigger. Keeps memory work off the turn's CPU/GPU and out of its way.
    static let silentIdleSettle: TimeInterval = 1.5
    static let silentIdleTimeout: TimeInterval = 120

    /// One-shot background generation (fact extraction, reflections, titles):
    /// nothing reaches the transcript or TTS, the conversation's KV cache is
    /// left as it was, and a user turn preempts it. Empty on failure.
    func runSilentGeneration(prompt: String, maxTokens: Int) async -> String {
        await runSilentGenerationOrNil(prompt: prompt, maxTokens: maxTokens) ?? ""
    }

    /// As `runSilentGeneration`, but nil when it could not run to the end
    /// (no model, never idle, or preempted) so callers can retry instead of
    /// treating it as an empty answer.
    func runSilentGenerationOrNil(prompt: String, maxTokens: Int) async -> String? {
        guard llmEngine.isLoaded, await waitUntilIdle() else { return nil }
        return await llmEngine.generateSilently(prompt: prompt, maxTokens: maxTokens)
    }

    private func waitUntilIdle() async -> Bool {
        let deadline = Date().addingTimeInterval(Self.silentIdleTimeout)
        var idleSince: Date?
        while Date() < deadline {
            let quiet = await MainActor.run { state.status == .ready || state.status == .disconnected }
            let recording = recordingLock.withLock { isRecordingVoice }
            if quiet && !recording {
                let since = idleSince ?? Date()
                idleSince = since
                if Date().timeIntervalSince(since) >= Self.silentIdleSettle { return true }
            } else {
                idleSince = nil
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }
}
