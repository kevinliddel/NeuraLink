//
//  llama_embed_bridge.cpp
//  NeuraLink
//
//  Embedding context on top of llama.cpp. Mirrors the upstream `embedding`
//  example: tokenise with special tokens, one sequence per call, mean pooling,
//  read the pooled vector with llama_get_embeddings_seq, normalise.
//
//  Created by Dedicatus on 26/09/2026.
//

#include "llama_embed_bridge.h"

#include <llama/llama.h>

#include <cmath>
#include <cstring>
#include <mutex>
#include <vector>

struct LlamaEmbedHandle {
    llama_model* model = nullptr;
    llama_context* ctx = nullptr;
    int32_t n_ctx      = 0;
    std::mutex mutex;
};

LlamaEmbedHandle* llama_embed_create(const char* model_path, int32_t n_ctx, int32_t n_threads, int32_t n_gpu_layers) {
    if (!model_path || n_ctx <= 0) { return nullptr; }
    llama_backend_init();

    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers       = n_gpu_layers;
    llama_model* model    = llama_model_load_from_file(model_path, mp);
    if (!model) { return nullptr; }

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx                = static_cast<uint32_t>(n_ctx);
    cp.n_batch              = static_cast<uint32_t>(n_ctx);
    cp.n_ubatch             = static_cast<uint32_t>(n_ctx);
    cp.n_threads            = static_cast<uint32_t>(n_threads);
    cp.n_threads_batch      = static_cast<uint32_t>(n_threads);
    cp.embeddings           = true;
    cp.pooling_type         = LLAMA_POOLING_TYPE_MEAN;

    llama_context* ctx = llama_init_from_model(model, cp);
    if (!ctx) {
        llama_model_free(model);
        return nullptr;
    }

    auto* handle  = new LlamaEmbedHandle();
    handle->model = model;
    handle->ctx   = ctx;
    handle->n_ctx = n_ctx;
    return handle;
}

int32_t llama_embed_dimension(const LlamaEmbedHandle* handle) {
    if (!handle || !handle->model) { return 0; }
    return llama_model_n_embd(handle->model);
}

int32_t llama_embed_text(LlamaEmbedHandle* handle, const char* text, float* out, int32_t out_cap) {
    if (!handle || !handle->ctx || !text || !out) { return -1; }
    const int32_t dim = llama_model_n_embd(handle->model);
    if (dim <= 0 || out_cap < dim) { return -2; }

    std::lock_guard<std::mutex> guard(handle->mutex);

    const llama_vocab* vocab = llama_model_get_vocab(handle->model);
    const int32_t text_len   = static_cast<int32_t>(std::strlen(text));
    std::vector<llama_token> tokens(static_cast<size_t>(handle->n_ctx));
    int32_t n_tokens = llama_tokenize(vocab, text, text_len, tokens.data(), handle->n_ctx, true, true);
    if (n_tokens < 0) {
        // Longer than the context: tokenise again into the exact size and truncate.
        n_tokens = handle->n_ctx;
        tokens.resize(static_cast<size_t>(n_tokens));
        n_tokens = llama_tokenize(vocab, text, text_len, tokens.data(), n_tokens, true, true);
        if (n_tokens < 0) { n_tokens = handle->n_ctx; }
    }
    if (n_tokens <= 0) { return -3; }

    llama_memory_clear(llama_get_memory(handle->ctx), true);

    llama_batch batch = llama_batch_init(n_tokens, 0, 1);
    for (int32_t i = 0; i < n_tokens; ++i) {
        batch.token[i]     = tokens[static_cast<size_t>(i)];
        batch.pos[i]       = i;
        batch.n_seq_id[i]  = 1;
        batch.seq_id[i][0] = 0;
        batch.logits[i]    = 1; // every position feeds the mean pool
    }
    batch.n_tokens = n_tokens;

    // Embedding-only contexts have no KV cache; llama_decode would just
    // redirect to llama_encode with a warning.
    const int32_t rc = llama_encode(handle->ctx, batch);
    if (rc != 0) {
        llama_batch_free(batch);
        return -4;
    }

    const float* pooled = llama_get_embeddings_seq(handle->ctx, 0);
    if (!pooled) {
        llama_batch_free(batch);
        return -5;
    }

    double norm = 0.0;
    for (int32_t i = 0; i < dim; ++i) { norm += static_cast<double>(pooled[i]) * pooled[i]; }
    const float scale = norm > 0.0 ? static_cast<float>(1.0 / std::sqrt(norm)) : 0.0f;
    for (int32_t i = 0; i < dim; ++i) { out[i] = pooled[i] * scale; }

    llama_batch_free(batch);
    return dim;
}

void llama_embed_free(LlamaEmbedHandle* handle) {
    if (!handle) { return; }
    if (handle->ctx) { llama_free(handle->ctx); }
    if (handle->model) { llama_model_free(handle->model); }
    delete handle;
}
