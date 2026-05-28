#pragma once
#include <string>
#include <unordered_map>
#include <vector>
#include <fstream>
#include <sstream>
#include <iostream>
#include <algorithm>

class EnG2P {
public:
    EnG2P(const std::string& dict_path) {
        load_dict(dict_path);
        init_arpabet_map();
    }

    std::string convert(const std::string& word) {
        std::string upper_word = word;
        
        // Trim common punctuation from ends just in case
        size_t start = 0;
        while (start < upper_word.size() && !isalnum((unsigned char)upper_word[start])) start++;
        size_t end = upper_word.size();
        while (end > start && !isalnum((unsigned char)upper_word[end-1])) end--;
        
        std::string clean_word = upper_word.substr(start, end - start);
        std::string prefix = upper_word.substr(0, start);
        std::string suffix = upper_word.substr(end);
        
        std::transform(clean_word.begin(), clean_word.end(), clean_word.begin(), ::toupper);
        
        if (dict_.count(clean_word)) {
            return prefix + arpabet_to_ipa(dict_.at(clean_word)) + suffix;
        }
        
        // Fallback: return original
        return word; 
    }

private:
    std::unordered_map<std::string, std::vector<std::string>> dict_;
    std::unordered_map<std::string, std::string> arpabet_map_;

    void load_dict(const std::string& path) {
        std::ifstream file(path);
        if (!file.is_open()) {
            std::cerr << "[EnG2P] Warning: Failed to open CMU dict: " << path << std::endl;
            return;
        }
        std::string line;
        while (std::getline(file, line)) {
            if (line.empty()) continue;
            // CMU dict lines start with word, possibly with symbols
            if (!isalpha(line[0]) && line[0] != '\'') continue; // Basic filtering

            std::stringstream ss(line);
            std::string word, ph;
            ss >> word;
            
            // Handle variants like WORD(1)
            size_t paren = word.find('(');
            if (paren != std::string::npos) {
                word = word.substr(0, paren);
            }

            // Normalize to UPPERCASE
            std::transform(word.begin(), word.end(), word.begin(), ::toupper);

            std::vector<std::string> phonemes;
            while (ss >> ph) {
                phonemes.push_back(ph);
            }
            
            // Only keep first variant if multiple exist
            if (!dict_.count(word)) {
                dict_[word] = phonemes;
            }
        }
    }

    void init_arpabet_map() {
        // Mapping ARPABET to IPA
        // Stress: 1 (primary) -> ˈ, 2 (secondary) -> ˌ, 0 (unstressed) -> nothing/schwa
        arpabet_map_ = {
            {"AA0", "ɑ"}, {"AA1", "ˈɑ"}, {"AA2", "ˌɑ"},
            {"AE0", "æ"}, {"AE1", "ˈæ"}, {"AE2", "ˌæ"},
            {"AH0", "ə"}, {"AH1", "ˈʌ"}, {"AH2", "ˌʌ"},
            {"AO0", "ɔ"}, {"AO1", "ˈɔ"}, {"AO2", "ˌɔ"},
            {"AW0", "aʊ"}, {"AW1", "ˈaʊ"}, {"AW2", "ˌaʊ"},
            {"AY0", "aɪ"}, {"AY1", "ˈaɪ"}, {"AY2", "ˌaɪ"},
            {"B", "b"}, {"CH", "tʃ"}, {"D", "d"}, {"DH", "ð"},
            {"EH0", "ɛ"}, {"EH1", "ˈɛ"}, {"EH2", "ˌɛ"},
            {"ER0", "ɚ"}, {"ER1", "ˈɝ"}, {"ER2", "ˌɝ"},
            {"EY0", "eɪ"}, {"EY1", "ˈeɪ"}, {"EY2", "ˌeɪ"},
            {"F", "f"}, {"G", "ɡ"}, {"HH", "h"},
            {"IH0", "ɪ"}, {"IH1", "ˈɪ"}, {"IH2", "ˌɪ"},
            {"IY0", "i"}, {"IY1", "ˈi"}, {"IY2", "ˌi"},
            {"JH", "dʒ"}, {"K", "k"}, {"L", "l"},
            {"M", "m"}, {"N", "n"}, {"NG", "ŋ"},
            {"OW0", "oʊ"}, {"OW1", "ˈoʊ"}, {"OW2", "ˌoʊ"},
            {"OY0", "ɔɪ"}, {"OY1", "ˈɔɪ"}, {"OY2", "ˌɔɪ"},
            {"P", "p"}, {"R", "r"}, {"S", "s"}, {"SH", "ʃ"},
            {"T", "t"}, {"TH", "θ"},
            {"UH0", "ʊ"}, {"UH1", "ˈʊ"}, {"UH2", "ˌʊ"},
            {"UW0", "u"}, {"UW1", "ˈu"}, {"UW2", "ˌu"},
            {"V", "v"}, {"W", "w"}, {"Y", "j"}, {"Z", "z"}, {"ZH", "ʒ"}
        };
    }

    std::string arpabet_to_ipa(const std::vector<std::string>& phonemes) {
        std::string res;
        for (const auto& p : phonemes) {
            if (arpabet_map_.count(p)) {
                res += arpabet_map_.at(p);
            } else {
                // Fallback: try removing digit
                std::string base = p;
                if (!base.empty() && isdigit(base.back())) base.pop_back();
                if (arpabet_map_.count(base)) {
                     res += arpabet_map_.at(base);
                }
            }
        }
        return res;
    }
};
