//
//  LocalLLMFactExtractor.swift
//  NeuraLink
//
//  Extracts atomic, user-stated facts from a window of dialogue turns about
//  to age out of the verbatim context. Output facts are stored via
//  RAGManager so they can be re-surfaced by semantic retrieval when the
//  user mentions a related topic in a future turn — even one that happens
//  long after the dialogue itself has been compacted away.
//
//  Designed for dependency injection: the LLM call is supplied as a closure
//  so the extractor can be unit-tested with a deterministic stub.
//
//  Part of the 3-tier memory hierarchy described in
//  docs/local_llm_memory_plan.md.
//
//  Created by Dedicatus on 18/05/2026.
//

import Foundation

/// Callback signature for "generate one completion synchronously for me".
/// The implementation in Phase 2B will route this through the active engine
/// with a `state.aiTranscript` / TTS / delegate bypass so the user sees and
/// hears nothing of the silent compaction step.
typealias LocalLLMSilentGenerator = (_ prompt: String, _ maxTokens: Int) async -> String

final class LocalLLMFactExtractor {

    // MARK: - Singleton

    static let shared = LocalLLMFactExtractor()

    private init() {}

    // MARK: - Tunables

    /// Token cap for the summarisation reply. 80 tokens fits 4–5 short
    /// "User likes X" / "Lives in Y" statements without runaway generation.
    private let maxTokens = 80

    /// The literal output we accept as "this exchange had no factual content".
    /// Surrounding whitespace and trailing punctuation are tolerated.
    private let nullSentinel = "NONE"

    // MARK: - Public API

    /// Run fact extraction on `turns`. Returns each extracted fact as one
    /// short natural-language statement, ready to be embedded and stored.
    /// Returns an empty array if `turns` is empty or the LLM signalled no
    /// factual content.
    ///
    /// The caller is responsible for guaranteeing no other generation is
    /// running on the same engine (the bridge is not re-entrant).
    func extract(
        from turns: [ChatEventItem],
        using generate: LocalLLMSilentGenerator
    ) async -> [String] {
        guard !turns.isEmpty else { return [] }
        let prompt = buildPrompt(from: turns)
        let raw = await generate(prompt, maxTokens)
        return parseFacts(raw)
    }

    /// Convenience: extract facts and persist them via `RAGManager`. Each
    /// fact is stored with `source = "fact"` so it can be retrieved later
    /// via `fetchFacts(relevantTo:limit:)`.
    func extractAndStore(
        from turns: [ChatEventItem],
        using generate: LocalLLMSilentGenerator
    ) async -> [String] {
        let facts = await extract(from: turns, using: generate)
        for fact in facts {
            RAGManager.shared.storeFact(fact)
        }
        return facts
    }

    // MARK: - Prompt building

    /// Builds the LLM prompt that asks for atomic-fact summarisation of the
    /// given turns. Format is intentionally compact — small instruct-tuned
    /// models (Llama-3.2-1B in particular) lose instruction-following
    /// ability with verbose prompts.
    func buildPrompt(from turns: [ChatEventItem]) -> String {
        var transcript = ""
        for turn in turns {
            let speaker = turn.role == "ai" ? "Assistant" : "User"
            transcript += "\(speaker): \(turn.detail)\n"
        }
        return """
        Extract atomic facts the User has stated about themselves from the \
        exchange below. Output one fact per line, in third person, no \
        bullet markers. If the exchange contains no factual user-stated \
        information, output exactly the single word \(nullSentinel).

        Exchange:
        \(transcript)
        Facts:
        """
    }

    // MARK: - Output parsing

    /// Parses LLM output into a clean list of facts. Tolerates bullet
    /// prefixes (`- `, `* `, `1. `), trailing punctuation noise, and the
    /// `NONE` sentinel in any casing.
    func parseFacts(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Sentinel check is whole-string and case-insensitive.
        let lower = trimmed.lowercased()
        if lower == nullSentinel.lowercased()
            || lower == "\(nullSentinel.lowercased())." {
            return []
        }

        var facts: [String] = []
        for line in trimmed.split(separator: "\n") {
            let cleaned = stripLeadingMarker(String(line))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleaned.count >= 4 else { continue }
            if cleaned.lowercased() == nullSentinel.lowercased() { continue }
            facts.append(cleaned)
        }
        return facts
    }

    /// Removes common list-marker prefixes (`- foo`, `* foo`, `1. foo`,
    /// `1) foo`) so the stored fact is just the statement itself.
    private func stripLeadingMarker(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("- ") { s.removeFirst(2); return s }
        if s.hasPrefix("* ") { s.removeFirst(2); return s }
        // Numbered: digits + "." or ")" + space.
        var idx = s.startIndex
        while idx < s.endIndex, s[idx].isNumber { idx = s.index(after: idx) }
        if idx > s.startIndex, idx < s.endIndex,
           s[idx] == "." || s[idx] == ")" {
            let after = s.index(after: idx)
            if after < s.endIndex, s[after] == " " {
                return String(s[s.index(after: after)...])
            }
        }
        return s
    }
}
