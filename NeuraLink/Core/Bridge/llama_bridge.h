//
//  llama_bridge.h
//  NeuraLink
//
//  Pure-C public API for the llama.cpp inference backend.
//  Swift imports this via the bridging header; C++ symbols stay hidden.
//
//  Created by Dedicatus on 29/04/2026.
//

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>
#include <stdbool.h>

/// Opaque inference context. Swift holds this as `OpaquePointer`.
typedef struct LlamaBridgeHandle LlamaBridgeHandle;

/// Called once per generated token (UTF-8 string, null-terminated).
/// Return `false` to stop generation after this token.
typedef bool (*LlamaTokenCallback)(const char* token, void* context);

/// Called once when generation finishes or is cancelled.
typedef void (*LlamaFinishCallback)(void* context);

// MARK: - Lifecycle

/// Create an inference context from a GGUF model file.
///
/// The sampler chain is built with sensible defaults
/// (top_k=40, top_p=0.9, temp=0.7, rep_penalty=1.1 over last 64 tokens).
LlamaBridgeHandle* llama_bridge_create(
    const char* model_path,
    int32_t     n_ctx,
    int32_t     n_threads,
    int32_t     n_gpu_layers,
    int32_t     k_type,
    int32_t     v_type
);

/// Destroy the context and release all memory.
void llama_bridge_free(LlamaBridgeHandle* handle);

// MARK: - Chat template

/// Apply the model's built-in chat template to format messages into a single
/// prompt string. Avoids hand-rolled template strings that drift between
/// model versions (Llama 3 vs Qwen 2.5 vs Qwen 3, etc.).
///
/// Returns bytes written (excluding null), or negative on error. If the
/// return value is >= out_buf_size, the buffer was too small.
int32_t llama_bridge_apply_chat_template(
    LlamaBridgeHandle* handle,
    const char* const* roles,
    const char* const* contents,
    int32_t            n_messages,
    bool               add_generation_prompt,
    char*              out_buf,
    int32_t            out_buf_size
);

// MARK: - Prompt-Lookup Decoding (PLD)

/// Enable or disable prompt-lookup speculative decoding.
///
/// PLD is speculative decoding without a separate draft model: each round,
/// the bridge looks for an n-gram match between the last `n` decoded tokens
/// and any prior position in the current context. If found, the next
/// `n_draft` tokens following that match are used as the draft and verified
/// in one batch decode. Gives 1.5–2× tok/s on conversations with repeated
/// phrasing — persona stock phrases, user names, command prefixes.
///
/// Pass `n <= 0` or `n_draft <= 0` to use defaults (n=3, n_draft=5).
void llama_bridge_set_prompt_lookup(
    LlamaBridgeHandle* handle,
    bool               enabled,
    int32_t            n,
    int32_t            n_draft
);

// MARK: - Inference

/// Generate tokens for `prompt`. Blocks the calling thread until done or
/// cancelled.
///
/// Reuses the KV cache across calls: tokens shared with the previous prompt
/// are not re-prefilled, cutting first-token latency on multi-turn chats.
/// When PLD is enabled, the decode loop also runs prompt-lookup speculative
/// decoding for additional speedup.
void llama_bridge_generate(
    LlamaBridgeHandle*  handle,
    const char*         prompt,
    int32_t             max_new_tokens,
    LlamaTokenCallback  on_token,
    LlamaFinishCallback on_finish,
    void*               context
);

/// Signal the running generation to stop cleanly after the current token.
/// Thread-safe — may be called from any thread.
void llama_bridge_cancel(LlamaBridgeHandle* handle);

// MARK: - Diagnostics

/// Returns the llama.cpp build commit string.
const char* llama_bridge_version(void);

#ifdef __cplusplus
}
#endif
