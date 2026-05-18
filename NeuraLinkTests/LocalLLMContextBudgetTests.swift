//
//  LocalLLMContextBudgetTests.swift
//  NeuraLinkTests
//
//  Unit tests for the token-estimation and compaction-trigger heuristics
//  used by the local LLM 3-tier memory hierarchy. Phase 2A of the plan in
//  docs/local_llm_memory_plan.md.
//
//  Created by Dedicatus on 18/05/2026.
//

import XCTest

@testable import NeuraLink

final class LocalLLMContextBudgetTests: XCTestCase {

    // MARK: - estimateTokens(in: String)

    func testEstimateTokensEmptyStringIsZero() {
        XCTAssertEqual(LocalLLMContextBudget.estimateTokens(in: ""), 0)
    }

    func testEstimateTokensRoughlyMatchesBytesOverThreePointFive() {
        // 35-byte ASCII string → expected ~10 tokens.
        let s = String(repeating: "a", count: 35)
        let estimate = LocalLLMContextBudget.estimateTokens(in: s)
        XCTAssertEqual(estimate, 10, "35 / 3.5 = 10 expected")
    }

    func testEstimateTokensCeilsUp() {
        // 4 bytes → ceil(4 / 3.5) = 2 tokens (not 1).
        let estimate = LocalLLMContextBudget.estimateTokens(in: "abcd")
        XCTAssertEqual(estimate, 2)
    }

    // MARK: - estimateTokens(in: [LLMChatMessage])

    func testEstimateTokensIncludesPerMessageOverhead() {
        // Two empty messages → overhead-only.
        let messages = [
            LLMChatMessage(role: "user", content: ""),
            LLMChatMessage(role: "assistant", content: "")
        ]
        let estimate = LocalLLMContextBudget.estimateTokens(in: messages)
        // 2 × templateOverheadPerMessage(=10) + 2 × estimateTokens("user"=4 bytes → 2) and
        // ("assistant"=9 bytes → 3) = 20 + 2 + 3 = 25
        XCTAssertEqual(estimate, 25)
    }

    // MARK: - shouldCompact

    func testShouldCompactReturnsFalseWhenUnderThreshold() {
        let messages = [LLMChatMessage(role: "user", content: "hi")]
        XCTAssertFalse(
            LocalLLMContextBudget.shouldCompact(messages: messages, nCtx: 2048))
    }

    func testShouldCompactReturnsTrueWhenOverThreshold() {
        // 7000 bytes / 3.5 = 2000 tokens, which is > 0.8 × 2048 = 1638.
        let content = String(repeating: "a", count: 7000)
        let messages = [LLMChatMessage(role: "user", content: content)]
        XCTAssertTrue(
            LocalLLMContextBudget.shouldCompact(messages: messages, nCtx: 2048))
    }

    func testShouldCompactReturnsFalseWhenNCtxIsZero() {
        // Defensive: nCtx = 0 should never trigger compaction.
        let messages = [LLMChatMessage(role: "user", content: String(repeating: "a", count: 9999))]
        XCTAssertFalse(
            LocalLLMContextBudget.shouldCompact(messages: messages, nCtx: 0))
    }

    // MARK: - turnsToDrop

    func testTurnsToDropReturnsZeroWhenUnderThreshold() {
        let messages = [LLMChatMessage(role: "user", content: "hi")]
        XCTAssertEqual(
            LocalLLMContextBudget.turnsToDrop(messages: messages, nCtx: 2048),
            0)
    }

    func testTurnsToDropReturnsAtLeastMinimumPairsWhenOverThreshold() {
        // Just barely over threshold — overrun is small so pairs ≈ 1, but
        // minimum is 2.
        let content = String(repeating: "a", count: 5800)  // ~1657 tokens
        let messages = [LLMChatMessage(role: "user", content: content)]
        let pairs = LocalLLMContextBudget.turnsToDrop(
            messages: messages, nCtx: 2048, minimumPairs: 2)
        XCTAssertGreaterThanOrEqual(pairs, 2)
    }

    func testTurnsToDropScalesWithOverrun() {
        // Severely overrun → more pairs to drop.
        let content = String(repeating: "a", count: 12_000)
        let messages = [LLMChatMessage(role: "user", content: content)]
        let pairs = LocalLLMContextBudget.turnsToDrop(messages: messages, nCtx: 2048)
        XCTAssertGreaterThan(pairs, 2,
            "Heavy overrun should require dropping more than the minimum pair count")
    }
}
