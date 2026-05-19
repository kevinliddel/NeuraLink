//
//  LocalLLMMemoryHierarchyTests.swift
//  NeuraLinkTests
//
//  Unit tests for the pure-logic split of LocalLLMMemoryHierarchy:
//    - `fitToBudget(_:nCtx:)` — budget-driven eviction
//    - `candidatesBeyondWindow(allRecent:windowMessages:lastCompactedID:)`
//      — what to compact
//
//  Phase 2B of docs/local_llm_memory_plan.md.
//
//  Created by Dedicatus on 19/05/2026.
//

import XCTest

@testable import NeuraLink

final class LocalLLMMemoryHierarchyTests: XCTestCase {

    // MARK: - Fixtures

    private func chatEvent(id: Int64, role: String = "user", detail: String = "hi") -> ChatEventItem {
        ChatEventItem(
            id: id, role: role, kind: "chat",
            title: "", detail: detail, pinned: false, timestamp: Date()
        )
    }

    private func msg(_ role: String, _ content: String) -> LLMChatMessage {
        LLMChatMessage(role: role, content: content)
    }

    // MARK: - fitToBudget

    func testFitToBudgetReturnsInputUnchangedWhenUnderThreshold() {
        let messages: [LLMChatMessage] = [
            msg("system", "you are an assistant"),
            msg("user", "hi"),
            msg("assistant", "hello"),
            msg("user", "today?")
        ]
        let result = LocalLLMMemoryHierarchy.fitToBudget(messages, nCtx: 2048)
        XCTAssertEqual(result.count, messages.count,
            "Below-threshold prompts must pass through untouched")
    }

    func testFitToBudgetKeepsSystemAndCurrentUserTurnEvenWhenOverflowing() {
        // Two huge history pairs that will trigger eviction.
        let huge = String(repeating: "a", count: 6_000)
        let messages: [LLMChatMessage] = [
            msg("system", "S"),
            msg("user", "U1"),
            msg("assistant", huge),     // ~1715 tokens — pushes over 0.8×2048
            msg("user", "U2"),
            msg("assistant", huge),
            msg("user", "current")
        ]
        let result = LocalLLMMemoryHierarchy.fitToBudget(messages, nCtx: 2048)
        XCTAssertEqual(result.first?.role, "system",
            "System message must remain at position 0")
        XCTAssertEqual(result.last?.content, "current",
            "Current user turn must remain at the end")
        XCTAssertLessThan(result.count, messages.count,
            "Eviction must have happened given the overflowing input")
    }

    func testFitToBudgetEvictsOldestHistoryFirst() {
        let huge = String(repeating: "a", count: 6_500)
        let messages: [LLMChatMessage] = [
            msg("system", "S"),
            msg("user", "OLDEST"),
            msg("assistant", huge),     // overflowing — gets evicted with OLDEST
            msg("user", "NEWER"),
            msg("assistant", "small reply"),
            msg("user", "current")
        ]
        let result = LocalLLMMemoryHierarchy.fitToBudget(messages, nCtx: 2048)
        // OLDEST and its huge assistant reply should be gone; "NEWER" still there.
        XCTAssertFalse(result.contains { $0.content == "OLDEST" },
            "Oldest user turn must be evicted first")
        XCTAssertFalse(result.contains { $0.content == huge },
            "Oldest assistant turn must be evicted with its user pair")
        XCTAssertTrue(result.contains { $0.content == "NEWER" },
            "Newer history must survive when older history was enough to free budget")
    }

    func testFitToBudgetTerminatesEvenIfBudgetUnreachable() {
        // Single message whose system content alone exceeds budget. Should
        // not infinite-loop — the while-guard `result.count > 2` stops it.
        let absurd = String(repeating: "a", count: 50_000)
        let messages: [LLMChatMessage] = [
            msg("system", absurd),
            msg("user", "current")
        ]
        let result = LocalLLMMemoryHierarchy.fitToBudget(messages, nCtx: 2048)
        XCTAssertEqual(result.count, 2,
            "When only system + user remain, fitToBudget must stop trying to evict")
    }

    // MARK: - candidatesBeyondWindow

    func testCandidatesBeyondWindowReturnsEmptyWhenEverythingFitsInWindow() {
        let events = (1...10).map { chatEvent(id: Int64($0)) }
        let result = LocalLLMMemoryHierarchy.candidatesBeyondWindow(
            allRecent: events, windowMessages: 12, lastCompactedID: 0)
        XCTAssertTrue(result.isEmpty)
    }

    func testCandidatesBeyondWindowReturnsAgedOutEntriesWhenWindowOverflows() {
        // 20 events newest-first: id 20 (newest) → id 1 (oldest). Window is 12.
        let events = (1...20).reversed().map { chatEvent(id: Int64($0)) }
        let result = LocalLLMMemoryHierarchy.candidatesBeyondWindow(
            allRecent: events, windowMessages: 12, lastCompactedID: 0)
        XCTAssertEqual(result.count, 8,
            "Events beyond the verbatim window should all be candidates")
        XCTAssertTrue(result.allSatisfy { $0.id <= 8 },
            "Candidates must be the oldest events (ids 1…8), not the newest")
    }

    func testCandidatesBeyondWindowFiltersAlreadyCompacted() {
        let events = (1...20).reversed().map { chatEvent(id: Int64($0)) }
        let result = LocalLLMMemoryHierarchy.candidatesBeyondWindow(
            allRecent: events, windowMessages: 12, lastCompactedID: 5)
        // Aged-out: ids 1...8. With lastCompactedID=5, only 6, 7, 8 remain.
        XCTAssertEqual(result.map(\.id).sorted(), [6, 7, 8])
    }

    func testCandidatesBeyondWindowEmptyWhenAllAgedOutAreAlreadyCompacted() {
        let events = (1...20).reversed().map { chatEvent(id: Int64($0)) }
        let result = LocalLLMMemoryHierarchy.candidatesBeyondWindow(
            allRecent: events, windowMessages: 12, lastCompactedID: 100)
        XCTAssertTrue(result.isEmpty,
            "lastCompactedID greater than every event id must yield no candidates")
    }
}
