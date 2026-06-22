//
//  openvoice_bridge.cpp
//  NeuraLink
//
//  MeloTTS (no-BERT) -> tone-color converter, both ONNX via ONNX Runtime.
//  Ported verbatim (renamed) from SynapLink's synap_voice.cpp.
//  The STFT between melo and the converter MUST match openvoice's
//  spectrogram_torch exactly (periodic Hann, reflect pad (n_fft-hop)/2,
//  center=False, magnitude sqrt(re^2+im^2+1e-6)), or the converter gets a bad
//  spectrogram. Accelerate (vDSP) does the FFT and the 2:1 resample (MeloTTS is
//  44.1 kHz, the converter wants 22.05 kHz).
//

#include "openvoice_bridge.h"

#include "onnxruntime_cxx_api.h"

#include <Accelerate/Accelerate.h>

#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr int kNFFT = 1024;
constexpr int kHop = 256;
constexpr int kWin = 1024;
constexpr int kSpecBins = kNFFT / 2 + 1;  // 513
constexpr int kLog2N = 10;                // 1024
constexpr int kReflectPad = (kNFFT - kHop) / 2;  // 384
constexpr int kOutSR = 22050;  // converter rate; MeloTTS (44.1k) is decimated 2:1
constexpr int kLPTaps = 64;  // 2:1 anti-alias lowpass

std::vector<float> make_lowpass() {
    // Hann-windowed sinc, cutoff 0.25 cycles/sample (= 11.025 kHz at 44.1 kHz).
    std::vector<float> h(kLPTaps);
    const double fc = 0.25, mid = (kLPTaps - 1) / 2.0;
    double sum = 0;
    for (int n = 0; n < kLPTaps; ++n) {
        double x = n - mid;
        double sinc = (x == 0.0) ? 2.0 * fc : std::sin(2.0 * M_PI * fc * x) / (M_PI * x);
        double w = 0.5 - 0.5 * std::cos(2.0 * M_PI * n / (kLPTaps - 1));
        h[n] = static_cast<float>(sinc * w);
        sum += h[n];
    }
    for (float& v : h) { v /= static_cast<float>(sum); }  // unity DC gain
    return h;
}

}  // namespace

constexpr int kBertDim = 768;  // bert-base-uncased hidden -> ja_bert channels

struct OpenVoiceBridge {
    Ort::Env env{ORT_LOGGING_LEVEL_WARNING, "openvoice_bridge"};
    Ort::Session melo{nullptr};
    Ort::Session converter{nullptr};
    Ort::Session bert{nullptr};  // optional prosody BERT (may be unset)
    bool has_bert = false;
    Ort::MemoryInfo mem = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    FFTSetup fft = nullptr;
    std::vector<float> hann;     // periodic Hann(1024)
    std::vector<float> lowpass;  // 2:1 decimation FIR

    // --- reflect-pad + STFT magnitude, matching spectrogram_torch ---
    std::vector<float> stft(const std::vector<float>& y, int& n_frames) {
        const int n = static_cast<int>(y.size());
        const int padded = n + 2 * kReflectPad;
        std::vector<float> p(padded);
        for (int i = 0; i < kReflectPad; ++i) { p[i] = y[kReflectPad - i]; }          // left reflect (excl. y[0])
        std::memcpy(p.data() + kReflectPad, y.data(), n * sizeof(float));
        for (int i = 0; i < kReflectPad; ++i) { p[kReflectPad + n + i] = y[n - 2 - i]; }  // right reflect

        n_frames = 1 + (padded - kNFFT) / kHop;
        std::vector<float> spec(static_cast<size_t>(kSpecBins) * n_frames);  // [bin][frame]

        std::vector<float> frame(kNFFT), realp(kNFFT / 2), imagp(kNFFT / 2);
        DSPSplitComplex split{realp.data(), imagp.data()};
        for (int f = 0; f < n_frames; ++f) {
            const int start = f * kHop;
            vDSP_vmul(p.data() + start, 1, hann.data(), 1, frame.data(), 1, kNFFT);
            vDSP_ctoz(reinterpret_cast<DSPComplex*>(frame.data()), 2, &split, 1, kNFFT / 2);
            vDSP_fft_zrip(fft, &split, 1, kLog2N, FFT_FORWARD);
            // vDSP packs DC in realp[0], Nyquist in imagp[0], and scales by 2.
            const float dc = 0.5f * realp[0];
            const float nyq = 0.5f * imagp[0];
            spec[static_cast<size_t>(0) * n_frames + f] = std::sqrt(dc * dc + 1e-6f);
            for (int k = 1; k < kNFFT / 2; ++k) {
                const float re = 0.5f * realp[k], im = 0.5f * imagp[k];
                spec[static_cast<size_t>(k) * n_frames + f] = std::sqrt(re * re + im * im + 1e-6f);
            }
            spec[static_cast<size_t>(kNFFT / 2) * n_frames + f] = std::sqrt(nyq * nyq + 1e-6f);
        }
        return spec;
    }

