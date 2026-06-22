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

    /// Constant lead-in prepended to every JP user turn. It is the *shared,
    /// turn-invariant* head of the user message, so the warm-up prefill
    /// (`buildPrefillMessages`) can prefill `[system + this]` and the real
    /// turn's prefix-reuse covers all of it — only the actual user words
    /// re-prefill. Must be byte-identical in `buildMessages` and
    /// `buildPrefillMessages` or KV prefix-reuse silently drops to zero.
    static let jpAnswerLeadIn = "（日本語で回答）"

    /// Per-config context window. Delegates to
    /// `LLMRuntimeProfile.resolvedContextLength(for:)` — the same value the
    /// engines pass to `LlamaBridge.init` — so the budget compactor can never
    /// over- or under-evict relative to actual KV capacity.
    static func nCtx(for config: LocalModelDownloadManager.ModelConfiguration) -> Int {
        Int(LLMRuntimeProfile.resolvedContextLength(for: config))
    }

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
        let isJP = (config == .japaneseGemma2b)

        let systemContent = buildSystemContent(
            base: baseSystemPrompt,
            characterName: characterName,
            isJapaneseLlama: isJP
        )

        // Tier 3 (facts) is appended AFTER history as its own system
        // message rather than glued onto the persona. Reason: facts vary
        // per turn (different RAG hits for different user inputs), so
        // mixing them into the system message would invalidate the KV-
        // cache prefix at the very first token where facts diverge.
        // Keeping persona + history contiguous lets prefix-reuse cover
        // the entire stable portion of the prompt — the only re-prefill
        // each turn is the facts block + the user turn itself.
        let factsBlock = isJP
            ? ""
            : buildFactsBlock(relevantTo: userInput)

        let history = buildHistory(
            isJapaneseLlama: isJP,
            excluding: userInput
        )

        let userMessage = isJP ? "\(Self.jpAnswerLeadIn)\(userInput)" : userInput

        var messages: [LLMChatMessage] = [
            .init(role: "system", content: systemContent)
        ]
        messages.append(contentsOf: history)
        if !factsBlock.isEmpty {
            messages.append(.init(role: "system", content: factsBlock))
        }
        messages.append(.init(role: "user", content: userMessage))

        return Self.fitToBudget(messages, nCtx: Self.nCtx(for: config))
    }

    /// Builds the warmup prompt for `prefill(messages:)` — everything we
    /// can format before knowing the user's input: system+persona content
    /// and the verbatim history. Tier 3 (RAG) is intentionally omitted
    /// because retrieval depends on the user query we don't have yet;
    /// the final `buildMessages` call will add it back, and the bridge's
    /// prefix-reuse will only re-prefill from the point where the prompts
    /// diverge.
    func buildPrefillMessages(
        config: LocalModelDownloadManager.ModelConfiguration,
        characterName: String,
        baseSystemPrompt: String
    ) async -> [LLMChatMessage] {
        let isJP = (config == .japaneseGemma2b)
        let systemContent = buildSystemContent(
            base: baseSystemPrompt,
            characterName: characterName,
            isJapaneseLlama: isJP
        )
        var messages: [LLMChatMessage] = [
            .init(role: "system", content: systemContent)
        ]
        messages.append(contentsOf: buildHistory(
            isJapaneseLlama: isJP,
            excluding: ""
        ))
        // JP path has no history, so a system-only message list makes Gemma's
        // chat template render nothing reusable (the warm-up no-ops and the
        // first token re-prefills the whole prompt — observed as prefill=1+N
        // in `[Bench]`). Append the turn-invariant user lead-in so the warm-up
        // prefills `[system + lead-in]`; the real turn then reuses all of it
        // and only re-prefills the user's actual words. English/Qwen tiers
        // carry real history here, so they already form a valid prefix.
        if isJP {
            messages.append(.init(role: "user", content: Self.jpAnswerLeadIn))
        }
        return messages
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
            // 1B model attends most to the first ~30 tokens. Order: (1)
            // language directive — strongest signal, (2) one-line user
            // context if the user has set their name, (3) role clarification
            // — names "私" and "あなた" explicitly so the model doesn't
            // mechanically translate English "my" → 私 in its reply, and
            // (4) persona description in `base`.
            var sys = "必ず日本語で返答してください。\n"
            sys += Self.buildJPUserContextLine()
            sys += Self.buildJPRoleClarification(characterName: characterName)
            sys += base
            return sys
        }
        // English path. Role clarification goes BEFORE the persona so it
        // anchors the AI's identity before any "I am" / "You are" phrasing
        // appears, and BEFORE the [User Information] block in
        // `systemPromptContext` so the model reads the rule first and the
        // data second. Mirrors the JP-side fix that resolved the same
        // "model treats user info as its own" pattern.
        return Self.buildEnglishRoleClarification(characterName: characterName)
            + base
            + UserSettings.shared.systemPromptContext
            + CompanionStateManager.shared.promptContext(characterName: characterName)
    }

    /// Returns a single-line JP user context block (`ユーザーの名前は{name}、{age}歳。\n`)
    /// when the user has set their display name in Settings; empty string
    /// otherwise. Kept short on purpose because the JP path runs on the
    /// 4 GB iPhone 11/12/13 tier where every system-prompt token eats
    /// into the 1B model's already-thin attention budget. Surface area
    /// is intentionally `name + age` only — the structured English
    /// `[User Information]` block stays out of JP because it would add
    /// ~80 tokens of mixed-language text and degrade response quality.
    private static func buildJPUserContextLine() -> String {
        let settings = UserSettings.shared
        let name = settings.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "" }

        let ageComponents = Calendar.current.dateComponents(
            [.year], from: settings.birthday, to: Date())
        if let age = ageComponents.year, age > 0 {
            return "ユーザーの名前は\(name)、\(age)歳。\n"
        }
        return "ユーザーの名前は\(name)。\n"
    }

    /// Pronoun + role disambiguation for the JP 1B. Observed failure mode
    /// without this: user asks "What is my name?" (in English), model
    /// answers `私の名前はDedicatusです` — using `私` (= "I/me") instead of
    /// `あなた` (= "you"). The 1B is mechanically translating English "my"
    /// to JP `私` rather than doing the speaker→listener perspective flip
    /// that JP grammar requires in a reply. Naming `私` (= the AI) and
    /// `あなた` (= the user) explicitly gives the model an unambiguous
    /// anchor it can attend to even when input arrives in English.
    ///
    /// Falls back to a softer boundary ("if you don't know, say so") when
    /// the user hasn't set a display name yet — without a name the role
    /// mapping is one-sided and the 1B still tends to confabulate.
    private static func buildJPRoleClarification(characterName: String) -> String {
        let aiName = characterName.capitalized
        let userName = UserSettings.shared.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if userName.isEmpty {
            return "私(AI)＝\(aiName)。ユーザーについて確実な情報がない時は「まだ知りません」と答える。\n"
        }
        return "私(AI)＝\(aiName)、あなた(ユーザー)＝\(userName)。役割を混同しない。\n"
            + "ユーザーが「私」「僕」「俺」と話す時、\(aiName)は「あなた」で返答する。\n"
    }

    /// Role/identity disambiguation for the English path. Mirrors the JP
    /// fix but uses third-person framing so it works whether the persona
    /// downstream speaks in first-person (Llama-1B: "I am Ekaterina") or
    /// second-person (Qwen tiers: "You are Ekaterina") — no voice clash.
    ///
    /// The clause "use the [User Information] block ... never invent details"
    /// pins the model to the structured user data appended later by
    /// `UserSettings.systemPromptContext`, replacing the inline
    /// "you don't know personal details" / "I must say I don't know yet"
    /// lines that previously contradicted that very block.
    private static func buildEnglishRoleClarification(characterName: String) -> String {
        let aiName = characterName.capitalized
        let userName = UserSettings.shared.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if userName.isEmpty {
            return "[Role] \(aiName) is the AI assistant. When the user asks about themselves and the [User Information] block below is empty, \(aiName) says so honestly instead of inventing details.\n"
        }
        return "[Role] \(aiName) is the AI assistant; the user is \(userName). \(aiName) answers questions about the user using the [User Information] block below, and never invents details that aren't present there.\n"
    }

    private func buildFactsBlock(relevantTo input: String) -> String {
        let facts = RAGManager.shared.fetchFacts(
            relevantTo: input, limit: Self.factsLimit
        )
        guard !facts.isEmpty else { return "" }
        let bulleted = facts.map { "- \($0)" }.joined(separator: "\n")
        return "[Established facts about the user]\n\(bulleted)\n[End facts]"
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
