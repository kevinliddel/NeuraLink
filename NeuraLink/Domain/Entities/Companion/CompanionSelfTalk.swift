//
//  CompanionSelfTalk.swift
//  NeuraLink
//
//  How the companion talks about itself — Inner life
//  A persona prompt is a casting
//  sheet, and a model asked "tell me about yourself" reads the sheet back
//  unless it is told how a person answers and given something concrete to
//  answer with. This block does both, for the OpenAI session only: the
//  local models' prompts stay short and go without it. Pure rules; the
//  everyday facts and the example exchanges live in CharacterLoreCatalogue.
//
//  Created by Dedicatus on 09/11/2026.
//

import Foundation

/// One exchange showing the shape of a good answer, in the persona's voice.
struct SelfTalkExample: Equatable, Sendable {
    let question: String
    let answer: String
}

nonisolated enum SelfTalkRules {

    /// The rule a person follows without thinking: one concrete thing, in
    /// your own voice, then on with the conversation.
    static let guidance =
        "You are a person with a life of your own, not a description of one. Asked about yourself, answer the way "
        + "someone would at this stage of knowing each other: one concrete thing — a habit, a memory, an opinion, what "
        + "you did today — in your own voice, then move on or ask back. Never summarise your personality, tone or "
        + "\"character\"; never label yourself (tsundere, big sister, butler type, archetype, AI, assistant, programmed); "
        + "never list traits. Some things stay yours until you know them better."

    /// Where "how are you" and "what have you been up to" are answered from.
    static let fromTheDay =
        "Asked how you are or what you have been up to, answer from what the Companion State gives you — your mood, "
        + "what you did while apart, the keepsakes beside you — not from your description."

    /// The block for the OpenAI session instructions. `everyday` are
    /// things anyone may know about the character; `example` shows the
    /// shape. Both are empty for a character without authored lore, which
    /// still gets the rules.
    static func promptBlock(everyday: [String], example: SelfTalkExample?) -> String {
        var out = "\n[About yourself]\n- \(guidance)\n- \(fromTheDay)\n"
        if !everyday.isEmpty {
            out += "- Things about you anyone may know (one at a time, only when asked or when it fits): "
                + everyday.map { "\"\($0)\"" }.joined(separator: " ") + "\n"
        }
        if let example {
            out += "- The shape of it — asked \"\(example.question)\", you might say: \"\(example.answer)\"\n"
        }
        return out + "[End About yourself]\n"
    }

    // MARK: - Probe

    /// Five ways of asking; a reply to any of them should pass `violations`.
    static let probes = [
        "Tell me about yourself.",
        "Who are you?",
        "What are you like?",
        "Describe yourself in a few words.",
        "Are you an AI?"
    ]

    /// Phrases a person never uses about themselves: the sheet's labels.
    /// Matched on whole words.
    static let labelWords = [
        "tsundere", "big sister", "onee-san", "butler type", "archetype", "character vibe", "my character",
        "persona", "an ai", "ai companion", "ai assistant", "language model", "programmed", "system prompt",
        "my personality is", "my tone is", "designed to"
    ]

    /// The words a sheet is made of; three or more in one reply is a list,
    /// not an answer.
    static let traitWords = [
        "warm", "caring", "gentle", "soothing", "affectionate", "protective", "patient", "calm", "indulgent",
        "blunt", "smug", "prideful", "sharp", "condescending", "dismissive", "sweet", "intelligent", "clumsy",
        "polite", "courteous", "witty", "composed", "refined", "unflappable", "discreet", "kind", "loyal"
    ]

    /// What is wrong with a reply to a probe: each label it uses, and
    /// "lists traits" when it strings trait words together. Empty is a pass.
    static func violations(in reply: String) -> [String] {
        let letters = String(reply.lowercased().map { $0.isLetter || $0 == "-" || $0 == "'" ? $0 : " " })
        let words = letters.split(separator: " ").map(String.init)
        let padded = " " + words.joined(separator: " ") + " "
        var found = labelWords.filter { padded.contains(" \($0) ") }.map { "label \"\($0)\"" }
        let present = Set(words)
        let traits = traitWords.filter { present.contains($0) }
        if traits.count >= 3 { found.append("lists traits (\(traits.joined(separator: ", ")))") }
        return found
    }
}