    // --- BERT prosody: input_ids -> hidden[-3] -> ja_bert[768, n] ---
    // Repeats token i's 768-vec word2ph[i] times along the phone axis (melo's
    // get_bert_feature). Layout matches melo's ja_bert input [1, 768, n].
    std::vector<float> build_ja_bert(const int64_t* input_ids, const int32_t* word2ph,
                                     int n_ids, int n) {
        std::vector<float> ja(static_cast<size_t>(kBertDim) * n, 0.0f);
        std::vector<int64_t> mask(n_ids, 1), ttype(n_ids, 0);
        std::vector<int64_t> shape{1, n_ids};
        Ort::Value in[] = {
            Ort::Value::CreateTensor<int64_t>(mem, const_cast<int64_t*>(input_ids), n_ids, shape.data(), 2),
            Ort::Value::CreateTensor<int64_t>(mem, mask.data(), n_ids, shape.data(), 2),
            Ort::Value::CreateTensor<int64_t>(mem, ttype.data(), n_ids, shape.data(), 2),
        };
        const char* in_names[] = {"input_ids", "attention_mask", "token_type_ids"};
        const char* out_names[] = {"hidden"};
        auto out = bert.Run(Ort::RunOptions{nullptr}, in_names, in, 3, out_names, 1);
        const float* hidden = out[0].GetTensorMutableData<float>();  // [n_ids, 768] row-major
        int col = 0;
        for (int i = 0; i < n_ids && col < n; ++i) {
            for (int r = 0; r < word2ph[i] && col < n; ++r, ++col) {
                for (int c = 0; c < kBertDim; ++c) {
                    ja[static_cast<size_t>(c) * n + col] = hidden[static_cast<size_t>(i) * kBertDim + c];
                }
            }
        }
        return ja;
    }

    // --- 2:1 anti-aliased decimation, 44.1 kHz -> 22.05 kHz ---
    std::vector<float> resample_half(const float* x, int n) {
        const int outN = n / 2, half = kLPTaps / 2;
        std::vector<float> out(outN, 0.0f);
        for (int m = 0; m < outN; ++m) {
            const int center = m * 2;
            float acc = 0;
            for (int k = 0; k < kLPTaps; ++k) {
                const int idx = center - half + k;
                if (idx >= 0 && idx < n) { acc += x[idx] * lowpass[k]; }
            }
            out[m] = acc;
        }
        return out;
    }
};

