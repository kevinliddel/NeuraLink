#include "Kokoro.h"
#include <fstream>
#include <sstream>
#include <regex>
#include <numeric>
#include <cstring>

static std::vector<float> trim_audio(const std::vector<float>& audio, int sample_rate, float threshold_db = 60.0f) {
    // Simplified placeholder returning audio as-is
    (void)sample_rate;
    (void)threshold_db;
    return audio; 
}

Kokoro::Kokoro(const std::string& model_path, const std::string& voices_path, const std::string& vocab_path, const std::string& dict_path) 
    : env_(ORT_LOGGING_LEVEL_WARNING, "Kokoro")
{
    Ort::SessionOptions session_options;
    session_options.SetIntraOpNumThreads(2);
    session_options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);

    // On iOS we run on ARM64 CPU. CoreML Execution Provider is not strictly necessary
    // for this small 82M model as CPU is already extremely fast (>100x real-time).
    
#ifdef _WIN32
    std::wstring wmodel_path(model_path.begin(), model_path.end());
    session_ = Ort::Session(env_, wmodel_path.c_str(), session_options);
#else
    session_ = Ort::Session(env_, model_path.c_str(), session_options);
#endif

    load_voices(voices_path);

    TokenizerConfig config;
    config.dict_path = dict_path;
    config.vocab_path = vocab_path;
    tokenizer_ = std::make_unique<Tokenizer>(config);
}

Kokoro::~Kokoro() = default;

void Kokoro::load_voices(const std::string& voices_path) {
    std::ifstream in(voices_path, std::ios::binary);
    if (!in.is_open()) {
        std::cerr << "[Kokoro] Failed to open voices file: " << voices_path << std::endl;
        return;
    }

    char magic[4];
    in.read(magic, 4);
    if (std::strncmp(magic, "VOIC", 4) != 0) {
        std::cerr << "[Kokoro] Invalid voices file format. Expected 'VOIC'." << std::endl;
        return;
    }

    uint32_t version;
    in.read(reinterpret_cast<char*>(&version), 4);

    uint32_t num_voices;
    in.read(reinterpret_cast<char*>(&num_voices), 4);

    for (uint32_t i = 0; i < num_voices; ++i) {
        uint32_t name_len;
        in.read(reinterpret_cast<char*>(&name_len), 4);
        
        std::string name(name_len, '\0');
        in.read(&name[0], name_len);
        
        uint32_t dim;
        in.read(reinterpret_cast<char*>(&dim), 4);
        
        std::vector<float> style(dim);
        in.read(reinterpret_cast<char*>(style.data()), dim * sizeof(float));
        
        voices_[name] = style;
    }
}

std::vector<float> Kokoro::get_voice_style(const std::string& name) {
    if (voices_.find(name) != voices_.end()) {
        return voices_.at(name);
    }
    std::cerr << "[Kokoro] Voice " << name << " not found. Using default." << std::endl;
    if (!voices_.empty()) return voices_.begin()->second;
    return std::vector<float>(256, 0.0f);
}

std::vector<std::string> Kokoro::_split_phonemes(const std::string& phonemes) {
    std::vector<std::string> batches;
    std::regex re("([.,!?;])");
    std::sregex_token_iterator it(phonemes.begin(), phonemes.end(), re, {-1, 0});
    std::sregex_token_iterator end;

    std::string current_batch;
    
    for (; it != end; ++it) {
        std::string part = *it;
        part = std::regex_replace(part, std::regex("^\\s+|\\s+$"), "");
        
        if (part.empty()) continue;

        if (current_batch.length() + part.length() + 1 >= MAX_PHONEME_LENGTH) {
            batches.push_back(current_batch);
            current_batch = part;
        } else {
             if (std::string(".,!?;").find(part) != std::string::npos) {
                current_batch += part;
             } else {
                if (!current_batch.empty()) current_batch += " ";
                current_batch += part;
             }
        }
    }
    if (!current_batch.empty()) {
        batches.push_back(current_batch);
    }
    return batches;
}

