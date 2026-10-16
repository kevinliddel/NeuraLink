//
//  PhantomTranscriptFilter.swift
//  NeuraLink
//
//  Decides whether a user transcript is something the user actually said.
//  Server VAD opens turns on desk noise and breaths, and the transcription
//  model then hallucinates: it echoes its own vocabulary prompt back as if
//  spoken, emits a lone "ね。" or "you", or trails off with "That's...".
//  Those turns must not reach the chat history, the memory store or the
//  model's context (docs/openai_realtime_chat.md). Pure and unit-tested.
//
//  Created by Dedicatus on 15/10/2026.
//

import Foundation

enum PhantomTranscriptFilter {

    enum Reason: String {
        /// Nothing but whitespace or punctuation.
        case empty
        /// The transcription prompt, or most of it, came back as the "speech".
        case promptEcho
        /// The detected speech segment is shorter than any spoken word.
        case tooShort
        /// Far more words than the segment could hold.
        case tooFastForDuration
        /// One or two words trailing off with an ellipsis.
        case fragment
        /// A known hallucination for silence ("you", "thank you", "ね").
        case filler
    }

    /// Server VAD pads a segment by ~300 ms before the speech, so a real
    /// one-syllable word still measures well above this.
    static let minSpeechMs = 350
    /// Fast natural speech is 4–6 words per second.
    static let maxWordsPerSecond = 8.0
    /// Echoes shorter than this are too generic to be sure about.
    static let minEchoWords = 3
    /// Share of a long transcript's words that must come from the prompt.
    static let echoOverlap = 0.6

    /// What the transcription models say when they hear nothing.
    static let fillers: Set<String> = [
        "you", "thank you", "thanks for watching", "thanks for listening", "bye", "ね", "ん", "あ", "え", "はい"
    ]

    /// Nil when the transcript is genuine; otherwise why it is not.
    static func reason(transcript: String, speechMs: Int? = nil, prompt: String? = nil) -> Reason? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.rangeOfCharacter(from: .alphanumerics) != nil else { return .empty }

        let normal = normalized(trimmed)
        if let prompt, isEcho(normal, ofPrompt: normalized(prompt)) { return .promptEcho }

        let words = normal.split(separator: " ")
        if let speechMs {
            if speechMs < minSpeechMs { return .tooShort }
            let seconds = Double(speechMs) / 1_000
            if Double(speechUnits(normal)) / seconds > maxWordsPerSecond { return .tooFastForDuration }
        }

        if words.count <= 2, trimmed.hasSuffix("…") || trimmed.hasSuffix("...") { return .fragment }
        if fillers.contains(normal) { return .filler }
        return nil
    }

    /// Lowercased, letters / digits / spaces only, single-spaced.
    static func normalized(_ text: String) -> String {
        let kept = text.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    /// Spoken units for the rate check: whitespace words, or, for scripts
    /// written without spaces, about one unit per four characters.
    static func speechUnits(_ normal: String) -> Int {
        let words = normal.split(separator: " ")
        if words.count == 1, let only = words.first, only.count > 6 {
            return max(1, (only.count + 3) / 4)
        }
        return max(1, words.count)
    }

    private static func isEcho(_ normal: String, ofPrompt prompt: String) -> Bool {
        guard !normal.isEmpty, !prompt.isEmpty else { return false }
        let words = normal.split(separator: " ")
        if words.count >= minEchoWords, prompt.contains(normal) || normal.contains(prompt) { return true }
        guard words.count >= 6 else { return false }
        let vocabulary = Set(prompt.split(separator: " "))
        let shared = words.filter { vocabulary.contains($0) }.count
        return Double(shared) / Double(words.count) >= echoOverlap
    }
}
