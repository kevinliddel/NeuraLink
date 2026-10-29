//
//  motion_bridge.cpp
//  NeuraLink
//
//  See motion_bridge.h. The denoiser graph batches the conditional and
//  unconditional passes itself and takes the CFG weight as an input, so one
//  session run is one DDIM step; the eta=0 update below is the browser
//  runtime's (web/src/runtime/ddim.ts), kept in float32 at the same points.
//

#include "motion_bridge.h"

#include "onnxruntime_cxx_api.h"

#include <dlfcn.h>

#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>

namespace {

constexpr int64_t kTokens         = MOTION_BRIDGE_TOKENS;
constexpr int64_t kHybrid         = MOTION_BRIDGE_HYBRID_DIM;
constexpr int64_t kFrames         = MOTION_BRIDGE_FRAMES;
constexpr int64_t kJoints         = MOTION_BRIDGE_JOINTS;
constexpr int64_t kTextDim        = MOTION_BRIDGE_TEXT_DIM;
constexpr int64_t kMotionDim      = MOTION_BRIDGE_MOTION_DIM;
constexpr int64_t kFramesPerToken = kFrames / kTokens;

// ORT 1.17's CoreML provider flags (coreml_provider_factory.h, not shipped
// with our headers). Looked up with dlsym so a build without the provider
// still links; the bridge then falls back.
constexpr uint32_t kCoreMLFlagUseCPUOnly                 = 0x001;
constexpr uint32_t kCoreMLFlagOnlyAllowStaticInputShapes = 0x008;
constexpr uint32_t kCoreMLFlagCreateMLProgram            = 0x010;
using AppendCoreMLFn                                     = OrtStatus* (*)(OrtSessionOptions*, uint32_t);

thread_local std::string lastError;

double millisecondsSince(std::chrono::steady_clock::time_point start) {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
}

// Newer runtimes register CoreML through the generic provider API with string
// options (ML Program, every compute unit, and from 1.21 a compiled-model
// cache); older ones only through the legacy flags function, found with
// dlsym so a build without the provider still links.
// Returns how the provider was registered ("generic+cache", "generic",
// "legacy") or an empty string when it could not be.
std::string appendCoreML(Ort::SessionOptions& options, const char* cache_dir) {
    std::unordered_map<std::string, std::string> coreml{
        {"ModelFormat", "MLProgram"}, {"MLComputeUnits", "ALL"}, {"RequireStaticInputShapes", "1"}};
    if (cache_dir != nullptr && cache_dir[0] != '\0') { coreml["ModelCacheDirectory"] = cache_dir; }
    for (int attempt = 0; attempt < 2; ++attempt) {
        try {
            options.AppendExecutionProvider("CoreML", coreml);
            return coreml.count("ModelCacheDirectory") ? "generic+cache" : "generic";
        } catch (const Ort::Exception& error) {
            lastError = std::string("CoreML provider: ") + error.what();
            if (attempt == 0 && coreml.erase("ModelCacheDirectory") == 0) { break; }
        }
    }
    auto fn = reinterpret_cast<AppendCoreMLFn>(dlsym(RTLD_DEFAULT, "OrtSessionOptionsAppendExecutionProvider_CoreML"));
    if (fn == nullptr) { return ""; }
    OrtStatus* status = fn(options, kCoreMLFlagCreateMLProgram | kCoreMLFlagOnlyAllowStaticInputShapes);
    if (status != nullptr) {
        lastError = std::string("CoreML provider: ") + Ort::GetApi().GetErrorMessage(status);
        Ort::GetApi().ReleaseStatus(status);
        return "";
    }
    (void)kCoreMLFlagUseCPUOnly;
    return "legacy";
}

bool appendXNNPACK(Ort::SessionOptions& options, int32_t threads) {
    try {
        std::unordered_map<std::string, std::string> xnnpack;
        if (threads > 0) { xnnpack["intra_op_num_threads"] = std::to_string(threads); }
        options.AppendExecutionProvider("XNNPACK", xnnpack);
        return true;
    } catch (const Ort::Exception&) { return false; }
}

} // namespace

struct MotionBridge {
    Ort::Env env{ORT_LOGGING_LEVEL_WARNING, "motion_bridge"};
    Ort::Session encoder{nullptr};
    Ort::Session denoiser{nullptr};
    Ort::Session decoder{nullptr};
    Ort::MemoryInfo memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    int32_t provider       = MOTION_BRIDGE_PROVIDER_CPU;
    std::string coremlRegistration;
};

