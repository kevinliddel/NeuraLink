//
//  whisper_bridge.h
//  NeuraLink
//
//  Pure-C bridge to whisper.cpp — on-device speech-to-text. Ported from
//  SynapLink's proven `synap_whisper` bridge (validated on the iPhone 11 / A13
//  tier). Swift imports this through NeuraLink-Bridging-Header.h; the
//  whisper/ggml C++ symbols stay inside whisper.xcframework.
//
//  Replaces WhisperKit (CoreML) for local STT: multilingual (ggml-base handles
//  Japanese, which the old `openai_whisper-tiny.en` could not) and lighter on
//  memory/ANE. On A13 the encoder must run on CPU (Metal lacks simdgroup-matrix
//  → garbage encoder output) — callers pass use_gpu=false there.
//
//  Audio contract: mono float32 PCM at 16 kHz (WHISPER_BRIDGE_SAMPLE_RATE).
//  The caller decodes the recording to that format (AVAudioConverter) and feeds
//  the float samples directly — no WAV round-trip.
//

#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define WHISPER_BRIDGE_SAMPLE_RATE 16000

/// Opaque transcriber. Swift holds this as `OpaquePointer`.
typedef struct WhisperBridge WhisperBridge;

/// Load a whisper GGML model (ggml-base.bin / ggml-tiny.bin ...). `use_gpu`
/// runs the encoder on Metal where available (keep false on A13). Returns NULL
/// on failure.
WhisperBridge* whisper_bridge_create(const char* model_path, bool use_gpu, int32_t n_threads);

/// Release the model and all state.
void whisper_bridge_free(WhisperBridge* whisper);

/// Transcribe mono float32 PCM at 16 kHz. `language` is an ISO code
/// ("ja", "en", ...) or NULL/"auto" to auto-detect. The recognized text is
/// written to `out_buf` (null-terminated). Returns the number of bytes written
/// (excluding null), or negative on error:
///   -1 invalid arguments   -2 transcription failed
int32_t whisper_bridge_transcribe(WhisperBridge* whisper, const float* samples, int32_t n_samples, const char* language,
                                  char* out_buf, int32_t out_buf_size);

#ifdef __cplusplus
}
#endif
