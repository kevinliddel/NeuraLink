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
/// - Parameters:
///   - model_path: Absolute path to the `.gguf` file.
///   - n_ctx:      KV-cache token capacity. Use 256 on 4 GB devices.
///   - n_threads:  CPU threads for ops not offloaded to Metal (4 on A13).
///   - n_gpu_layers: Transformer layers to offload to Metal GPU.
///                   Pass 999 to offload all layers.
///
/// - Returns: Opaque handle, or NULL on failure (model not found / OOM).
LlamaBridgeHandle* llama_bridge_create(
    const char* model_path,
    int32_t     n_ctx,
    int32_t     n_threads,
    int32_t     n_gpu_layers
);

/// Destroy the context and release all memory.
/// Safe to call from any thread after generation finishes.
void llama_bridge_free(LlamaBridgeHandle* handle);

// MARK: - Inference

/// Generate tokens for `prompt`. Blocks the calling thread until done or cancelled.
///
/// - Parameters:
///   - handle:         Context returned by `llama_bridge_create`.
///   - prompt:         Full prompt string (UTF-8, null-terminated).
///   - max_new_tokens: Maximum number of new tokens to generate.
///   - on_token:       Callback invoked per token. Return false to stop early.
///   - on_finish:      Callback invoked once when generation ends.
///   - context:        Opaque pointer forwarded to both callbacks.
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

/// Returns the llama.cpp build commit string (e.g. "b5200").
const char* llama_bridge_version(void);

#ifdef __cplusplus
}
#endif
