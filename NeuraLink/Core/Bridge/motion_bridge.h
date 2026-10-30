//
//  motion_bridge.h
//  NeuraLink
//
//  C bridge over the ARDY-mini motion graphs (text encoder, text-conditioned
//  denoiser, structured decoder) through the ONNX Runtime NeuraLink already
//  ships for OpenVoice. One handle owns the three sessions; the Swift layer
//  (ARDYMotionRuntime) owns the autoregressive window state, recentering and
//  retargeting. docs/REALTIME_MOTION_PLAN.md, Phase 1.
//
//  Shapes are the fixed browser contract of
//  intsuc/Llama-3-ARDY-Mini-Core40-Browser: a 20-token window of 148-float
//  hybrid tokens (4 frames each, 80 frames), 27 joints, 2048 text conditions.
//

#ifndef MOTION_BRIDGE_H
#define MOTION_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    MOTION_BRIDGE_TOKENS            = 20,
    MOTION_BRIDGE_HYBRID_DIM        = 148,
    MOTION_BRIDGE_FRAMES            = 80,
    MOTION_BRIDGE_JOINTS            = 27,
    MOTION_BRIDGE_TEXT_DIM          = 2048,
    MOTION_BRIDGE_MOTION_DIM        = 330,
    MOTION_BRIDGE_MAX_PROMPT_TOKENS = 128
};

/// Execution providers, in the order the bridge falls back through them.
enum { MOTION_BRIDGE_PROVIDER_CPU = 0, MOTION_BRIDGE_PROVIDER_XNNPACK = 1, MOTION_BRIDGE_PROVIDER_COREML = 2 };

typedef struct MotionBridge MotionBridge;

/// Loads the text encoder, denoiser and decoder graphs from the given paths.
/// `provider` is the request; `out_provider` (optional) receives the one the
/// sessions actually use after fallback. `threads` <= 0 keeps ORT's default.
/// `cache_dir` (optional) is where the CoreML provider may keep compiled
/// models between runs, when the runtime supports it. Returns NULL on failure.
MotionBridge* motion_bridge_create(const char* text_encoder_path, const char* denoiser_path, const char* decoder_path,
                                   int32_t provider, int32_t threads, const char* cache_dir, int32_t* out_provider);

void motion_bridge_free(MotionBridge* bridge);

/// Encodes one WordPiece-tokenized prompt (`n` <= 128 ids) into the 2048
/// root/body conditions. Returns the wall time in ms, or a negative error.
double motion_bridge_encode_text(MotionBridge* bridge, const int64_t* input_ids, const int64_t* attention_mask,
                                 const int64_t* token_type_ids, int32_t n, float* out_conditions);

/// Runs the DDIM recurrence over one window. `x` holds TOKENS*HYBRID_DIM
/// floats: history tokens first, Gaussian noise in the generation slots, zero
/// after; only the generation slots are rewritten. `timesteps`, `alphas` and
/// `alphas_prev` have `steps` entries (from model.json's diffusion block).
/// `out_step_ms` (optional) receives each step's wall time. Returns the total
/// ms, or a negative error.
double motion_bridge_denoise(MotionBridge* bridge, float* x, int32_t history_tokens, int32_t generation_tokens,
                             const float* text_conditions, float cfg_weight, float first_heading_angle,
                             const int32_t* timesteps, const float* alphas, const float* alphas_prev, int32_t steps,
                             double* out_step_ms);

/// Decodes a recentered, requantized window of `valid_tokens` tokens into
/// FRAMES x JOINTS 3x3 local and global rotations (row-major), FRAMES x 3 root
/// positions, FRAMES x 4 foot contacts and the FRAMES x MOTION_DIM normalized
/// motion features (the first five per frame are the world root features the
/// next window's history is built from). Any output pointer may be NULL.
/// Returns the wall time in ms, or a negative error.
double motion_bridge_decode(MotionBridge* bridge, const float* hybrid, int32_t valid_tokens,
                            const float* global_translation, float* out_local_rotations, float* out_global_rotations,
                            float* out_root_positions, uint8_t* out_foot_contacts, float* out_normalized_motion);

/// The ONNX Runtime version string the bridge is linked against.
const char* motion_bridge_runtime_version(void);

/// The message of the last ONNX Runtime failure on this thread (empty if none).
const char* motion_bridge_last_error(void);

/// How this bridge registered the CoreML provider: "generic+cache",
/// "generic", "legacy" or "" (not registered).
const char* motion_bridge_coreml_registration(const MotionBridge* bridge);

#ifdef __cplusplus
}
#endif

#endif /* MOTION_BRIDGE_H */
