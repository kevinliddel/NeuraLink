//
//  llama_bridge_state.cpp
//  NeuraLink
//
//  KV cache persistence — save/restore the prefilled state across app
//  launches so the cold-start persona prefill (~6–17 s on iPhone 11)
//  doesn't have to be paid every time the user opens the app.
//
//  Split out of llama_bridge.cpp per docs/local_llm_memory_plan.md §6 to
//  keep each translation unit under the 500-line rule.
//
//  Created by Dedicatus on 20/05/2026.
//

#include "llama_bridge.h"
#include "llama_bridge_internal.hpp"

size_t llama_bridge_save_kv_state(LlamaBridgeHandle* handle, const char* path) {
    if (!handle || !handle->ctx || !path) { return 0; }
    if (handle->kv_tokens.empty()) { return 0; }
    return llama_state_seq_save_file(
        handle->ctx,
        path,
        /*seq_id=*/0,
        handle->kv_tokens.data(),
        handle->kv_tokens.size()
    );
}

int32_t llama_bridge_load_kv_state(LlamaBridgeHandle* handle, const char* path) {
    if (!handle || !handle->ctx || !path) { return 0; }

    // n_ctx is the maximum sequence length the context was created with —
    // also the upper bound on tokens recoverable from a saved state.
    const size_t cap = static_cast<size_t>(llama_n_ctx(handle->ctx));
    std::vector<llama_token> tokens(cap);
    size_t n_loaded = 0;

    const size_t bytes = llama_state_seq_load_file(
        handle->ctx,
        path,
        /*dest_seq_id=*/0,
        tokens.data(),
        cap,
        &n_loaded
    );

    if (bytes == 0 || n_loaded == 0) {
        // Load failed (missing file, format mismatch, capacity exhausted).
        // Leave the handle in its current state — caller can fall through
        // to a normal generate/prefill which will rebuild the cache from
        // scratch.
        return 0;
    }

    tokens.resize(n_loaded);
    handle->kv_tokens = std::move(tokens);
    return static_cast<int32_t>(n_loaded);
}

int32_t llama_bridge_kv_token_count(LlamaBridgeHandle* handle) {
    if (!handle) { return 0; }
    return static_cast<int32_t>(handle->kv_tokens.size());
}
