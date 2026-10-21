//
//  llama_bridge_state.cpp
//  NeuraLink
//
//  KV cache persistence — save/restore the prefilled state across app
//  launches so the cold-start persona prefill (~6–17 s on iPhone 11)
//  doesn't have to be paid every time the user opens the app.
//
//  Split out of llama_bridge.cpp.
//
//  Created by Dedicatus on 20/05/2026.
//

#include "llama_bridge.h"
#include "llama_bridge_internal.hpp"

size_t llama_bridge_save_kv_state(LlamaBridgeHandle* handle, const char* path) {
    if (!handle || !handle->ctx || !path) { return 0; }
    if (handle->kv_tokens.empty()) { return 0; }
    return llama_state_seq_save_file(handle->ctx, path,
                                     /*seq_id=*/0, handle->kv_tokens.data(), handle->kv_tokens.size());
}

int32_t llama_bridge_load_kv_state(LlamaBridgeHandle* handle, const char* path) {
    if (!handle || !handle->ctx || !path) { return 0; }

    // n_ctx is the maximum sequence length the context was created with —
    // also the upper bound on tokens recoverable from a saved state.
    const size_t cap = static_cast<size_t>(llama_n_ctx(handle->ctx));
    std::vector<llama_token> tokens(cap);
    size_t n_loaded = 0;

    const size_t bytes = llama_state_seq_load_file(handle->ctx, path,
                                                   /*dest_seq_id=*/0, tokens.data(), cap, &n_loaded);

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

int32_t llama_bridge_state_seq_version(void) {
    return static_cast<int32_t>(LLAMA_STATE_SEQ_VERSION);
}

void llama_bridge_get_pld_stats(LlamaBridgeHandle* handle, int32_t* out_rounds, int32_t* out_hits) {
    if (!handle) { return; }
    if (out_rounds) { *out_rounds = handle->last_pld_rounds; }
    if (out_hits) { *out_hits = handle->last_pld_hits; }
}

// MARK: - In-memory snapshot (background generations)

struct LlamaBridgeSnapshot {
    std::vector<uint8_t> data;
    std::vector<llama_token> tokens;
};

LlamaBridgeSnapshot* llama_bridge_snapshot_create(LlamaBridgeHandle* handle) {
    if (!handle || !handle->ctx || handle->kv_tokens.empty()) { return nullptr; }
    const size_t size = llama_state_seq_get_size(handle->ctx, /*seq_id=*/0);
    if (size == 0) { return nullptr; }
    auto* snapshot = new LlamaBridgeSnapshot();
    snapshot->data.resize(size);
    const size_t written = llama_state_seq_get_data(handle->ctx, snapshot->data.data(), size, /*seq_id=*/0);
    if (written == 0) {
        delete snapshot;
        return nullptr;
    }
    snapshot->data.resize(written);
    snapshot->tokens = handle->kv_tokens;
    return snapshot;
}

bool llama_bridge_snapshot_restore(LlamaBridgeHandle* handle, const LlamaBridgeSnapshot* snapshot) {
    if (!handle || !handle->ctx || !snapshot) { return false; }
    auto* memory = llama_get_memory(handle->ctx);
    llama_memory_seq_rm(memory, /*seq_id=*/0, -1, -1);
    const size_t read = llama_state_seq_set_data(handle->ctx, snapshot->data.data(), snapshot->data.size(),
                                                 /*dest_seq_id=*/0);
    if (read == 0) {
        // Leave a clean, empty cache: the next prompt prefills from scratch.
        llama_memory_clear(memory, true);
        handle->kv_tokens.clear();
        return false;
    }
    handle->kv_tokens = snapshot->tokens;
    return true;
}

int32_t llama_bridge_snapshot_token_count(const LlamaBridgeSnapshot* snapshot) {
    return snapshot ? static_cast<int32_t>(snapshot->tokens.size()) : 0;
}

void llama_bridge_snapshot_free(LlamaBridgeSnapshot* snapshot) {
    delete snapshot;
}
