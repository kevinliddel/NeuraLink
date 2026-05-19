//
//  LocalLLMFactExtractorTests.swift
//  NeuraLinkTests
//
//  Unit tests for the fact extractor. Uses a stubbed LLM generator so the
//  tests are deterministic and don't require a model to be downloaded.
//
//  Phase 2A of docs/local_llm_memory_plan.md.
//
//  Created by Dedicatus on 18/05/2026.
//

import XCTest

@testable import NeuraLink

final class LocalLLMFactExtractorTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTurn(role: String, detail: String) -> ChatEventItem {
        ChatEventItem(
            id: 0, role: role, kind: "chat", title: "", detail: detail,
            pinned: false, timestamp: Date()
        )
    }

    // MARK: - Prompt building

    func testBuildPromptIncludesSpeakerLabelsAndContent() {
        let extractor = LocalLLMFactExtractor.shared
        let turns = [
            makeTurn(role: "user", detail: "My name is Dedicatus."),
            makeTurn(role: "ai", detail: "Nice to meet you, Dedicatus.")
        ]
        let prompt = extractor.buildPrompt(from: turns)
        XCTAssertTrue(prompt.contains("User: My name is Dedicatus."))
        XCTAssertTrue(prompt.contains("Assistant: Nice to meet you, Dedicatus."))
        XCTAssertTrue(prompt.contains("NONE"),
            "Prompt must mention the NONE sentinel so the LLM knows how to signal absence")
    }

    // MARK: - Output parsing

    func testParseFactsHandlesPlainLines() {
        let raw = "User is named Dedicatus.\nUser lives in Tokyo."
        let facts = LocalLLMFactExtractor.shared.parseFacts(raw)
        XCTAssertEqual(facts.count, 2)
        XCTAssertEqual(facts[0], "User is named Dedicatus.")
        XCTAssertEqual(facts[1], "User lives in Tokyo.")
    }

    func testParseFactsStripsBulletAndNumberMarkers() {
        let raw = """
        - User is named Dedicatus.
        * User has a cat called Mochi.
        1. User prefers tea over coffee.
        2) User works as a developer.
        """
        let facts = LocalLLMFactExtractor.shared.parseFacts(raw)
        XCTAssertEqual(facts, [
            "User is named Dedicatus.",
            "User has a cat called Mochi.",
            "User prefers tea over coffee.",
            "User works as a developer."
        ])
    }

    func testParseFactsReturnsEmptyForNoneSentinel() {
        XCTAssertEqual(LocalLLMFactExtractor.shared.parseFacts("NONE"), [])
        XCTAssertEqual(LocalLLMFactExtractor.shared.parseFacts(" none "), [])
        XCTAssertEqual(LocalLLMFactExtractor.shared.parseFacts("NONE."), [])
    }

    func testParseFactsReturnsEmptyForEmptyInput() {
        XCTAssertEqual(LocalLLMFactExtractor.shared.parseFacts(""), [])
        XCTAssertEqual(LocalLLMFactExtractor.shared.parseFacts("   \n  "), [])
    }

    func testParseFactsSkipsVeryShortLines() {
        // Lines below the minFactLength threshold are noise (model echoing
        // punctuation or fragments).
        let raw = "ok\nUser likes cats.\n.\nUser drinks tea."
        let facts = LocalLLMFactExtractor.shared.parseFacts(raw)
        XCTAssertEqual(facts, ["User likes cats.", "User drinks tea."])
    }

    // MARK: - Quality gates (1B-model hallucination resistance)

    func testParseFactsRejectsBoilerplatePrefixes() {
        // 1B models frequently echo the prompt structure rather than producing
        // facts. None of these should reach the store.
        let raw = """
        Facts:
        Facts the user mentioned in this exchange
        Explanation: this exchange contains nothing
        Summary: nothing was said
        The assistant states that the user is named Dedicatus.
        Assistant: I think the user likes cats.
        User: My name is Dedicatus.
        User drinks coffee in the morning.
        """
        let facts = LocalLLMFactExtractor.shared.parseFacts(raw)
        XCTAssertEqual(facts, ["User drinks coffee in the morning."],
            "Only the genuine 'User …' line should survive; every echo / boilerplate prefix must be filtered out")
    }

    func testParseFactsRejectsFirstPersonHallucinations() {
        // The model gets confused and starts producing first-person lines
        // about itself instead of third-person facts about the user.
        let raw = """
        I am a user who has stated that I live in Tokyo.
        I'm under the care of my mother.
        My name is Dedicatus and I like cats.
        We had a great conversation.
        User lives in Osaka.
        """
        let facts = LocalLLMFactExtractor.shared.parseFacts(raw)
        XCTAssertEqual(facts, ["User lives in Osaka."],
            "All first-person 'I'/'My'/'We' lines must be rejected; only third-person 'User …' survives")
    }

    func testParseFactsRejectsOverLongLines() {
        // The previous output included a 310-char hallucinated paragraph
        // ("The assistant states that the user's mother is very kind…").
        // A line that long is essay-style, not an atomic fact.
        let longHallucination = "User " + String(repeating: "is a person who likes many things ", count: 8)
        let raw = "\(longHallucination)\nUser likes cats."
        let facts = LocalLLMFactExtractor.shared.parseFacts(raw)
        XCTAssertEqual(facts, ["User likes cats."],
            "Lines beyond maxFactLength must be dropped even if they otherwise match the User-prefix rule")
    }

    func testParseFactsAcceptsCommonSubjectVariants() {
        let raw = """
        User likes cats.
        The user lives in Tokyo.
        User's allergy is to peanuts.
        Users drink tea sometimes.
        """
        let facts = LocalLLMFactExtractor.shared.parseFacts(raw)
        XCTAssertEqual(facts, [
            "User likes cats.",
            "The user lives in Tokyo.",
            "User's allergy is to peanuts.",
            "Users drink tea sometimes."
        ])
    }

    // MARK: - End-to-end with a stub generator

    func testExtractRoutesPromptThroughGeneratorAndParsesOutput() async {
        let turns = [
            makeTurn(role: "user", detail: "I live in Osaka and have a cat."),
            makeTurn(role: "ai", detail: "Got it. Anything else?")
        ]
        var capturedPrompt = ""
        let facts = await LocalLLMFactExtractor.shared.extract(
            from: turns,
            using: { prompt, _ in
                capturedPrompt = prompt
                return "- User lives in Osaka.\n- User has a cat."
            }
        )
        XCTAssertTrue(capturedPrompt.contains("Osaka"),
            "Generator should receive the prompt the extractor built from the turns")
        XCTAssertEqual(facts, ["User lives in Osaka.", "User has a cat."])
    }

    func testExtractReturnsEmptyWhenGeneratorOutputsNone() async {
        let turns = [makeTurn(role: "user", detail: "It's raining today.")]
        let facts = await LocalLLMFactExtractor.shared.extract(
            from: turns,
            using: { _, _ in "NONE" }
        )
        XCTAssertEqual(facts, [])
    }

    func testExtractReturnsEmptyForEmptyTurnList() async {
        let facts = await LocalLLMFactExtractor.shared.extract(
            from: [],
            using: { _, _ in "User lives in Tokyo." }
        )
        XCTAssertEqual(facts, [],
            "Empty input must short-circuit without calling the generator")
    }
}
