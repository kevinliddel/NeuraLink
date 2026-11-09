//
//  SelfTalkTests.swift
//  NeuraLinkTests
//
//  How the companion talks about itself (docs/Companion/LIVING_COMPANION.md):
//  the OpenAI block carries the rule, the everyday facts and the example;
//  the bundled characters' facts are in their own voice and never pre-empt
//  a story; the checker tells a sheet read back from a person's answer.
//
//  Created by Dedicatus on 09/11/2026.
//

import Foundation
import Testing

@testable import NeuraLink

@Suite("Self talk")
struct SelfTalkTests {

    @Test("The block carries the rule, the facts and the example; a character without lore gets the rule alone")
    func block() {
        let sonya = SelfTalkRules.promptBlock(
            everyday: CharacterLoreCatalogue.everyday(for: "sonya"),
            example: CharacterLoreCatalogue.selfTalkExample(for: "sonya"))
        #expect(sonya.hasPrefix("\n[About yourself]\n"))
        #expect(sonya.contains("never list traits"))
        #expect(sonya.contains("answer from what the Companion State gives you"))
        #expect(sonya.contains("Things about you anyone may know"))
        #expect(sonya.contains("The shape of it"))
        #expect(sonya.hasSuffix("[End About yourself]\n"))

        let imported = SelfTalkRules.promptBlock(
            everyday: CharacterLoreCatalogue.everyday(for: "someone-imported"),
            example: CharacterLoreCatalogue.selfTalkExample(for: "someone-imported"))
        #expect(imported.contains("never list traits"))
        #expect(!imported.contains("anyone may know") && !imported.contains("The shape of it"))
    }

    @Test("Every bundled character has everyday facts in its own voice and an example that pass the checker")
    func catalogue() throws {
        for character in CharacterLoreCatalogue.characters {
            let everyday = CharacterLoreCatalogue.everyday(for: character)
            #expect(everyday.count >= 3, "\(character)")
            let stories = Set(CharacterLoreCatalogue.fragments(for: character).map(\.text))
            for fact in everyday {
                #expect(!fact.lowercased().hasPrefix("you "), "\(character) speaks of itself in the second person: \(fact)")
                #expect(SelfTalkRules.violations(in: fact).isEmpty, "\(character): \(fact)")
                #expect(!stories.contains(fact), "\(character) gives a story away: \(fact)")
            }
            let example = try #require(CharacterLoreCatalogue.selfTalkExample(for: character), "\(character)")
            #expect(SelfTalkRules.probes.contains(example.question), "\(character) answers a question nobody asks")
            #expect(SelfTalkRules.violations(in: example.answer).isEmpty, "\(character): \(example.answer)")
        }
    }

    @Test("The checker flags a sheet read back and passes a person's answer")
    func checker() {
        let sheet = "I'm Sonya, a blunt tsundere. I'm sharp and condescending but secretly kind and caring."
        let found = SelfTalkRules.violations(in: sheet)
        #expect(found.contains("label \"tsundere\""))
        #expect(found.contains { $0.hasPrefix("lists traits") })
        #expect(SelfTalkRules.violations(in: "As an AI companion, I was programmed to help you.").count == 3)
        #expect(SelfTalkRules.violations(
            in: "Hmph. I finished the crossword before my coffee went cold. What have you managed today?").isEmpty)
        // Whole words: an airport is not an AI, and two trait words are a sentence, not a list.
        #expect(SelfTalkRules.violations(in: "I waited an hour at an airport once and read a whole novel.").isEmpty)
        #expect(SelfTalkRules.violations(in: "I try to be kind, and patient when I can manage it.").isEmpty)
        #expect(SelfTalkRules.probes.count == 5 && Set(SelfTalkRules.probes).count == 5)
    }
}
