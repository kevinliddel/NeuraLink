//
//  LocalReplyFormat.swift
//  NeuraLink
//
//  Prompt format and reply hygiene for the local models.
//
//  LLM-jp-3 instruct speaks its own Japanese instruction format
//  ("### 指示:" / "### 応答:"), which llama.cpp's built-in template detector
//  doesn't know: `llama_chat_apply_template` failed and the app quietly fell
//  back to Llama-3's `<|start_header_id|>` markup — text this model was never
//  trained on, so it improvised a script ("ユーザー：… Oz:…") instead of
//  answering. `LLMjpPromptFormat` renders the real format; its stock template
//  also throws the system message away, so our persona goes INTO the
//  instruction block instead.
//
//  Whatever the format, a small model can still drift into writing the next
//  turn itself. `StopSequenceFilter` stops it there, and `LeadingLabelFilter`
//  drops a "Oz:" style speaker label off the front of a reply.
//
//  Created by Dedicatus on 21/10/2026.
//

import Foundation

nonisolated enum LLMjpPromptFormat {
    static let preamble = "以下は、タスクを説明する指示です。要求を適切に満たす応答を書きなさい。"

    /// The model's own format, with system content folded into the next
    /// instruction. The BOS token is left to the tokenizer (`add_bos`). A
    /// prompt without the generation tail is a prefix of the same prompt with
    /// more user text and the tail, so the warm-up's KV cache carries over.
    static func render(_ messages: [LLMChatMessage], addGenerationPrompt: Bool) -> String {
        var out = preamble
        var pendingSystem: [String] = []
        for message in messages {
            switch message.role {
            case "system":
                pendingSystem.append(message.content)
            case "user":
                let body = (pendingSystem + [message.content]).filter { !$0.isEmpty }.joined(separator: "\n\n")
                pendingSystem = []
                out += "\n\n### 指示:\n" + body
            case "assistant":
                out += "\n\n### 応答:\n" + message.content + "</s>"
            default:
                continue
            }
        }
        if !pendingSystem.isEmpty { out += "\n\n### 指示:\n" + pendingSystem.joined(separator: "\n\n") }
        if addGenerationPrompt { out += "\n\n### 応答:\n" }
        return out
    }
}

/// Stops a streamed reply where the model starts writing the next turn, or a
/// prompt block, itself. Text that could still turn into a stop marker is held
/// back until it can't, so nothing of the marker reaches the screen or TTS.
nonisolated struct StopSequenceFilter {
    /// Anywhere in the reply.
    static let stops = [
        "### 指示", "### 応答", "\n###", "\nユーザー：", "\nユーザー:", "\nUser:", "\nuser:",
        "<|start_header_id|>", "<|eot_id|>", "</s>", "<|im_start|>", "<|im_end|>"
    ]
    /// Only at the very start: a reply that opens by quoting the user is a
    /// script, not an answer.
    static let leadingStops = ["ユーザー：", "ユーザー:", "User:", "user:", "###"]

    private(set) var stopped = false
    private var pending = ""
    private var emittedAny = false

    /// Feed one streamed piece; returns what is safe to show now.
    mutating func feed(_ piece: String) -> String {
        guard !stopped else { return "" }
        pending += piece
        if !emittedAny {
            let trimmed = String(pending.drop { $0.isWhitespace })
            if Self.leadingStops.contains(where: { trimmed.hasPrefix($0) }) {
                stopped = true
                pending = ""
                return ""
            }
            // Could still become a leading stop: hold everything for now.
            if !trimmed.isEmpty, Self.leadingStops.contains(where: { $0.hasPrefix(trimmed) }) { return "" }
        }
        if let cut = Self.stops.compactMap({ pending.range(of: $0)?.lowerBound }).min() {
            let out = String(pending[..<cut])
            pending = ""
            stopped = true
            return emit(out)
        }
        let hold = Self.heldSuffixLength(pending, against: Self.stops)
        let out = String(pending.dropLast(hold))
        pending = String(pending.suffix(hold))
        return emit(out)
    }

    /// Whatever is still held when generation ends (unless it stopped).
    mutating func flush() -> String {
        defer { pending = "" }
        return stopped ? "" : emit(pending)
    }

    private mutating func emit(_ text: String) -> String {
        if !text.isEmpty { emittedAny = true }
        return text
    }

    /// The longest suffix of `text` that is a proper prefix of a stop marker.
    static func heldSuffixLength(_ text: String, against stops: [String]) -> Int {
        let chars = Array(text)
        var best = 0
        for stop in stops {
            let s = Array(stop)
            for len in stride(from: min(s.count - 1, chars.count), through: 1, by: -1) where len > best {
                if Array(chars.suffix(len)) == Array(s.prefix(len)) {
                    best = len
                    break
                }
            }
        }
        return best
    }
}

