#pragma once
#include <string>
#include <vector>
#include <map>
#include <memory>
#include "EnG2P.h"

struct TokenizerConfig {
    std::string dict_path = "";
    std::string vocab_path = "";
};

class Tokenizer {
public:
    Tokenizer(const TokenizerConfig& config = {});
    ~Tokenizer();
    
    std::vector<int> tokenize(const std::string& phonemes);
    std::string phonemize(const std::string& text, bool norm = true);

private:
    std::map<std::string, int> vocab_;
    std::unique_ptr<EnG2P> eng_g2p_;
    
    void load_vocab(const std::string& path);
};
