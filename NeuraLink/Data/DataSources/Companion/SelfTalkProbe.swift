//
//  SelfTalkProbe.swift
//  NeuraLink
//
//  A developer probe for how the persona talks about itself — Inner life
//  (docs/Companion/LIVING_COMPANION.md): asks the OpenAI text model the
//  SelfTalkRules.probes with the character's instructions (persona, its
//  mood, About yourself, and what a story recall would return), read-only and logs every reply with
//  what the checker found. `-nl.debug.selfTalkProbe YES` in DEBUG builds;
//  needs a valid OpenAI key.
//
//  Created by Dedicatus on 09/11/2026.
//

import Foundation

enum SelfTalkProbe {

    /// Asks the probes for `character` and logs each reply; returns
    /// how many replies read like the sheet (the checker found something).
    @discardableResult
    static func run(character: String) async -> Int {
        let openAI = OpenAISettings.shared
        guard openAI.isEnabled, openAI.hasValidKey else {
            nlLog("[SelfTalkProbe] needs an OpenAI key", level: .info)
            return 0
        }
        let persona = CharacterPersona.forCharacter(named: character)
        // Read-only context: building the real Companion State would stamp
        // an away line told, a story shared or a keepsake celebrated without
        // the user ever hearing it. The mood line is the part the answers
        // lean on, and reading it changes nothing.
        let mood = CompanionInnerLife.shared.bodyMood(character: character).map { "\n[Companion State]\n- \($0.promptLine)\n[End Companion State]\n" } ?? ""
        let system = CharacterPersona.strippingEmotionInstructions(persona.instructions) + "\n" + mood
            + CharacterStoryProvider.shared.promptBlock(character: character)
        var failures = 0
        for probe in SelfTalkRules.probes {
            // The text client has no tools: hand over what the recall would
            // return for this question, without stamping anything shared.
            // Inner life off: nothing of its own is shared, so none is sent.
            let recalled = PresenceSettings.innerLifeOn
                ? CharacterStoryProvider.shared.recall(topic: probe, character: character, stamp: false) : ""
            let reply = await OpenAIChatClient.complete(
                system: system + "\n" + recalled + "\n", user: probe, maxTokens: 120, temperature: 0.8,
                purpose: "selfTalkProbe") ?? ""
            let found = SelfTalkRules.violations(in: reply, probe: probe)
            if !found.isEmpty { failures += 1 }
            let verdict = found.isEmpty ? "ok" : found.joined(separator: "; ")
            // The reply can repeat story text: kept out of the persistent log.
            nlLogSensitive("[SelfTalkProbe] \(character) | \(probe) → \(reply) | \(verdict)", level: .info)
        }
        nlLog("[SelfTalkProbe] \(character): \(failures) of \(SelfTalkRules.probes.count) replies read like the sheet",
              level: .info)
        return failures
    }
}
