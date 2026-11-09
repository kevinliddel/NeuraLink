//
//  SelfTalkProbe.swift
//  NeuraLink
//
//  A developer probe for how the persona talks about itself — Inner life
//  (docs/Companion/LIVING_COMPANION.md): asks the OpenAI text model the
//  five SelfTalkRules.probes with the character's real instructions
//  (persona, Companion State, About yourself) and logs every reply with
//  what the checker found. `-nl.debug.selfTalkProbe YES` in DEBUG builds;
//  needs a valid OpenAI key.
//
//  Created by Dedicatus on 09/11/2026.
//

import Foundation

enum SelfTalkProbe {

    /// Asks the five probes for `character` and logs each reply; returns
    /// how many replies read like the sheet (the checker found something).
    @discardableResult
    static func run(character: String) async -> Int {
        let openAI = OpenAISettings.shared
        guard openAI.isEnabled, openAI.hasValidKey else {
            nlLog("[SelfTalkProbe] needs an OpenAI key", level: .info)
            return 0
        }
        let persona = CharacterPersona.forCharacter(named: character)
        let system = CharacterPersona.strippingEmotionInstructions(persona.instructions) + "\n"
            + CompanionStateManager.shared.promptContext(characterName: character)
            + SelfTalkRules.promptBlock(
                everyday: CharacterLoreCatalogue.everyday(for: character),
                example: CharacterLoreCatalogue.selfTalkExample(for: character))
        var failures = 0
        for probe in SelfTalkRules.probes {
            let reply = await OpenAIChatClient.complete(
                system: system, user: probe, maxTokens: 120, temperature: 0.8, purpose: "selfTalkProbe") ?? ""
            let found = SelfTalkRules.violations(in: reply)
            if !found.isEmpty { failures += 1 }
            let verdict = found.isEmpty ? "ok" : found.joined(separator: "; ")
            nlLog("[SelfTalkProbe] \(character) | \(probe) → \(reply) | \(verdict)", level: .info)
        }
        nlLog("[SelfTalkProbe] \(character): \(failures) of \(SelfTalkRules.probes.count) replies read like the sheet",
              level: .info)
        return failures
    }
}
