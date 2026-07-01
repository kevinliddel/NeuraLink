//
//  LocalLLMContextBudget.swift
//  NeuraLink
//
//  Estimates the token footprint of the prompt we are about to send to the
//  local LLM and decides whether compaction should fire before the next
//  user turn. Pure functions only — no I/O, no engine references — so it
//  can be unit-tested in isolation.
//
//  Created by Dedicatus on 18/05/2026.
//

import Foundation

enum LocalLLMContextBudget {

    // MARK: - Tunables

    /// Bytes-per-token heuristic. Empirically holds within ±10% across the
    /// Llama-3.2 and LLM-jp BPE vocabularies for mixed
    /// English + Japanese conversational text. Tokenising via the bridge
    /// would be more accurate but would require holding the bridge across
    /// threads (it is not safe to share between in-flight generations).
    static let bytesPerToken = 3.5

    /// Approximate template overhead per role-tagged message — the
    /// `<|start_header_id|>role<|end_header_id|>\n\n…<|eot_id|>` (Llama 3)
    /// or `<|im_start|>role\n…<|im_end|>\n` (Qwen ChatML) wrapping added by
    /// `llama_chat_apply_template`. ~10 tokens is a reasonable upper bound.
    static let templateOverheadPerMessage = 10

    /// Fraction of `n_ctx` we want to stay under after appending the next
    /// user turn. Leaves headroom for the assistant's reply tokens (we cap
    /// generation at 160 tokens for Qwen, 100 for English Llama, so 20% of
    /// 2048 = ~400 tokens is more than enough).
    static let defaultCompactionThreshold = 0.8

    /// Approximate token cost of one user+assistant turn pair. Used to
    /// estimate how many pairs to drop in a compaction round. Real values
    /// average ~80 tokens for short spoken-style replies; a tighter
    /// estimate would require tokenising every dropped pair.
    static let approximateTurnPairTokens = 80

    // MARK: - Estimation

    /// Rough token count of an arbitrary UTF-8 string.
    static func estimateTokens(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return Int(ceil(Double(text.utf8.count) / bytesPerToken))
    }

    /// Rough token count of a chat-template-formatted prompt assembled from
    /// `messages`. Adds the per-message template overhead.
    static func estimateTokens(in messages: [LLMChatMessage]) -> Int {
        var total = templateOverheadPerMessage * messages.count
        for msg in messages {
            total += estimateTokens(in: msg.role)
            total += estimateTokens(in: msg.content)
        }
        return total
    }

    // MARK: - Decisions

    /// Returns true if the projected prompt exceeds `threshold * nCtx`.
    /// Use this to gate compaction before building the next prompt.
    static func shouldCompact(
        messages: [LLMChatMessage],
        nCtx: Int,
        threshold: Double = defaultCompactionThreshold
    ) -> Bool {
        guard nCtx > 0 else { return false }
        let projected = estimateTokens(in: messages)
        let limit = Int(Double(nCtx) * threshold)
        return projected > limit
    }

    /// Number of oldest turn pairs the hierarchy should drop in this
    /// compaction round. A turn pair is one user + one assistant message.
    /// Returns 0 when compaction is not needed.
    static func turnsToDrop(
        messages: [LLMChatMessage],
        nCtx: Int,
        threshold: Double = defaultCompactionThreshold,
        minimumPairs: Int = 2
    ) -> Int {
        guard shouldCompact(messages: messages, nCtx: nCtx, threshold: threshold) else {
            return 0
        }
        let projected = estimateTokens(in: messages)
        let limit = Int(Double(nCtx) * threshold)
        let overrun = max(0, projected - limit)
        // Drop enough pairs to clear `overrun` plus one pair of margin so
        // the next user turn does not immediately re-trigger compaction.
        let pairs = (overrun / approximateTurnPairTokens) + 1
        return max(minimumPairs, pairs)
    }
}