std::pair<std::vector<float>, int> Kokoro::_create_audio(
    const std::string& phonemes,
    const std::vector<float>& voice,
    float speed
) {
    std::string truncated_phonemes = phonemes;
    if (phonemes.length() > MAX_PHONEME_LENGTH) {
        truncated_phonemes = phonemes.substr(0, MAX_PHONEME_LENGTH);
    }

    std::vector<int> tokens_raw = tokenizer_->tokenize(truncated_phonemes);

    std::vector<int64_t> tokens = {0};
    for (int t : tokens_raw) tokens.push_back(t);
    tokens.push_back(0);
    
    std::vector<int64_t> input_shape = {1, (int64_t)tokens.size()};
    
    const int STYLE_DIM = 256;
    std::vector<float> selected_style;
    if (voice.size() > STYLE_DIM) {
         size_t index = tokens_raw.size();
         if (index * STYLE_DIM + STYLE_DIM <= voice.size()) {
              auto start = voice.begin() + index * STYLE_DIM;
              selected_style.assign(start, start + STYLE_DIM);
         } else {
              selected_style.assign(voice.begin(), voice.begin() + STYLE_DIM);
         }
    } else {
        selected_style = voice;
    }

    std::vector<int64_t> style_shape = {1, (int64_t)selected_style.size()};
    std::vector<int64_t> speed_shape = {1};
    std::vector<float> speed_tensor = {speed};

    bool use_new_schema = false;
    size_t num_inputs = session_.GetInputCount();
    for (size_t i = 0; i < num_inputs; i++) {
        auto name_ptr = session_.GetInputNameAllocated(i, allocator_);
        if (std::string(name_ptr.get()) == "input_ids") {
            use_new_schema = true;
        }
    }

    std::vector<const char*> inputs;
    if (use_new_schema) {
        inputs = {"input_ids", "style", "speed"};
    } else {
        inputs = {"tokens", "style", "speed"};
    }
    
    std::vector<Ort::Value> input_tensors;
    auto memory_info = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    
    input_tensors.push_back(Ort::Value::CreateTensor<int64_t>(
        memory_info, tokens.data(), tokens.size(), input_shape.data(), input_shape.size()));
        
    input_tensors.push_back(Ort::Value::CreateTensor<float>(
        memory_info, selected_style.data(), selected_style.size(), style_shape.data(), style_shape.size()));
    
    // speed parameter mapping
    int speed_int = (int)speed;
    if (use_new_schema) {
        input_tensors.push_back(Ort::Value::CreateTensor<int>(
            memory_info, &speed_int, 1, speed_shape.data(), speed_shape.size()));
    } else {
        input_tensors.push_back(Ort::Value::CreateTensor<float>(
            memory_info, speed_tensor.data(), speed_tensor.size(), speed_shape.data(), speed_shape.size()));
    }

    auto out_name_ptr = session_.GetOutputNameAllocated(0, allocator_);
    std::vector<const char*> output_names_vec = {out_name_ptr.get()};

    auto output_tensors = session_.Run(
        Ort::RunOptions{nullptr},
        inputs.data(),
        input_tensors.data(),
        input_tensors.size(),
        output_names_vec.data(),
        1
    );
    
    float* floatarr = output_tensors[0].GetTensorMutableData<float>();
    size_t output_len = output_tensors[0].GetTensorTypeAndShapeInfo().GetElementCount();
    
    std::vector<float> audio(floatarr, floatarr + output_len);
    return {audio, SAMPLE_RATE};
}

std::pair<std::vector<float>, int> Kokoro::create(
    const std::string& text,
    const std::vector<float>& voice_style,
    float speed,
    bool is_phonemes,
    bool trim
) {
    std::string phonemes = text;
    if (!is_phonemes) {
        phonemes = tokenizer_->phonemize(text);
    }
    
    auto batched_phonemes = _split_phonemes(phonemes);
    std::vector<float> full_audio;
    
    for (const auto& batch : batched_phonemes) {
        auto [audio_part, sr] = _create_audio(batch, voice_style, speed);
        if (trim) {
            audio_part = trim_audio(audio_part, sr);
        }
        full_audio.insert(full_audio.end(), audio_part.begin(), audio_part.end());
    }
    
    return {full_audio, SAMPLE_RATE};
}

std::pair<std::vector<float>, int> Kokoro::create(
    const std::string& text,
    const std::string& voice_name,
    float speed,
    bool is_phonemes,
    bool trim
) {
    return create(text, get_voice_style(voice_name), speed, is_phonemes, trim);
}
