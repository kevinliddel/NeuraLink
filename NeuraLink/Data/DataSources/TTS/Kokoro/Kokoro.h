#pragma once

#include <string>
#include <vector>
#include <memory>
#include <map>
#include <optional>
#include <iostream>
#include <algorithm>
#include <cmath>
#include "onnxruntime_cxx_api.h"
#include "Tokenizer.h"

const int MAX_PHONEME_LENGTH = 510;
const int SAMPLE_RATE = 24000;

class Kokoro {
public:
    Kokoro(const std::string& model_path, const std::string& voices_path, const std::string& vocab_path, const std::string& dict_path);
    ~Kokoro();

    std::vector<float> get_voice_style(const std::string& name);

    std::pair<std::vector<float>, int> create(
        const std::string& text,
        const std::string& voice_name,
        float speed = 1.0f,
        bool is_phonemes = false,
        bool trim = true
    );

    std::pair<std::vector<float>, int> create(
        const std::string& text,
        const std::vector<float>& voice_style,
        float speed = 1.0f,
        bool is_phonemes = false,
        bool trim = true
    );

private:
    Ort::Env env_;
    Ort::Session session_{nullptr};
    Ort::AllocatorWithDefaultOptions allocator_;
    
    std::map<std::string, std::vector<float>> voices_;
    std::unique_ptr<Tokenizer> tokenizer_;
    
    void load_voices(const std::string& voices_path);
    
    std::pair<std::vector<float>, int> _create_audio(
        const std::string& phonemes,
        const std::vector<float>& voice,
        float speed
    );

    std::vector<std::string> _split_phonemes(const std::string& phonemes);
};
