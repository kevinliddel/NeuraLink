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
};
