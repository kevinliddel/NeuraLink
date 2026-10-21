//
//  SpeechChunker.swift
//  NeuraLink
//
//  Splits a finished text into the pieces a local voice engine should speak
//  one after another. VOICEVOX renders a whole call before it returns any
//  audio, so speaking a paragraph in one call means silence until the last
//  word is ready. Speaking it in chunks starts playback after the first one
//  and renders the rest while that plays.
//
//  Same shape as the live chat's streamed chunking (LocalLLMManager+Engine):
//  the first chunk ends at the first clause so audio starts early, later
//  chunks are whole sentences (better prosody, fewer calls), and a runaway
//  sentence is cut at a clause or, failing that, at a hard length.
//
//  Created by Dedicatus on 20/10/2026.
//

import Foundation

nonisolated enum SpeechChunker {
    /// End a sentence wherever they appear.
    private static let cjkEnders: Set<Character> = ["。", "！", "？", "\n"]
    /// End a sentence only before a space or the end, so "3.14" stays whole.
    private static let latinEnders: Set<Character> = [".", "!", "?"]
    private static let cjkClauses: Set<Character> = ["、", "，", "…"]
    private static let latinClauses: Set<Character> = [",", ";", ":"]
    /// Stay with the sentence they close: 「…。」 is one chunk.
    private static let closers: Set<Character> = ["」", "』", "）", ")", "\"", "”", "’", "】"]

    /// The first chunk may end at a clause once it has this many characters.
    static let firstClauseMinLength = 4
    /// English with no punctuation: the first chunk ends at a space past this.
    static let firstChunkSoftLength = 24
    /// Later chunks end at a clause only once they are this long.
    static let clauseBreakLength = 40
    /// Runaway cap: past this, break at the next space (anywhere in CJK).
    static let hardLength = 120

    static func chunks(_ text: String) -> [String] {
        let chars = Array(text)
        var out: [String] = []
        var buffer = ""
        for index in chars.indices {
            let char = chars[index]
            buffer.append(char)
            let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
            if shouldBreak(buffer: buffer, last: char, next: next, isFirst: out.isEmpty) {
                emit(buffer, into: &out)
                buffer = ""
            }
        }
        emit(buffer, into: &out)
        return out
    }

    // MARK: - Rules

    private static func shouldBreak(buffer: String, last: Character, next: Character?, isFirst: Bool) -> Bool {
        // Punctuation runs ("?!", "……", "。」") stay together; break after the run.
        if let next, isPunctuation(next) { return false }
        let beforeSpaceOrEnd = next.map(\.isWhitespace) ?? true
        let length = buffer.count

        let core = buffer.last { !closers.contains($0) } ?? last
        if cjkEnders.contains(core) { return true }
        if latinEnders.contains(core) && beforeSpaceOrEnd { return true }

        let isClause = cjkClauses.contains(core) || (latinClauses.contains(core) && beforeSpaceOrEnd)
        if isClause {
            if isFirst && length >= firstClauseMinLength { return true }
            if length >= clauseBreakLength { return true }
        }
        if isFirst && last.isWhitespace && length >= firstChunkSoftLength { return true }
        if length >= hardLength && (last.isWhitespace || isCJK(last)) { return true }
        return false
    }

    private static func isPunctuation(_ char: Character) -> Bool {
        cjkEnders.contains(char) || latinEnders.contains(char) || cjkClauses.contains(char)
            || latinClauses.contains(char) || closers.contains(char)
    }

    private static func isCJK(_ char: Character) -> Bool {
        char.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
        }
    }

    /// Adds a chunk; a piece with nothing to say (stray punctuation) joins
    /// the chunk before it instead of becoming a silent engine call.
    private static func emit(_ raw: String, into out: inout [String]) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if text.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
            out.append(text)
        } else if let last = out.indices.last {
            out[last] += text
        }
    }
}
