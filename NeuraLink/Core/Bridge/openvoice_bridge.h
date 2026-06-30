//
//  openvoice_bridge.h
//  NeuraLink
//
//  C bridge over the on-device OpenVoice TTS: MeloTTS VITS -> tone-color
//  converter, both ONNX via ONNX Runtime. Ported from SynapLink's proven
//  `synap_voice` bridge. Reuses the ONNX Runtime NeuraLink already ships
//  (headers under Dependencies/Kokoro/include — on HEADER_SEARCH_PATHS — plus
//  the voicevox_onnxruntime framework). The OpenVoice engine is the local TTS
//  for every non-Japanese voice (VoiceVox stays for the JP model).
//
//  One call synthesizes a single g2p'd text chunk in a target voice and returns
//  22.05 kHz mono float audio. An optional bert-base session supplies prosody
//  (ja_bert). The Swift layer (OpenVoiceEngine) handles g2p, chunking, and
//  playback via TTSEngineProtocol's onBufferReady.
//

#ifndef OPENVOICE_BRIDGE_H
#define OPENVOICE_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OpenVoiceBridge OpenVoiceBridge;

/// Load the MeloTTS + converter ONNX models, plus an optional prosody BERT
/// (pass NULL to synthesize without intonation / ja_bert=0). Returns NULL on failure.
OpenVoiceBridge* openvoice_bridge_create(const char* melo_onnx_path, const char* converter_onnx_path,
                                         const char* bert_onnx_path);

void openvoice_bridge_free(OpenVoiceBridge* voice);

/// Synthesize one chunk in the target voice.
///   phones/tones/langs : int64 arrays of length `n` (from the g2p frontend)
///   sid                : MeloTTS speaker id (EN-US)
///   src_se / tgt_se    : 256-float speaker embeddings (base source / target voice)
///   input_ids/word2ph  : BERT WordPiece ids (len `n_ids`) + per-id phone counts
///                        (sum == n). Pass NULL / n_ids<=0 for no intonation.
///   out_audio          : receives a malloc'd 22.05 kHz mono float buffer
///   out_stage_ms       : optional; if non-NULL, receives 4 stage timings in ms
///                        [bert, melo, spec, converter] for profiling.
/// Returns the sample count (>0), or a negative error code. Free with
/// openvoice_bridge_free_audio.
int32_t openvoice_bridge_say(OpenVoiceBridge* voice, const int64_t* phones, const int64_t* tones, const int64_t* langs,
                             int32_t n, int64_t sid, const float* src_se, const float* tgt_se, const int64_t* input_ids,
                             const int32_t* word2ph, int32_t n_ids, float** out_audio, double* out_stage_ms);

void openvoice_bridge_free_audio(float* audio);

/// Output sample rate of openvoice_bridge_say (22050).
int32_t openvoice_bridge_sample_rate(void);

#ifdef __cplusplus
}
#endif

#endif /* OPENVOICE_BRIDGE_H */
