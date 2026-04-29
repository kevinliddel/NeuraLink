//
//  llama_bridge.cpp
//  NeuraLink
//
//  C++ implementation of the llama_bridge public API.
//  Integrates llama.cpp via its public C API (llama.h).
//  Drives Metal GPU inference with a greedy decode loop.
//
//  Section layout (each section ≤ 150 lines):
//    §1  Includes and internal struct
//    §2  Context lifecycle (create / free / version)
//    §3  Sampler helpers
//    §4  Generation loop
//
//  Created by Dedicatus on 29/04/2026.
//

// MARK: - §1 Includes

#include "llama_bridge.h"
#include <llama/llama.h>

#include <atomic>
#include <vector>
#include <algorithm>
#include <cstring>

/// Internal state bundled behind the opaque pointer.
struct LlamaBridgeHandle {
    llama_model*          model       = nullptr;
    llama_context*        ctx         = nullptr;
    std::atomic<bool>     cancel_flag { false };
};

// MARK: - §2 Context lifecycle

LlamaBridgeHandle* llama_bridge_create(
    const char* model_path,
    int32_t     n_ctx,
    int32_t     n_threads,
    int32_t     n_gpu_layers)
{
    llama_backend_init();

    // ── Model load ──────────────────────────────────────────────────────────
    llama_model_params mp  = llama_model_default_params();
    mp.n_gpu_layers        = static_cast<int32_t>(n_gpu_layers);

    llama_model* model = llama_load_model_from_file(model_path, mp);
    if (!model) {
        llama_backend_free();
        return nullptr;
    }

    // ── Context creation ────────────────────────────────────────────────────
    llama_context_params cp = llama_context_default_params();
    cp.n_ctx        = static_cast<uint32_t>(n_ctx);
    cp.n_threads    = static_cast<uint32_t>(n_threads);

    llama_context* ctx = llama_new_context_with_model(model, cp);
    if (!ctx) {
        llama_free_model(model);
        llama_backend_free();
        return nullptr;
    }

    auto* handle    = new LlamaBridgeHandle();
    handle->model   = model;
    handle->ctx     = ctx;
    return handle;
}

void llama_bridge_free(LlamaBridgeHandle* handle) {
    if (!handle) { return; }
    if (handle->ctx)   { llama_free(handle->ctx);        }
    if (handle->model) { llama_free_model(handle->model); }
    llama_backend_free();
    delete handle;
}

const char* llama_bridge_version(void) {
    return llama_print_system_info();
}

// MARK: - §3 Sampler helpers

/// Greedy argmax over logits for the last decoded position.
static llama_token greedy_sample(llama_context* ctx, llama_model* model) {
    const auto* vocab  = llama_model_get_vocab(model);
    const int   n_vocab = static_cast<int>(llama_vocab_n_tokens(vocab));
    float*      logits  = llama_get_logits_ith(ctx, -1);

    llama_token best  = 0;
    float       best_v = logits[0];
    for (int i = 1; i < n_vocab; ++i) {
        if (logits[i] > best_v) {
            best_v = logits[i];
            best   = static_cast<llama_token>(i);
        }
    }
    return best;
}

/// Converts a token id to its string piece (may be multiple bytes for UTF-8).
static int token_to_str(llama_model* model, llama_token tok,
                         char* buf, int buf_size) {
    const auto* vocab = llama_model_get_vocab(model);
    return llama_token_to_piece(vocab, tok, buf, buf_size, 0, true);
}

// MARK: - §4 Generation loop (cyclomatic complexity = 7)

void llama_bridge_generate(
    LlamaBridgeHandle*  handle,
    const char*         prompt,
    int32_t             max_new_tokens,
    LlamaTokenCallback  on_token,
    LlamaFinishCallback on_finish,
    void*               user_ctx)
{
    if (!handle || !handle->model || !handle->ctx) {
        if (on_finish) { on_finish(user_ctx); }
        return;
    }

    handle->cancel_flag.store(false);

    // ── Tokenise ─────────────────────────────────────────────────────────────
    const auto* vocab = llama_model_get_vocab(handle->model);

    std::vector<llama_token> tokens(2048);
    int n = llama_tokenize(vocab, prompt,
                            static_cast<int32_t>(strlen(prompt)),
                            tokens.data(),
                            static_cast<int32_t>(tokens.size()),
                            /*add_special=*/true,
                            /*parse_special=*/true);
    if (n < 0) {
        // Buffer too small — resize and retry once
        tokens.resize(static_cast<size_t>(-n));
        n = llama_tokenize(vocab, prompt,
                            static_cast<int32_t>(strlen(prompt)),
                            tokens.data(),
                            static_cast<int32_t>(tokens.size()),
                            true, true);
    }
    if (n <= 0) {
        if (on_finish) { on_finish(user_ctx); }
        return;
    }
    tokens.resize(static_cast<size_t>(n));

    // ── Prefill ──────────────────────────────────────────────────────────────
    llama_memory_clear(llama_get_memory(handle->ctx), true);
    llama_batch batch = llama_batch_get_one(tokens.data(), static_cast<int32_t>(n));
    if (llama_decode(handle->ctx, batch) != 0) {
        if (on_finish) { on_finish(user_ctx); }
        return;
    }

    // ── Decode loop ───────────────────────────────────────────────────────────
    char piece_buf[512] = {};
    for (int step = 0; step < max_new_tokens; ++step) {
        if (handle->cancel_flag.load()) { break; }

        llama_token next = greedy_sample(handle->ctx, handle->model);

        if (llama_vocab_is_eog(vocab, next)) { break; }

        int piece_len = token_to_str(handle->model, next, piece_buf, sizeof(piece_buf));
        if (piece_len > 0) {
            piece_buf[piece_len] = '\0';
            if (on_token && !on_token(piece_buf, user_ctx)) { break; }
        }

        llama_batch next_batch = llama_batch_get_one(&next, 1);
        if (llama_decode(handle->ctx, next_batch) != 0) { break; }
    }

    if (on_finish) { on_finish(user_ctx); }
}

void llama_bridge_cancel(LlamaBridgeHandle* handle) {
    if (handle) { handle->cancel_flag.store(true); }
}