extern "C" {

OpenVoiceBridge* openvoice_bridge_create(const char* melo_path, const char* converter_path,
                                         const char* bert_path) {
    if (!melo_path || !converter_path) { return nullptr; }
    try {
        auto* v = new OpenVoiceBridge();
        Ort::SessionOptions opt;
        // melo + converter are sequential and compute-bound; use all cores
        // (A13 = 6) rather than pinning to 2. Biggest lever on synth throughput.
        const unsigned cores = std::thread::hardware_concurrency();
        opt.SetIntraOpNumThreads(cores > 0 ? static_cast<int>(cores) : 4);
        opt.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
        v->melo = Ort::Session(v->env, melo_path, opt);
        v->converter = Ort::Session(v->env, converter_path, opt);
        if (bert_path) {
            v->bert = Ort::Session(v->env, bert_path, opt);
            v->has_bert = true;
        }
        v->fft = vDSP_create_fftsetup(kLog2N, FFT_RADIX2);
        v->hann.resize(kWin);
        for (int i = 0; i < kWin; ++i) { v->hann[i] = 0.5f - 0.5f * std::cos(2.0f * M_PI * i / kWin); }
        v->lowpass = make_lowpass();
        if (!v->fft) { delete v; return nullptr; }
        return v;
    } catch (const std::exception&) {
        return nullptr;
    }
}

void openvoice_bridge_free(OpenVoiceBridge* v) {
    if (!v) { return; }
    if (v->fft) { vDSP_destroy_fftsetup(v->fft); }
    delete v;
}

int32_t openvoice_bridge_say(OpenVoiceBridge* v,
                             const int64_t* phones, const int64_t* tones, const int64_t* langs,
                             int32_t n, int64_t sid, const float* src_se, const float* tgt_se,
                             const int64_t* input_ids, const int32_t* word2ph, int32_t n_ids,
                             float** out_audio, double* out_stage_ms) {
    if (!v || !phones || !tones || !langs || n <= 0 || !src_se || !tgt_se || !out_audio) { return -1; }
    using clock = std::chrono::steady_clock;
    auto since = [](clock::time_point a) {
        return std::chrono::duration<double, std::milli>(clock::now() - a).count();
    };
    try {
        // ---- MeloTTS: phones/tones/langs + bert -> 44.1 kHz audio ----
        // bert (1024-dim slot) is zero for English; ja_bert (768) carries the
        // prosody when a BERT session + alignment are supplied, else zeros.
        const int64_t len = n;
        std::vector<int64_t> shape_seq{1, len};
        std::vector<float> bert_f(static_cast<size_t>(1024) * n, 0.0f);
        std::vector<float> ja_bert_f;
        auto t_bert = clock::now();
        if (v->has_bert && input_ids && word2ph && n_ids > 0) {
            ja_bert_f = v->build_ja_bert(input_ids, word2ph, n_ids, n);
        } else {
            ja_bert_f.assign(static_cast<size_t>(768) * n, 0.0f);
        }
        const double bert_ms = since(t_bert);
        int64_t xlen = len, sidv = sid;
        std::vector<int64_t> shape_bert{1, 1024, len}, shape_ja{1, 768, len}, one{1};

        Ort::Value melo_in[] = {
            Ort::Value::CreateTensor<int64_t>(v->mem, const_cast<int64_t*>(phones), n, shape_seq.data(), 2),
            Ort::Value::CreateTensor<int64_t>(v->mem, &xlen, 1, one.data(), 1),
            Ort::Value::CreateTensor<int64_t>(v->mem, &sidv, 1, one.data(), 1),
            Ort::Value::CreateTensor<int64_t>(v->mem, const_cast<int64_t*>(tones), n, shape_seq.data(), 2),
            Ort::Value::CreateTensor<int64_t>(v->mem, const_cast<int64_t*>(langs), n, shape_seq.data(), 2),
            Ort::Value::CreateTensor<float>(v->mem, bert_f.data(), bert_f.size(), shape_bert.data(), 3),
            Ort::Value::CreateTensor<float>(v->mem, ja_bert_f.data(), ja_bert_f.size(), shape_ja.data(), 3),
        };
        const char* melo_in_names[] = {"x", "x_lengths", "sid", "tones", "lang_ids", "bert", "ja_bert"};
        const char* melo_out_names[] = {"audio"};
        auto t_melo = clock::now();
        auto melo_out = v->melo.Run(Ort::RunOptions{nullptr}, melo_in_names, melo_in, 7, melo_out_names, 1);
        const double melo_ms = since(t_melo);
        float* a44 = melo_out[0].GetTensorMutableData<float>();
        auto a44_shape = melo_out[0].GetTensorTypeAndShapeInfo().GetShape();
        int n44 = static_cast<int>(a44_shape[a44_shape.size() - 1]);

        // ---- resample 44.1k -> 22.05k, STFT ----
        auto t_spec = clock::now();
        std::vector<float> a22 = v->resample_half(a44, n44);
        int n_frames = 0;
        std::vector<float> spec = v->stft(a22, n_frames);
        const double spec_ms = since(t_spec);

        // ---- converter: spec + source/target embeddings -> 22.05 kHz audio ----
        auto t_conv = clock::now();
        int64_t t = n_frames;
        std::vector<int64_t> shape_spec{1, kSpecBins, t}, shape_se{1, 256, 1};
        Ort::Value conv_in[] = {
            Ort::Value::CreateTensor<float>(v->mem, spec.data(), spec.size(), shape_spec.data(), 3),
            Ort::Value::CreateTensor<int64_t>(v->mem, &t, 1, one.data(), 1),
            Ort::Value::CreateTensor<float>(v->mem, const_cast<float*>(src_se), 256, shape_se.data(), 3),
            Ort::Value::CreateTensor<float>(v->mem, const_cast<float*>(tgt_se), 256, shape_se.data(), 3),
        };
        const char* conv_in_names[] = {"spec", "lengths", "src_se", "tgt_se"};
        const char* conv_out_names[] = {"audio"};
        auto conv_out = v->converter.Run(Ort::RunOptions{nullptr}, conv_in_names, conv_in, 4, conv_out_names, 1);
        const double conv_ms = since(t_conv);
        float* aout = conv_out[0].GetTensorMutableData<float>();
        auto out_shape = conv_out[0].GetTensorTypeAndShapeInfo().GetShape();
        int nout = static_cast<int>(out_shape[out_shape.size() - 1]);

        float* buf = static_cast<float*>(std::malloc(static_cast<size_t>(nout) * sizeof(float)));
        if (!buf) { return -2; }
        std::memcpy(buf, aout, static_cast<size_t>(nout) * sizeof(float));
        *out_audio = buf;
        if (out_stage_ms) {
            out_stage_ms[0] = bert_ms; out_stage_ms[1] = melo_ms;
            out_stage_ms[2] = spec_ms; out_stage_ms[3] = conv_ms;
        }
        return nout;
    } catch (const std::exception&) {
        return -3;
    }
}

void openvoice_bridge_free_audio(float* audio) { std::free(audio); }

int32_t openvoice_bridge_sample_rate(void) { return kOutSR; }

}  // extern "C"