/// Drops a speaker label ("Oz:", "オズ：", "Assistant:") from the front of a
/// reply. Buffers the opening characters until it can tell.
nonisolated struct LeadingLabelFilter {
    let labels: [String]
    private var buffer = ""
    private var decided = false

    init(names: [String]) {
        let generic = ["AI", "Assistant", "assistant", "アシスタント"]
        labels = Array(Set((names + generic).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }))
            .sorted { $0.count > $1.count }
    }

    /// Text to pass on now, or "" while still deciding.
    mutating func feed(_ piece: String) -> String {
        guard !decided else { return piece }
        buffer += piece
        let trimmed = String(buffer.drop { $0.isWhitespace })
        for label in labels {
            for colon in [":", "："] {
                let full = label + colon
                if trimmed.hasPrefix(full) {
                    decided = true
                    let rest = String(trimmed.dropFirst(full.count).drop { $0 == " " })
                    buffer = ""
                    return rest
                }
                if full.hasPrefix(trimmed) && !trimmed.isEmpty { return "" }
            }
        }
        decided = true
        defer { buffer = "" }
        return buffer
    }

    mutating func flush() -> String {
        decided = true
        defer { buffer = "" }
        return buffer
    }

    /// One-shot form for a whole reply.
    static func strip(_ text: String, names: [String]) -> String {
        var filter = LeadingLabelFilter(names: names)
        return filter.feed(text) + filter.flush()
    }
}

/// Something the companion says on its own initiative — breaking a silence,
/// greeting the user back, reacting to a song or a head pat. For the local
/// models it is an instruction, never a user message: sent as the user's
/// words, a 1–2B model read it out or answered it as if the user had said it.
nonisolated struct LocalCue: Sendable, Equatable {
    let english: String
    /// The same instruction in Japanese, for LLM-jp. When absent the English
    /// goes in a short Japanese frame.
    let japanese: String?

    init(english: String, japanese: String? = nil) {
        self.english = english
        self.japanese = japanese
    }

    func instruction(japaneseModel: Bool, characterName: String) -> String {
        guard japaneseModel else { return english }
        if let japanese, !japanese.isEmpty { return japanese }
        return "次の状況に合わせて、\(characterName)として日本語で短く一言だけ話してください。状況：\(english)"
    }
}

/// Decides whether a cue's reply is something to say aloud. A small model
/// sometimes repeats or narrates its instruction ("The user has gone quiet…",
/// "ユーザーが…"); that must never be spoken. Pure, for tests.
nonisolated enum CueReplyValidator {
    static let narrationMarkers = [
        "the user", "in character", "relationship stage", "break the silence", "instruction",
        "ユーザーが", "ユーザーは", "ユーザーに", "指示", "状況："
    ]

    /// The line to say, or nil when it echoes or narrates the instruction or
    /// is empty.
    static func clean(_ reply: String, instruction: String, names: [String]) -> String? {
        let text = LeadingLabelFilter.strip(reply, names: names).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("*") || (text.hasPrefix("（") && text.hasSuffix("）")) { return nil }
        let lowered = text.lowercased()
        if narrationMarkers.contains(where: { lowered.contains($0) }) { return nil }
        let cjk = text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
        if longestCommonSubstring(lowered, instruction.lowercased()) >= (cjk ? 8 : 18) { return nil }
        return text
    }

    static func longestCommonSubstring(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: y.count + 1)
        var best = 0
        for i in 1...x.count {
            var current = [Int](repeating: 0, count: y.count + 1)
            for j in 1...y.count where x[i - 1] == y[j - 1] {
                current[j] = previous[j - 1] + 1
                best = max(best, current[j])
            }
            previous = current
        }
        return best
    }
}
