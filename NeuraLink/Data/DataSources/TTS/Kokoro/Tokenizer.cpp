#include "Tokenizer.h"
#include <iostream>
#include <fstream>
#include <sstream>
#include <regex>
#include <algorithm>

Tokenizer::Tokenizer(const TokenizerConfig& config) {
    if (!config.dict_path.empty()) {
        eng_g2p_ = std::make_unique<EnG2P>(config.dict_path);
    }
    if (!config.vocab_path.empty()) {
        load_vocab(config.vocab_path);
    }
}

Tokenizer::~Tokenizer() = default;

void Tokenizer::load_vocab(const std::string& path) {
    std::ifstream in(path);
    if (!in.is_open()) {
        std::cerr << "[Tokenizer] Warning: Failed to open vocab file: " << path << std::endl;
        return;
    }
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty()) continue;
        size_t tab = line.find('\t');
        if (tab != std::string::npos) {
            std::string token = line.substr(0, tab);
            std::string id_str = line.substr(tab + 1);
            
            // Unescape token if needed (\n, \r, \t)
            size_t pos = 0;
            while ((pos = token.find("\\n", pos)) != std::string::npos) { token.replace(pos, 2, "\n"); pos += 1; }
            pos = 0;
            while ((pos = token.find("\\r", pos)) != std::string::npos) { token.replace(pos, 2, "\r"); pos += 1; }
            pos = 0;
            while ((pos = token.find("\\t", pos)) != std::string::npos) { token.replace(pos, 2, "\t"); pos += 1; }
            
            try {
                vocab_[token] = std::stoi(id_str);
            } catch (...) {}
        }
    }
}

static std::vector<std::string> split_utf8(const std::string& str) {
    std::vector<std::string> chars;
    for (size_t i = 0; i < str.length();) {
        unsigned char c = static_cast<unsigned char>(str[i]);
        size_t char_len = 0;
        if (c < 0x80) char_len = 1;
        else if ((c & 0xE0) == 0xC0) char_len = 2;
        else if ((c & 0xE0) == 0xE0) char_len = 3;
        else if ((c & 0xF0) == 0xF0) char_len = 4;
        else char_len = 1; 

        if (i + char_len > str.length()) char_len = str.length() - i;
        
        chars.push_back(str.substr(i, char_len));
        i += char_len;
    }
    return chars;
}

std::vector<int> Tokenizer::tokenize(const std::string& phonemes) {
    std::vector<int> tokens;
    std::vector<std::string> chars = split_utf8(phonemes);
    
    for (const auto& c : chars) {
        if (vocab_.count(c)) {
            tokens.push_back(vocab_.at(c));
        }
    }
    return tokens;
}

static std::string map_punctuation(std::string text) {
    // Map smart punctuation to standard ASCII format
    size_t pos = 0;
    while ((pos = text.find("、", pos)) != std::string::npos) { text.replace(pos, 3, ", "); pos += 2; }
    pos = 0;
    while ((pos = text.find("，", pos)) != std::string::npos) { text.replace(pos, 3, ", "); pos += 2; }
    pos = 0;
    while ((pos = text.find("。", pos)) != std::string::npos) { text.replace(pos, 3, ". "); pos += 2; }
    pos = 0;
    while ((pos = text.find("！", pos)) != std::string::npos) { text.replace(pos, 3, "! "); pos += 2; }
    pos = 0;
    while ((pos = text.find("？", pos)) != std::string::npos) { text.replace(pos, 3, "? "); pos += 2; }
    pos = 0;
    while ((pos = text.find("：", pos)) != std::string::npos) { text.replace(pos, 3, ": "); pos += 2; }
    pos = 0;
    while ((pos = text.find("；", pos)) != std::string::npos) { text.replace(pos, 3, "; "); pos += 2; }
    pos = 0;
    while ((pos = text.find("“", pos)) != std::string::npos) { text.replace(pos, 3, "\""); pos += 1; }
    pos = 0;
    while ((pos = text.find("”", pos)) != std::string::npos) { text.replace(pos, 3, "\""); pos += 1; }
    
    // Trim leading and trailing spaces
    size_t first = text.find_first_not_of(" \t\n\r");
    if (std::string::npos == first) return text;
    size_t last = text.find_last_not_of(" \t\n\r");
    return text.substr(first, (last - first + 1));
}

std::string Tokenizer::phonemize(const std::string& text, bool norm) {
    if (!eng_g2p_) return text;
    
    std::string mapped = map_punctuation(text);
    std::string result;
    std::string current_word;
    
    for (size_t i = 0; i < mapped.length(); ++i) {
        char c = mapped[i];
        if (isalpha(c) || c == '\'') {
            current_word += c;
        } else {
            if (!current_word.empty()) {
                result += eng_g2p_->convert(current_word);
                current_word.clear();
            }
            result += c;
        }
    }
    if (!current_word.empty()) {
        result += eng_g2p_->convert(current_word);
    }
    
    return result;
}
