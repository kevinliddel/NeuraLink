//
//  llama_embed_bridge.h
//  NeuraLink
//
//  Pure-C API for sentence embeddings via llama.cpp (docs/CHAT_LLM_IMPROVEMENT_PLAN.md §C2).
//  A separate, tiny context from the chat model: encoder-style GGUF (e5 / bge / gemma
//  embedding) with mean pooling, returning L2-normalised vectors.
//
//  Created by Dedicatus on 26/09/2026.
//

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

/// Opaque embedding context. Swift holds this as `OpaquePointer`.
typedef struct LlamaEmbedHandle LlamaEmbedHandle;

/// Load an embedding model. `n_ctx` caps tokens per text (longer input is truncated).
/// Returns NULL when the file is missing or the model cannot be initialised.
LlamaEmbedHandle* llama_embed_create(const char* model_path, int32_t n_ctx, int32_t n_threads, int32_t n_gpu_layers);

/// Vector dimension of the loaded model.
int32_t llama_embed_dimension(const LlamaEmbedHandle* handle);

/// Embed one UTF-8 text. Writes up to `out_cap` floats (L2-normalised) into `out`.
/// Returns the dimension written, or a negative value on error / insufficient capacity.
int32_t llama_embed_text(LlamaEmbedHandle* handle, const char* text, float* out, int32_t out_cap);

/// Release the model and context.
void llama_embed_free(LlamaEmbedHandle* handle);

#ifdef __cplusplus
}
#endif
