//
//  LocalLLMMemoryHierarchy.swift
//  NeuraLink
//
//  Composes the 3-tier prompt for the local LLM per
//  docs/local_llm_memory_plan.md §3.2:
//    - Tier 1: system + persona + user context + companion
//    - Tier 3: relevant atomic facts (RAGManager.fetchFacts, English only)
//    - Tier 2: verbatim recent dialogue turns (MemoryStore.fetchChatEvents)
//    - User turn
//
//  Also identifies which aged-out chat events are candidates for fact
//  extraction (compaction). The actual silent LLM call that does the
//  extraction lives in `LocalLLMManager+Compaction.swift`.
//
//  Created by Dedicatus on 19/05/2026.
//

import Foundation

final class LocalLLMMemoryHierarchy {

    // MARK: - Singleton

    static let shared = LocalLLMMemoryHierarchy()

    // MARK: - Tunables

    /// Tier 2 verbatim window, in raw chat events (≈ 6 user+assistant pairs).
    /// Lower bound; the budget check in `fitToBudget` can evict more.
    static let verbatimWindowMessages = 12

    /// Top-K facts retrieved from `RAGManager.fetchFacts` for Tier 3.
    static let factsLimit = 3

    /// Context window used by the budget check. All current engines use 2048.
    static let nCtxDefault = 2_048

    private static let lastCompactedKey = "LocalLLM_LastCompactedTurnID"

    // MARK: - State

    private let inFlightLock = NSLock()
    private var compactionInFlight = false

    // MARK: - Init

    private init() {}

    // MARK: - Prompt assembly

    /// Builds the `[LLMChatMessage]` array for the next prompt by stacking
    /// all three tiers and the new user turn, then evicting oldest history
    /// pairs until the projected prompt fits under the budget threshold.
    ///
    /// - Parameters:
    ///   - userInput: The freshly transcribed user message.
    ///   - config:   Currently selected model configuration — controls JP
    ///               special-casing and may control `n_ctx` in future tiers.
    ///   - characterName: Persona identifier used by `baseSystemPrompt`.
    ///   - baseSystemPrompt: Pre-resolved persona/tool/system prompt block.
    ///                       Supplied by the caller (`LocalLLMManager`) so
    ///                       the hierarchy stays decoupled from the
    ///                       `+TTS.swift` extension that owns
    ///                       `localLLMSystemPrompt(for:)`.
    func buildMessages(
        userInput: String,
        config: LocalModelDownloadManager.ModelConfiguration,
        characterName: String,
        baseSystemPrompt: String
    ) async -> [LLMChatMessage] {
        let isJP = (config == .japaneseLlama1b)

        let systemContent = buildSystemContent(
            base: baseSystemPrompt,
            characterName: characterName,
            isJapaneseLlama: isJP
        )

        // Tier 3 (facts) injected into the system message so it's prefix-
        // cached alongside the persona — same KV reuse semantics, no extra
        // role chunk for the model to parse.
        let factsBlock = isJP
            ? ""
            : buildFactsBlock(relevantTo: userInput)

        let history = buildHistory(
            isJapaneseLlama: isJP,
            excluding: userInput
        )

        let userMessage = isJP ? "（日本語で回答）\(userInput)" : userInput

        var messages: [LLMChatMessage] = [
            .init(role: "system", content: systemContent + factsBlock)
        ]
        messages.append(contentsOf: history)
        messages.append(.init(role: "user", content: userMessage))

        return Self.fitToBudget(messages, nCtx: Self.nCtxDefault)
    }

    // MARK: - Compaction surface

    /// Returns chat events that have aged out of the verbatim window AND
    /// have not yet been compacted into facts. Empty when nothing to do.
    /// Caller is `LocalLLMManager.maybeRunCompaction`.
    func compactionCandidates() -> [ChatEventItem] {
        let lastID = UserDefaults.standard.object(
            forKey: Self.lastCompactedKey) as? Int64 ?? 0
        let recent = MemoryStore.shared.fetchChatEvents(limit: 50)
        return Self.candidatesBeyondWindow(
            allRecent: recent,
            windowMessages: Self.verbatimWindowMessages,
            lastCompactedID: lastID
        )
    }