extern "C" {

const char* motion_bridge_runtime_version(void) {
    return OrtGetApiBase()->GetVersionString();
}

const char* motion_bridge_last_error(void) {
    return lastError.c_str();
}

const char* motion_bridge_coreml_registration(const MotionBridge* bridge) {
    return bridge == nullptr ? "" : bridge->coremlRegistration.c_str();
}

MotionBridge* motion_bridge_create(const char* model_dir, int32_t provider, int32_t threads, const char* cache_dir,
                                   int32_t* out_provider) {
    if (model_dir == nullptr) { return nullptr; }
    auto* bridge = new (std::nothrow) MotionBridge();
    if (bridge == nullptr) { return nullptr; }
    try {
        Ort::SessionOptions options;
        options.SetGraphOptimizationLevel(ORT_ENABLE_ALL);
        if (threads > 0) { options.SetIntraOpNumThreads(threads); }
        int32_t used = MOTION_BRIDGE_PROVIDER_CPU;
        std::string registration;
        if (provider == MOTION_BRIDGE_PROVIDER_COREML && !(registration = appendCoreML(options, cache_dir)).empty()) {
            used = MOTION_BRIDGE_PROVIDER_COREML;
        } else if (provider != MOTION_BRIDGE_PROVIDER_CPU && appendXNNPACK(options, threads)) {
            used = MOTION_BRIDGE_PROVIDER_XNNPACK;
        }
        const std::string dir(model_dir);
        bridge->encoder            = Ort::Session(bridge->env, (dir + "/text_encoder.onnx").c_str(), options);
        bridge->denoiser           = Ort::Session(bridge->env, (dir + "/denoiser.onnx").c_str(), options);
        bridge->decoder            = Ort::Session(bridge->env, (dir + "/decoder.onnx").c_str(), options);
        bridge->provider           = used;
        bridge->coremlRegistration = registration;
        if (out_provider != nullptr) { *out_provider = used; }
        return bridge;
    } catch (const Ort::Exception& error) {
        lastError = std::string("session: ") + error.what();
        delete bridge;
        return nullptr;
    } catch (const std::exception& error) {
        lastError = std::string("session: ") + error.what();
        delete bridge;
        return nullptr;
    }
}

void motion_bridge_free(MotionBridge* bridge) {
    delete bridge;
}

double motion_bridge_encode_text(MotionBridge* bridge, const int64_t* input_ids, const int64_t* attention_mask,
                                 const int64_t* token_type_ids, int32_t n, float* out_conditions) {
    if (bridge == nullptr || input_ids == nullptr || attention_mask == nullptr || token_type_ids == nullptr ||
        out_conditions == nullptr || n <= 0 || n > MOTION_BRIDGE_MAX_PROMPT_TOKENS) {
        return -1;
    }
    try {
        const auto start = std::chrono::steady_clock::now();
        const std::array<int64_t, 2> shape{1, n};
        std::array<Ort::Value, 3> inputs{
            Ort::Value::CreateTensor<int64_t>(bridge->memory, const_cast<int64_t*>(input_ids), static_cast<size_t>(n),
                                              shape.data(), shape.size()),
            Ort::Value::CreateTensor<int64_t>(bridge->memory, const_cast<int64_t*>(attention_mask),
                                              static_cast<size_t>(n), shape.data(), shape.size()),
            Ort::Value::CreateTensor<int64_t>(bridge->memory, const_cast<int64_t*>(token_type_ids),
                                              static_cast<size_t>(n), shape.data(), shape.size())};
        const std::array<const char*, 3> names{"input_ids", "attention_mask", "token_type_ids"};
        const std::array<const char*, 1> outputs{"text_conditions"};
        auto result      = bridge->encoder.Run(Ort::RunOptions{nullptr}, names.data(), inputs.data(), inputs.size(),
                                               outputs.data(), outputs.size());
        const auto count = result[0].GetTensorTypeAndShapeInfo().GetElementCount();
        if (count != static_cast<size_t>(kTextDim)) { return -2; }
        std::memcpy(out_conditions, result[0].GetTensorData<float>(), sizeof(float) * static_cast<size_t>(kTextDim));
        return millisecondsSince(start);
    } catch (const Ort::Exception&) { return -3; }
}

double motion_bridge_denoise(MotionBridge* bridge, float* x, int32_t history_tokens, int32_t generation_tokens,
                             const float* text_conditions, float cfg_weight, float first_heading_angle,
                             const int32_t* timesteps, const float* alphas, const float* alphas_prev, int32_t steps,
                             double* out_step_ms) {
    if (bridge == nullptr || x == nullptr || text_conditions == nullptr || timesteps == nullptr || alphas == nullptr ||
        alphas_prev == nullptr || steps <= 0 || history_tokens < 0 || generation_tokens <= 0 ||
        history_tokens + generation_tokens > kTokens) {
        return -1;
    }
    try {
        const auto start               = std::chrono::steady_clock::now();
        const int64_t historyFrames    = history_tokens * kFramesPerToken;
        const int64_t generationFrames = generation_tokens * kFramesPerToken;
        std::vector<float> historyMask(static_cast<size_t>(kFrames), 0.0f);
        std::vector<float> generationMask(static_cast<size_t>(kFrames), 0.0f);
        std::vector<float> historyTokenMask(static_cast<size_t>(kTokens), 0.0f);
        std::vector<float> generationTokenMask(static_cast<size_t>(kTokens), 0.0f);
        std::fill_n(historyMask.begin(), historyFrames, 1.0f);
        std::fill_n(generationMask.begin() + historyFrames, generationFrames, 1.0f);
        std::fill_n(historyTokenMask.begin(), history_tokens, 1.0f);
        std::fill_n(generationTokenMask.begin() + history_tokens, generation_tokens, 1.0f);
        int64_t historyLength    = historyFrames;
        int64_t generationLength = generationFrames;
        int64_t timestep         = 0;
        float cfg                = cfg_weight;
        float heading            = first_heading_angle;

        const std::array<int64_t, 1> scalar{1};
        const std::array<int64_t, 3> xShape{1, kTokens, kHybrid};
        const std::array<int64_t, 2> frameShape{1, kFrames};
        const std::array<int64_t, 2> tokenShape{1, kTokens};
        const std::array<int64_t, 3> textShape{1, 1, kTextDim};
        std::array<Ort::Value, 11> inputs{
            Ort::Value::CreateTensor<float>(bridge->memory, &cfg, 1, scalar.data(), scalar.size()),
            Ort::Value::CreateTensor<float>(bridge->memory, x, static_cast<size_t>(kTokens * kHybrid), xShape.data(),
                                            xShape.size()),
            Ort::Value::CreateTensor<int64_t>(bridge->memory, &historyLength, 1, scalar.data(), scalar.size()),
            Ort::Value::CreateTensor<int64_t>(bridge->memory, &generationLength, 1, scalar.data(), scalar.size()),
            Ort::Value::CreateTensor<float>(bridge->memory, historyMask.data(), historyMask.size(), frameShape.data(),
                                            frameShape.size()),
            Ort::Value::CreateTensor<float>(bridge->memory, generationMask.data(), generationMask.size(),
                                            frameShape.data(), frameShape.size()),
            Ort::Value::CreateTensor<float>(bridge->memory, historyTokenMask.data(), historyTokenMask.size(),
                                            tokenShape.data(), tokenShape.size()),
            Ort::Value::CreateTensor<float>(bridge->memory, generationTokenMask.data(), generationTokenMask.size(),
                                            tokenShape.data(), tokenShape.size()),
            Ort::Value::CreateTensor<float>(bridge->memory, const_cast<float*>(text_conditions),
                                            static_cast<size_t>(kTextDim), textShape.data(), textShape.size()),
            Ort::Value::CreateTensor<int64_t>(bridge->memory, &timestep, 1, scalar.data(), scalar.size()),
            Ort::Value::CreateTensor<float>(bridge->memory, &heading, 1, scalar.data(), scalar.size())};
        const std::array<const char*, 11> names{"cfg_weight",         "x",
                                                "history_len",        "generation_len",
                                                "history_mask",       "generation_mask",
                                                "history_token_mask", "generation_token_mask",
                                                "text_conditions",    "timestep",
                                                "first_heading_angle"};
        const std::array<const char*, 1> outputs{"pred_x0"};
        const size_t generationStart = static_cast<size_t>(history_tokens * kHybrid);
        const size_t generationEnd   = static_cast<size_t>((history_tokens + generation_tokens) * kHybrid);

        for (int32_t step = 0; step < steps; ++step) {
            const auto stepStart = std::chrono::steady_clock::now();
            timestep             = timesteps[step];
            auto result = bridge->denoiser.Run(Ort::RunOptions{nullptr}, names.data(), inputs.data(), inputs.size(),
                                               outputs.data(), outputs.size());
            if (result[0].GetTensorTypeAndShapeInfo().GetElementCount() != static_cast<size_t>(kTokens * kHybrid)) {
                return -2;
            }
            const float* predicted              = result[0].GetTensorData<float>();
            const double alpha                  = alphas[step];
            const double alphaPrev              = alphas_prev[step];
            const double sqrtAlpha              = std::sqrt(alpha);
            const double sqrtReciprocalMinusOne = std::sqrt(1.0 / alpha - 1.0);
            const double sqrtPrevious           = std::sqrt(alphaPrev);
            const double sqrtOneMinusPrevious   = std::sqrt(1.0 - alphaPrev);
            for (size_t index = generationStart; index < generationEnd; ++index) {
                const double x0 = predicted[index];
                const double epsilon =
                    sqrtReciprocalMinusOne == 0.0 ? 0.0 : (x[index] / sqrtAlpha - x0) / sqrtReciprocalMinusOne;
                x[index] = static_cast<float>(x0 * sqrtPrevious + epsilon * sqrtOneMinusPrevious);
            }
            if (out_step_ms != nullptr) { out_step_ms[step] = millisecondsSince(stepStart); }
        }
        return millisecondsSince(start);
    } catch (const Ort::Exception&) { return -3; }
}

double motion_bridge_decode(MotionBridge* bridge, const float* hybrid, int32_t valid_tokens,
                            const float* global_translation, float* out_local_rotations, float* out_global_rotations,
                            float* out_root_positions, uint8_t* out_foot_contacts, float* out_normalized_motion) {
    if (bridge == nullptr || hybrid == nullptr || global_translation == nullptr || valid_tokens <= 0 ||
        valid_tokens > kTokens) {
        return -1;
    }
    try {
        const auto start = std::chrono::steady_clock::now();
        std::vector<float> padMask(static_cast<size_t>(kFrames), 0.0f);
        std::fill_n(padMask.begin(), valid_tokens * kFramesPerToken, 1.0f);
        const std::array<int64_t, 3> hybridShape{1, kTokens, kHybrid};
        const std::array<int64_t, 2> frameShape{1, kFrames};
        const std::array<int64_t, 2> translationShape{1, 3};
        std::array<Ort::Value, 3> inputs{
            Ort::Value::CreateTensor<float>(bridge->memory, const_cast<float*>(hybrid),
                                            static_cast<size_t>(kTokens * kHybrid), hybridShape.data(),
                                            hybridShape.size()),
            Ort::Value::CreateTensor<float>(bridge->memory, padMask.data(), padMask.size(), frameShape.data(),
                                            frameShape.size()),
            Ort::Value::CreateTensor<float>(bridge->memory, const_cast<float*>(global_translation), 3,
                                            translationShape.data(), translationShape.size())};
        const std::array<const char*, 3> names{"hybrid_tokens", "motion_pad_mask", "global_translation"};
        const std::array<const char*, 5> outputs{"local_rotations", "global_rotations", "root_positions",
                                                 "foot_contacts", "normalized_motion"};
        auto result = bridge->decoder.Run(Ort::RunOptions{nullptr}, names.data(), inputs.data(), inputs.size(),
                                          outputs.data(), outputs.size());
        const size_t rotations = static_cast<size_t>(kFrames * kJoints * 9);
        if (result[0].GetTensorTypeAndShapeInfo().GetElementCount() != rotations ||
            result[2].GetTensorTypeAndShapeInfo().GetElementCount() != static_cast<size_t>(kFrames * 3) ||
            result[3].GetTensorTypeAndShapeInfo().GetElementCount() != static_cast<size_t>(kFrames * 4) ||
            result[4].GetTensorTypeAndShapeInfo().GetElementCount() != static_cast<size_t>(kFrames * kMotionDim)) {
            return -2;
        }
        if (out_local_rotations != nullptr) {
            std::memcpy(out_local_rotations, result[0].GetTensorData<float>(), sizeof(float) * rotations);
        }
        if (out_global_rotations != nullptr) {
            std::memcpy(out_global_rotations, result[1].GetTensorData<float>(), sizeof(float) * rotations);
        }
        if (out_root_positions != nullptr) {
            std::memcpy(out_root_positions, result[2].GetTensorData<float>(),
                        sizeof(float) * static_cast<size_t>(kFrames * 3));
        }
        if (out_foot_contacts != nullptr) {
            const bool* contacts = result[3].GetTensorData<bool>();
            for (int64_t index = 0; index < kFrames * 4; ++index) {
                out_foot_contacts[index] = contacts[index] ? 1 : 0;
            }
        }
        if (out_normalized_motion != nullptr) {
            std::memcpy(out_normalized_motion, result[4].GetTensorData<float>(),
                        sizeof(float) * static_cast<size_t>(kFrames * kMotionDim));
        }
        return millisecondsSince(start);
    } catch (const Ort::Exception&) { return -3; }
}

} // extern "C"
