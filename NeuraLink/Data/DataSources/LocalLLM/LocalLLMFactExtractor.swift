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

    /// Minimum useful fact length. Below this is almost always echo
    /// fragments like "Facts:" or "Explanation:" from a 1B model that
    /// half-answered the prompt structure instead of producing content.
    private let minFactLength = 12

    /// Maximum fact length. Above this is almost always a hallucinated
    /// paragraph rather than an atomic statement — the previous output
    /// was a 310-char essay about "the user's mother is very kind".
    private let maxFactLength = 120

    /// Prefixes that indicate the model echoed the prompt structure rather
    /// than producing a fact. Compared case-insensitively at line start.
    private let rejectedPrefixes: [String] = [
        "facts",          // "Facts:" / "Facts the user..."
        "explanation",    // "Explanation: ..."
        "summary",        // "Summary: ..."
        "the assistant",  // "The assistant states that ..."
        "assistant:",     // ChatML role echo
        "user:",          // ChatML role echo
        "i ",             // First-person — wrong subject
        "i'",             // "I'm", "I've", "I'll"
        "my ",            // First-person possessive
        "we "             // First-person plural
    ]

    /// Subject prefixes a *valid* fact line must start with. Anything that
    /// doesn't begin one of these is rejected — even if it looks like a
    /// reasonable sentence, it's almost certainly not user-about-self.
    private let acceptedSubjectPrefixes: [String] = [
        "user ", "user'", "users ",
        "the user "
    ]

    /// Parses LLM output into a clean list of facts. Tolerates bullet
    /// prefixes (`- `, `* `, `1. `), trailing punctuation noise, and the
    /// `NONE` sentinel in any casing. Applies the quality gates above so
    /// 1B-class hallucinations don't reach RAGManager.
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
            guard isAcceptableFact(cleaned) else { continue }
            facts.append(cleaned)
        }
        return facts
    }

    /// Quality gate: returns true only if `line` looks like a valid
    /// user-stated fact rather than an echo / boilerplate / first-person
    /// hallucination / over-long paragraph.
    private func isAcceptableFact(_ line: String) -> Bool {
        if line.count < minFactLength { return false }
        if line.count > maxFactLength { return false }
        let lower = line.lowercased()
        if lower == nullSentinel.lowercased() { return false }
        for prefix in rejectedPrefixes where lower.hasPrefix(prefix) {
            return false
        }
        for prefix in acceptedSubjectPrefixes where lower.hasPrefix(prefix) {
            return true
        }
        return false
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
