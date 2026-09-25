//
//  MemoryEntityExtractor.swift
//  NeuraLink
//
//  No-LLM entity extraction for memory units (docs/AGENTIC_MEMORY.md
//  §Retain). Uses NLTagger name recognition (people, places,
//  organisations) with a capitalised-word fallback so entity linking works
//  on the simulator and for languages without a name-tagging model. The
//  "user" entity is always included for user-authored text, mirroring
//  Hindsight's "Always include 'user' when fact is about the user".
//
//  Created by Dedicatus on 25/09/2026.
//

import Foundation
import NaturalLanguage

enum MemoryEntityExtractor {

    static let userEntity = "user"

    /// Words that often start a sentence capitalised but are never entities.
    private static let capitalisedNoise: Set<String> = [
        "i", "i'm", "i've", "i'll", "i'd", "the", "a", "an", "my", "your", "we", "you", "it",
        "this", "that", "yes", "no", "ok", "okay", "hi", "hello", "hey", "thanks", "thank",
        "user", "assistant", "monday", "tuesday", "wednesday", "thursday", "friday",
        "saturday", "sunday", "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december", "today", "yesterday",
        "tomorrow", "what", "when", "where", "why", "how", "who", "do", "does", "did", "can",
        "could", "would", "should", "is", "are", "was", "were", "have", "has", "had", "so",
        "but", "and", "or", "if", "then", "well", "oh", "also", "please", "sure", "sorry"
    ]

    /// Canonical entity names found in `text`. `includeUser` adds the
    /// "user" entity (true for user turns and user-about facts).
    static func entities(in text: String, includeUser: Bool) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        func add(_ raw: String) {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard name.count >= 2, name.count <= 40 else { return }
            let key = name.lowercased()
            guard !seen.contains(key), !capitalisedNoise.contains(key) else { return }
            seen.insert(key)
            found.append(name)
        }

        if includeUser {
            found.append(userEntity)
            seen.insert(userEntity)
        }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: options) { tag, range in
            if let tag, tag == .personalName || tag == .placeName || tag == .organizationName {
                add(String(text[range]))
            }
            return true
        }

        // Fallback: capitalised words that are not sentence-initial.
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
        for sentence in sentences {
            let words = sentence.split(separator: " ").map(String.init)
            for (index, word) in words.enumerated() where index > 0 {
                let cleaned = word.trimmingCharacters(in: .punctuationCharacters)
                guard let first = cleaned.first, first.isUppercase, cleaned.count >= 2,
                      cleaned.dropFirst().allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" })
                else { continue }
                add(cleaned)
            }
        }
        return Array(found.prefix(8))
    }

    /// True when the text is about the user (third-person "User …" facts
    /// or first-person statements).
    static func isAboutUser(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        return lower.hasPrefix("user") || lower.hasPrefix("the user") || lower.hasPrefix("i ")
            || lower.hasPrefix("i'") || lower.hasPrefix("my ") || lower.contains(" user's ")
    }
}
