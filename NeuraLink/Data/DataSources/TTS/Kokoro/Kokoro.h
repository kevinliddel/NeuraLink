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

    /// Lazy-load index. Holds (file_offset, float_count) per voice name so
    /// `get_voice_style` can fseek+read the single requested voice instead
    /// of eager-loading all 103 voices into RAM at startup (~51 MB saved
    /// on the bundled voices.bin). Combined with the ONNX arena tweaks in
    /// the constructor, this is what keeps Kokoro under the iOS memory
    /// ceiling alongside a 1B-class local LLM.
    struct VoiceEntry {
        uint64_t file_offset;
        uint32_t float_count;
    };
    std::string voices_path_;
    std::map<std::string, VoiceEntry> voice_index_;

    /// Single-slot read-through cache so back-to-back synthesis calls for the
    /// same persona don't re-read the file every chunk.
    std::string cached_voice_name_;
    std::vector<float> cached_voice_data_;

    std::unique_ptr<Tokenizer> tokenizer_;

    void load_voices(const std::string& voices_path);

    std::pair<std::vector<float>, int> _create_audio(
        const std::string& phonemes,
        const std::vector<float>& voice,
        float speed
    );

    std::vector<std::string> _split_phonemes(const std::string& phonemes);
};
