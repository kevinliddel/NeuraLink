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
        // Three-character lines are noise (model echoing punctuation, etc.).
        let raw = "ok\nUser likes cats.\n.\nUser drinks tea."
        let facts = LocalLLMFactExtractor.shared.parseFacts(raw)
        XCTAssertEqual(facts, ["User likes cats.", "User drinks tea."])
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