    /// Pure-logic split of `compactionCandidates` for testability.
    /// `allRecent` is expected newest-first (matches
    /// `MemoryStore.fetchChatEvents(limit:)` which orders by timestamp DESC).
    static func candidatesBeyondWindow(
        allRecent: [ChatEventItem],
        windowMessages: Int,
        lastCompactedID: Int64
    ) -> [ChatEventItem] {
        guard allRecent.count > windowMessages else { return [] }
        let beyondWindow = Array(allRecent.dropFirst(windowMessages))
        return beyondWindow.filter { $0.id > lastCompactedID }
    }

    /// Persists the highest event id from `turns` as the last-compacted
    /// boundary so `compactionCandidates()` won't return them again.
    func markCompacted(_ turns: [ChatEventItem]) {
        guard let maxID = turns.map(\.id).max() else { return }
        UserDefaults.standard.set(maxID, forKey: Self.lastCompactedKey)
    }

    /// Re-entrancy guard so concurrent `maybeRunCompaction` invocations
    /// don't pile multiple background extractions on top of each other.
    /// Returns true if the caller acquired the in-flight slot.
    func tryBeginCompaction() -> Bool {
        inFlightLock.lock(); defer { inFlightLock.unlock() }
        if compactionInFlight { return false }
        compactionInFlight = true
        return true
    }

    func endCompaction() {
        inFlightLock.lock(); defer { inFlightLock.unlock() }
        compactionInFlight = false
    }

    // MARK: - Internals

    private func buildSystemContent(
        base: String,
        characterName: String,
        isJapaneseLlama: Bool
    ) -> String {
        if isJapaneseLlama {
            // Language instruction first: a 1B model attends most to the
            // first ~30 tokens, so placing the directive there gives it
            // the strongest signal.
            return "必ず日本語で返答してください。\n" + base
        }
        return base
            + UserSettings.shared.systemPromptContext
            + CompanionStateManager.shared.promptContext(characterName: characterName)
    }

    private func buildFactsBlock(relevantTo input: String) -> String {
        let facts = RAGManager.shared.fetchFacts(
            relevantTo: input, limit: Self.factsLimit
        )
        guard !facts.isEmpty else { return "" }
        let bulleted = facts.map { "- \($0)" }.joined(separator: "\n")
        return "\n[Established facts about the user]\n\(bulleted)\n[End facts]\n"
    }

    private func buildHistory(
        isJapaneseLlama: Bool,
        excluding currentInput: String
    ) -> [LLMChatMessage] {
        // No history for the Japanese 1B model — see comment in the
        // original handleUserInput about orphaned AI responses and the
        // 1B model's poor multi-turn coherence.
        let limit = isJapaneseLlama ? 0 : Self.verbatimWindowMessages
        guard limit > 0 else { return [] }

        let raw = MemoryStore.shared.fetchChatEvents(limit: limit)
        // fetchChatEvents is newest-first; the prompt wants chronological.
        var events = Array(raw.reversed())
        // If the just-logged user message is already in the timeline
        // (`ChatTimelineStore.logUserMessage` ran before us) drop it so
        // we don't duplicate it as both history and current turn.
        if let last = events.last, last.role == "user", last.detail == currentInput {
            events.removeLast()
        }
        return events.map {
            LLMChatMessage(
                role: $0.role == "ai" ? "assistant" : "user",
                content: $0.detail
            )
        }
    }

    /// Evicts the oldest history message (and a second one to keep
    /// removals in user/assistant pairs when both are over-budget) until
    /// `LocalLLMContextBudget.shouldCompact` returns false. Keeps the
    /// system message at index 0 and the current user turn at the end
    /// regardless of how much we evict. Internal (rather than private)
    /// so unit tests can exercise it directly.
    static func fitToBudget(
        _ messages: [LLMChatMessage],
        nCtx: Int
    ) -> [LLMChatMessage] {
        var result = messages
        while result.count > 2,
              LocalLLMContextBudget.shouldCompact(messages: result, nCtx: nCtx) {
            // result[0] = system; remove the oldest message (index 1).
            result.remove(at: 1)
            // If still over budget, drop one more so removals progress in
            // user+assistant pairs rather than orphaning a single message.
            if result.count > 2,
               LocalLLMContextBudget.shouldCompact(messages: result, nCtx: nCtx) {
                result.remove(at: 1)
            }
        }
        return result
    }
}
