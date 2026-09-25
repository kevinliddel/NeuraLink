//
//  MemoryTextIndex.swift
//  NeuraLink
//
//  Tokeniser + BM25 scorer for the keyword arm of recall
//  (docs/AGENTIC_MEMORY.md §Recall). Hindsight uses Postgres full-text
//  search; on-device we store a normalised token string per unit at insert
//  time and score BM25 in Swift over the (small) corpus, which avoids
//  depending on an FTS5 build of SQLCipher.
//
//  Created by Dedicatus on 25/09/2026.
//

import Foundation
import NaturalLanguage

enum MemoryTextIndex {

    // MARK: - Tokenisation

    /// Small multilingual stop list; anything shorter than 2 characters is
    /// also dropped. Kept short on purpose — BM25's IDF already dampens
    /// very common words.
    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "at", "for", "with",
        "is", "are", "was", "were", "be", "been", "it", "its", "this", "that", "these",
        "those", "i", "me", "my", "you", "your", "we", "our", "they", "them", "he", "she",
        "his", "her", "do", "does", "did", "have", "has", "had", "so", "as", "by", "from",
        "not", "no", "yes", "if", "then", "than", "too", "very", "just", "about", "into",
        "what", "which", "who", "whom", "when", "where", "why", "how", "can", "could",
        "would", "should", "will", "shall", "may", "might", "also", "there", "here",
        "user", "assistant"
    ]

    /// Lower-cased, diacritic-folded word tokens with stop words removed.
    /// Uses NLTokenizer so CJK text is segmented sensibly.
    static func tokens(for text: String) -> [String] {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = folded
        var out: [String] = []
        tokenizer.enumerateTokens(in: folded.startIndex..<folded.endIndex) { range, _ in
            var token = String(folded[range]).lowercased()
            // Possessives ("cat's", "user’s") index as the bare noun.
            for suffix in ["'s", "\u{2019}s"] where token.hasSuffix(suffix) { token.removeLast(2) }
            if token.count >= 2, !stopWords.contains(token), token.rangeOfCharacter(from: .alphanumerics) != nil {
                out.append(stem(token))
            }
            return true
        }
        return out
    }

    /// Persisted form: tokens joined by single spaces.
    static func tokenString(for text: String) -> String {
        tokens(for: text).joined(separator: " ")
    }

    /// Minimal English suffix stripper so inflections collide on one key:
    /// "likes"/"liked"/"liking"/"like" → "lik", "named"/"names"/"name" →
    /// "nam", "cats" → "cat". Stems are keys, not words — the same rules
    /// run on queries and documents, so only consistency matters.
    static func stem(_ token: String) -> String {
        guard token.allSatisfy(\.isLetter) else { return token }
        var stem = token
        if stem.count > 4, stem.hasSuffix("ies") {
            stem = String(stem.dropLast(3)) + "y"
        } else if stem.count > 5, stem.hasSuffix("ing") {
            stem = String(stem.dropLast(3))
        } else if stem.count > 4, stem.hasSuffix("ed") {
            stem = String(stem.dropLast(2))
        } else if stem.count > 4, ["ses", "xes", "zes", "ches", "shes"].contains(where: stem.hasSuffix) {
            stem = String(stem.dropLast(2))
        } else if stem.count > 3, stem.hasSuffix("s"), !stem.hasSuffix("ss") {
            stem = String(stem.dropLast())
        }
        // Final silent-e drop (Porter step 5a, simplified): "name" → "nam"
        // so it meets "named" → "nam"; "like" → "lik" meets "likes" → "lik".
        if stem.count > 3, stem.hasSuffix("e") { stem.removeLast() }
        return stem
    }

    // MARK: - BM25

    struct Document {
        let id: Int64
        /// Persisted token string (see `tokenString(for:)`).
        let tokens: String
    }

    /// Okapi BM25 (k1 = 1.2, b = 0.75). Returns `(id, score)` for every
    /// document with a positive score, best first.
    static func bm25(query: String, documents: [Document], k1: Double = 1.2, b: Double = 0.75) -> [(Int64, Double)] {
        let queryTerms = Set(tokens(for: query))
        guard !queryTerms.isEmpty, !documents.isEmpty else { return [] }

        let docTerms: [[String]] = documents.map { $0.tokens.split(separator: " ").map(String.init) }
        let n = Double(documents.count)
        let avgLen = max(1.0, docTerms.reduce(0.0) { $0 + Double($1.count) } / n)

        // Document frequency per query term.
        var df: [String: Double] = [:]
        for terms in docTerms {
            for term in Set(terms) where queryTerms.contains(term) {
                df[term, default: 0] += 1
            }
        }
        guard !df.isEmpty else { return [] }

        var scored: [(Int64, Double)] = []
        for (index, terms) in docTerms.enumerated() {
            let length = Double(terms.count)
            var tf: [String: Double] = [:]
            for term in terms where queryTerms.contains(term) { tf[term, default: 0] += 1 }
            guard !tf.isEmpty else { continue }
            var score = 0.0
            for (term, frequency) in tf {
                let dfT = df[term] ?? 0
                let idf = log(1 + (n - dfT + 0.5) / (dfT + 0.5))
                let norm = frequency * (k1 + 1) / (frequency + k1 * (1 - b + b * length / avgLen))
                score += idf * norm
            }
            if score > 0 { scored.append((documents[index].id, score)) }
        }
        return scored.sorted { $0.1 > $1.1 }
    }
}
