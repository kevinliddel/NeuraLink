//
//  llama_bridge_internal.hpp
//  NeuraLink
//
//  C++-only private header shared between llama_bridge.cpp and
//  llama_bridge_state.cpp. Defines the opaque `LlamaBridgeHandle` struct
//  exactly once so both compilation units operate on the same layout.
//  Never include this from a .h that Swift imports — the bridging header
//  only sees `llama_bridge.h`.
//
//  Created by Dedicatus on 20/05/2026.
//

#pragma once

#include <llama/llama.h>

#include <atomic>
#include <cstddef>
#include <string>
#include <vector>

struct LlamaBridgeHandle {
    llama_model*             model       = nullptr;
    llama_context*           ctx         = nullptr;
    llama_sampler*           sampler     = nullptr;
    std::atomic<bool>        cancel_flag { false };

    /// Tokens currently materialised in the KV cache for sequence 0.
    /// Used to compute the common prefix with the next prompt so we only
    /// re-prefill the suffix that actually changed.
    std::vector<llama_token> kv_tokens;

    /// Prompt-Lookup Decoding config. See `llama_bridge_set_prompt_lookup`.
    bool                     pld_enabled = false;
    int32_t                  pld_n       = 3;
    int32_t                  pld_n_draft = 5;

    /// Per-call prefill telemetry, populated by `sync_kv_for_prompt`. Read
    /// from Swift via `llama_bridge_get_prefill_stats` after generate returns
    /// — lets the benchmark log distinguish prefix-reuse hits from full
    /// re-prefills on multi-turn dialogue.
    int32_t                  last_prefill_reused = 0;
    int32_t                  last_prefill_new    = 0;
    double                   last_prefill_ms     = 0.0;

    /// Per-call PLD (prompt-lookup decoding) telemetry. `pld_rounds` counts
    /// every iteration of the speculative loop; `pld_hits` counts only those
    /// where an n-gram match was found and the verification batch ran. Hit
    /// rate = hits/rounds. Useful for deciding whether PLD's overhead is
    /// paying off — particularly relevant on Japanese where n-gram matches
    /// are rarer than in English conversation.
    int32_t                  last_pld_rounds     = 0;
    int32_t                  last_pld_hits       = 0;
};

// MARK: - UTF-8 stream assembly

/// Returns the longest prefix of `s` that ends on a complete UTF-8 boundary.
/// llama.cpp's BPE tokeniser emits raw bytes per token for any code point
/// outside the model's vocabulary fast path — for CJK/emoji input that means
/// a single Unicode character can arrive as 2–4 separate `on_token` pieces,
/// each containing only one byte of a multi-byte UTF-8 sequence. Passing
/// such a piece through Swift's `String(cString:)` produces `\u{FFFD}`
/// (the replacement char) because no individual byte is valid UTF-8 on its
/// own. Callers buffer pieces until this function reports a complete
/// boundary and only then forward the prefix to the Swift callback.
///
/// Lead-byte length classification used here:
///   0xxxxxxx → 1 byte (ASCII)
///   110xxxxx → 2 bytes
///   1110xxxx → 3 bytes
///   11110xxx → 4 bytes
///   10xxxxxx → continuation byte (never a lead)
inline std::size_t utf8_safe_prefix(const std::string& s) {
    if (s.empty()) { return 0; }
    std::size_t pos = s.size();
    while (pos > 0) {
        const unsigned char b = static_cast<unsigned char>(s[pos - 1]);
        if ((b & 0xC0) == 0x80) {
            // Continuation byte — walk back to find the lead.
            --pos;
            continue;
        }
        // Lead byte (or ASCII) — determine its expected length.
        int expected = 1;
        if ((b & 0x80) == 0)      { expected = 1; }
        else if ((b & 0xE0) == 0xC0) { expected = 2; }
        else if ((b & 0xF0) == 0xE0) { expected = 3; }
        else if ((b & 0xF8) == 0xF0) { expected = 4; }
        // Anything else is malformed — fall through with expected=1
        // so we emit the lead alone rather than block the stream.
        const std::size_t lead_pos = pos - 1;
        const std::size_t available = s.size() - lead_pos;
        if (available >= static_cast<std::size_t>(expected)) {
            return s.size();          // last char is complete
        }
        return lead_pos;              // last char incomplete; keep tail buffered
    }
    return s.size();                  // all continuation bytes (malformed) — flush
}
