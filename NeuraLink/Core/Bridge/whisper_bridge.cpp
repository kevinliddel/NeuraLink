//
//  whisper_bridge.cpp
//  NeuraLink
//
//  C++ implementation of the whisper_bridge C API over whisper.cpp's C API.
//  Ported verbatim (renamed) from SynapLink's synap_whisper.cpp.
//

#include "whisper_bridge.h"

#include <whisper/whisper.h>

#include <cstring>
#include <string>

struct WhisperBridge {
    whisper_context* ctx = nullptr;
    int32_t n_threads    = 4;
};

WhisperBridge* whisper_bridge_create(const char* model_path, bool use_gpu, int32_t n_threads) {
    if (!model_path) { return nullptr; }

    whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu                = use_gpu;
    cparams.flash_attn             = false;

    whisper_context* ctx = whisper_init_from_file_with_params(model_path, cparams);
    if (!ctx) { return nullptr; }

    auto* w      = new WhisperBridge();
    w->ctx       = ctx;
    w->n_threads = n_threads > 0 ? n_threads : 4;
    return w;
}

void whisper_bridge_free(WhisperBridge* whisper) {
    if (!whisper) { return; }
    if (whisper->ctx) { whisper_free(whisper->ctx); }
    delete whisper;
}

int32_t whisper_bridge_transcribe(WhisperBridge* whisper, const float* samples, int32_t n_samples, const char* language,
                                  char* out_buf, int32_t out_buf_size) {
    if (!whisper || !whisper->ctx || !samples || n_samples <= 0 || !out_buf || out_buf_size <= 0) { return -1; }

    whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads           = whisper->n_threads;
    params.print_progress      = false;
    params.print_realtime      = false;
    params.print_timestamps    = false;
    params.translate           = false;
    params.no_timestamps       = true;
    params.suppress_blank      = true;
    if (language && language[0] != '\0' && std::string(language) != "auto") {
        params.language        = language;
        params.detect_language = false;
    } else {
        params.language        = "auto";
        params.detect_language = true;
    }

    if (whisper_full(whisper->ctx, params, samples, n_samples) != 0) { return -2; }

    std::string text;
    const int n_segments = whisper_full_n_segments(whisper->ctx);
    for (int i = 0; i < n_segments; ++i) {
        const char* seg = whisper_full_get_segment_text(whisper->ctx, i);
        if (seg) { text += seg; }
    }

    // Trim the leading space whisper segments usually carry.
    const auto begin = text.find_first_not_of(" \t\n\r");
    if (begin == std::string::npos) {
        out_buf[0] = '\0';
        return 0;
    }
    const auto end = text.find_last_not_of(" \t\n\r");
    text           = text.substr(begin, end - begin + 1);

    const int32_t total = static_cast<int32_t>(text.size());
    const int32_t n     = total < out_buf_size - 1 ? total : out_buf_size - 1;
    memcpy(out_buf, text.data(), static_cast<size_t>(n));
    out_buf[n] = '\0';
    return total;
}
