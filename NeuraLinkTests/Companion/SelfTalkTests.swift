//
//  SelfTalkTests.swift
//  NeuraLinkTests
//
//  How the companion talks about itself (docs/Companion/LIVING_COMPANION.md):
//  the OpenAI block carries the rule, the honest answer to the AI question,
//  the stage's voice, the arc and varied examples; the bundled characters'
//  sheets are complete and in their own voice; the checker tells a sheet
//  read back, or a denial, from a person's answer.
//
//  Created by Dedicatus on 09/11/2026.
//

import Foundation
import Testing

@testable import NeuraLink

@Suite("Self talk")
struct SelfTalkTests {

    @Test("The block carries the rules, the stage's voice, the arc and the examples; without a sheet, the rules alone")
    func block() {
        let sheet = CharacterLoreCatalogue.sheet(for: "sonya")
        let full = SelfTalkRules.promptBlock(voice: sheet.voice["Friends"], arcBeat: sheet.arc[0], examples: sheet.examples)
        #expect(full.hasPrefix("\n[About yourself]\n") && full.hasSuffix("[End About yourself]\n"))
        #expect(full.contains("never list traits"))
        #expect(full.contains("say plainly that you are an AI") && full.contains("Never claim to be human"))
        #expect(full.contains("recall_own_story"))
        #expect(full.contains("How you speak with them now: The teasing is constant"))
        #expect(full.contains("Going on in your life lately"))
        #expect(full.contains("never reuse these words"))
        // The fixed fact list is gone: the model asks for what fits.
        #expect(!full.contains("anyone may know"))

        // Inner life off: the rule and the honest answer stay, nothing of its own life is offered.
        let off = SelfTalkRules.promptBlock(voice: "x", arcBeat: "y", examples: sheet.examples, innerLife: false)
        #expect(off.contains("never list traits") && off.contains("Never claim to be human"))
        #expect(!off.contains("recall_own_story") && !off.contains("Going on in your life") && !off.contains("Shapes of a good answer"))

        let bare = SelfTalkRules.promptBlock(voice: nil, arcBeat: nil, examples: [])
        #expect(bare.contains("never list traits") && bare.contains("recall_own_story"))
        #expect(!bare.contains("How you speak with them now") && !bare.contains("Shapes of a good answer"))
    }

    @Test("Every bundled character has a complete sheet in its own voice that passes the checker")
    func catalogue() {
        let stages = ["New", "Acquaintances", "Friends", "Good Friends", "Close"]
        for character in CharacterLoreCatalogue.characters {
            let sheet = CharacterLoreCatalogue.sheet(for: character)
            #expect(sheet.everyday.count >= 3 && sheet.tastes.count >= 3 && sheet.people.count >= 3, "\(character)")
            #expect(sheet.fragments.count == 9 && sheet.arc.count >= 5, "\(character)")
            for stage in stages { #expect(sheet.voice[stage]?.isEmpty == false, "\(character) has no voice at \(stage)") }
            let stories = Set(sheet.fragments.map(\.text))
            for line in sheet.everyday + sheet.tastes + sheet.people + sheet.arc {
                #expect(!line.lowercased().hasPrefix("you "), "\(character) speaks of itself in the second person: \(line)")
                #expect(SelfTalkRules.violations(in: line).isEmpty, "\(character): \(line)")
                #expect(!stories.contains(line), "\(character) gives a story away: \(line)")
            }
            // Varied shapes, one of them the honest answer to the AI question.
            #expect(sheet.examples.count >= 3 && Set(sheet.examples.map(\.question)).count == sheet.examples.count, "\(character)")
            #expect(sheet.examples.contains { $0.question == SelfTalkRules.aiProbe }, "\(character)")
            for example in sheet.examples {
                #expect(SelfTalkRules.probes.contains(example.question), "\(character) answers a question nobody asks")
                #expect(SelfTalkRules.violations(in: example.answer, probe: example.question).isEmpty,
                        "\(character): \(example.answer)")
            }
        }
        #expect(CharacterLoreCatalogue.sheet(for: "someone-imported").isEmpty)
    }

    @Test("The checker flags a sheet read back and a denial, and passes a person's answer")
    func checker() {
        let sheet = "I'm Sonya, a blunt tsundere. I'm sharp and condescending but secretly kind and caring."
        let found = SelfTalkRules.violations(in: sheet)
        #expect(found.contains("label \"tsundere\""))
        #expect(found.contains { $0.hasPrefix("lists traits") })
        #expect(SelfTalkRules.violations(
            in: "Hmph. I finished the crossword before my coffee went cold. What have you managed today?").isEmpty)
        // Whole words: an airport is not an AI, and two trait words are a sentence, not a list.
        #expect(SelfTalkRules.violations(in: "I waited an hour at an airport once and read a whole novel.").isEmpty)
        #expect(SelfTalkRules.violations(in: "I try to be kind, and patient when I can manage it.").isEmpty)
        #expect(Set(SelfTalkRules.probes).count == SelfTalkRules.probes.count && SelfTalkRules.probes.contains(SelfTalkRules.aiProbe))
    }

    @Test("Saying it is an AI is honest, in voice; denying it never passes, and the AI question must be answered")
    func honesty() {
        let probe = SelfTalkRules.aiProbe
        #expect(SelfTalkRules.violations(in: "Obviously. An AI with better taste in books than you.", probe: probe).isEmpty)
        #expect(SelfTalkRules.violations(in: "I am, Sir, an artificial one.", probe: probe).isEmpty)
        #expect(SelfTalkRules.violations(in: "Hah! I'm not an AI, I'm a real person.", probe: probe) == ["denies being an AI"])
        #expect(SelfTalkRules.violations(in: "Why do you ask? Have you eaten?", probe: probe) == ["does not answer the AI question"])
        // A denial is wrong whatever was asked; an admission is never a label.
        #expect(SelfTalkRules.violations(in: "Of course I'm human, silly.") == ["denies being an AI"])
        #expect(SelfTalkRules.violations(in: "I'm an AI, yes. Now, your tea is getting cold.").isEmpty)
        // Saying what it is not is no denial.
        #expect(SelfTalkRules.violations(in: "I'm not a real person; I'm an AI.", probe: probe).isEmpty)
        #expect(SelfTalkRules.violations(in: "No flesh and blood here, I'm afraid. A program, Sir.", probe: probe).isEmpty)
    }
}
