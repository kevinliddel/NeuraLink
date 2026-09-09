//
//  PersonalityEvolutionTests.swift
//  NeuraLinkTests
//
//  Living Companion Phase 2: the unified affinity curve, TRAIT parsing, and
//  the capped/decaying trait pool. Shares the app-host MemoryStore singleton;
//  every test namespaces its character and cleans up.
//

import Foundation
import Testing

@testable import NeuraLink

@Suite("Personality Evolution")
struct PersonalityEvolutionTests {

    private func cleanup(_ character: String) {
        MemoryStore.shared.deleteAllTraits(character: character)
        MemoryStore.shared.deleteJournal(character: character)
    }

    // MARK: - Relationship curve (v2 — connection, not XP)

    private func inputs(
        turns: Int = 0, facts: Int = 0, days: Int = 0,
        reflections: Int = 0, sinceSeen: Double? = 0
    ) -> CompanionAffinity.Inputs {
        CompanionAffinity.Inputs(
            turns: turns, factCount: facts, sharedDays: days,
            reflectionCount: reflections, daysSinceLastSeen: sinceSeen)
    }

    @Test("Volume alone can't buy closeness — one chatty night stays Acquaintances")
    func volumeCannotGrind() {
        // 1000 turns, all on a single day, nothing learned.
        let allNighter = CompanionAffinity.score(
            inputs(turns: 1_000, days: 1, sinceSeen: 0))
        #expect(allNighter < 0.25, "one marathon night scored \(allNighter)")
        #expect(CompanionAffinity.label(forScore: allNighter, turns: 1_000) == "Acquaintances")
    }

    @Test("Shared days and depth carry the relationship")
    func daysAndDepthDominate() {
        // A month of genuine, regular contact with real learning.
        let genuine = CompanionAffinity.score(
            inputs(turns: 150, facts: 20, days: 30, reflections: 12, sinceSeen: 1))
        #expect(genuine >= 0.75, "a month of real contact scored \(genuine)")
        #expect(CompanionAffinity.label(forScore: genuine, turns: 150) == "Close")

        // Same volume, crammed into 3 days with little depth → much lower.
        let crammed = CompanionAffinity.score(
            inputs(turns: 150, facts: 2, days: 3, reflections: 1, sinceSeen: 1))
        #expect(crammed < genuine / 2)
    }

    @Test("Score is zero before the first turn and capped at 0.95")
    func scoreBounds() {
        #expect(CompanionAffinity.score(inputs(turns: 0, facts: 50, days: 50)) == 0)
        let maxed = CompanionAffinity.score(
            inputs(turns: 10_000, facts: 500, days: 500, reflections: 500, sinceSeen: 0))
        #expect(maxed == 0.95)
    }

    @Test("Absence cools the bond gently and never resets it")
    func absenceCooling() {
        #expect(CompanionAffinity.recencyFactor(daysSince: nil) == 1.0)
        #expect(CompanionAffinity.recencyFactor(daysSince: 2) == 1.0)
        let month = CompanionAffinity.recencyFactor(daysSince: 30)
        #expect(month < 1.0 && month > 0.65)
        // Floor: even a year away leaves an old friend, not a stranger.
        #expect(CompanionAffinity.recencyFactor(daysSince: 365) == 0.65)
    }

    @Test("Five stages, one curve for meter and prompt")
    func affinityLabels() {
        #expect(CompanionAffinity.label(forScore: 0.9, turns: 2) == "New")
        #expect(CompanionAffinity.label(forScore: 0.2, turns: 10) == "Acquaintances")
        #expect(CompanionAffinity.label(forScore: 0.4, turns: 50) == "Friends")
        #expect(CompanionAffinity.label(forScore: 0.6, turns: 100) == "Good Friends")
        #expect(CompanionAffinity.label(forScore: 0.8, turns: 200) == "Close")
    }

    @Test("Every stage carries distinct persona guidance")
    func stageGuidance() {
        let stages = ["New", "Acquaintances", "Friends", "Good Friends", "Close"]
        let guidance = stages.map(CompanionAffinity.stageGuidance(for:))
        #expect(Set(guidance).count == stages.count)  // all distinct
        #expect(guidance[0].contains("reserved"))
        #expect(guidance[4].contains("close"))
        // Unknown labels still return usable guidance.
        #expect(!CompanionAffinity.stageGuidance(for: "???").isEmpty)
    }

    // MARK: - TRAIT parsing

    @Test("Parses the optional TRAIT line")
    func parseTrait() {
        let raw = """
        DIARY: We debugged their Swift project together.
        OPENER: Any luck with that crash?
        NOTIFY: Your code misses you.
        TRAIT: Gets absorbed in debugging late at night.
        """
        let reflection = ReflectionManager.parse(raw)
        #expect(reflection?.trait == "Gets absorbed in debugging late at night.")
    }

    @Test("Missing TRAIT line yields an empty trait, not a failure")
    func parseWithoutTrait() {
        let reflection = ReflectionManager.parse("DIARY: A quiet chat about the weather.")
        #expect(reflection != nil)
        #expect(reflection?.trait == "")
    }

    // MARK: - Trait pool

    @Test("recordTrait inserts, and rejects junk lengths")
    func traitInsertAndJunk() {
        let character = "test_evo_insert"
        cleanup(character)
        defer { cleanup(character) }

        ReflectionManager.recordTrait(character: character, trait: "Loves rainy-day conversations")
        #expect(MemoryStore.shared.traits(character: character).count == 1)

        ReflectionManager.recordTrait(character: character, trait: "short")  // < 8 chars
        ReflectionManager.recordTrait(character: character, trait: String(repeating: "x", count: 200))
        ReflectionManager.recordTrait(character: "", trait: "Valid length but no character")
        #expect(MemoryStore.shared.traits(character: character).count == 1)
    }

    @Test("Repeated trait bumps weight instead of duplicating")
    func traitBump() {
        let character = "test_evo_bump"
        cleanup(character)
        defer { cleanup(character) }

        ReflectionManager.recordTrait(character: character, trait: "Teases about coffee habits")
        ReflectionManager.recordTrait(character: character, trait: "TEASES ABOUT COFFEE HABITS")

        let traits = MemoryStore.shared.traits(character: character)
        #expect(traits.count == 1)
        // 1.0, decayed to 0.95, then bumped +1.0 → 1.95.
        #expect(abs(traits[0].weight - 1.95) < 0.001)
    }

    @Test("Pool caps at five — the weakest trait is evicted")
    func traitCapEviction() {
        let character = "test_evo_cap"
        cleanup(character)
        defer { cleanup(character) }

        for i in 1...ReflectionManager.maxTraitsPerCharacter {
            ReflectionManager.recordTrait(character: character, trait: "Recurring trait number \(i)")
        }
        #expect(MemoryStore.shared.traits(character: character).count == 5)

        // The oldest trait has decayed the most; a sixth evicts it.
        ReflectionManager.recordTrait(character: character, trait: "Fresh sixth trait arriving")
        let traits = MemoryStore.shared.traits(character: character)
        #expect(traits.count == 5)
        #expect(traits.contains { $0.trait == "Fresh sixth trait arriving" })
        #expect(!traits.contains { $0.trait == "Recurring trait number 1" })
    }

    @Test("decayTraits multiplies weights down")
    func decay() {
        let character = "test_evo_decay"
        cleanup(character)
        defer { cleanup(character) }

        MemoryStore.shared.upsertTrait(character: character, trait: "A trait to decay", weight: 2.0)
        MemoryStore.shared.decayTraits(character: character, factor: 0.5)
        let traits = MemoryStore.shared.traits(character: character)
        #expect(abs(traits[0].weight - 1.0) < 0.001)
    }

    // MARK: - Carry-over formatter (Phase 6 ②)

    @Test("Diary wins the carry-over; closing exchange is the fallback")
    @MainActor
    func carryOverPriority() {
        let diaryLine = CompanionStateManager.carryOverText(
            diary: "We argued about pineapple pizza.",
            closingRole: "user", closingContent: "ignored")
        #expect(diaryLine == "Last session, you privately noted: We argued about pineapple pizza.")

        let userClose = CompanionStateManager.carryOverText(
            diary: nil, closingRole: "user", closingContent: "see you tomorrow!")
        #expect(userClose == "Your previous conversation ended with the user saying: \"see you tomorrow!\"")

        let aiClose = CompanionStateManager.carryOverText(
            diary: nil, closingRole: "assistant", closingContent: "sleep well!")
        #expect(aiClose?.contains("with you saying") == true)

        #expect(CompanionStateManager.carryOverText(
            diary: nil, closingRole: nil, closingContent: nil) == nil)
        #expect(CompanionStateManager.carryOverText(
            diary: "", closingRole: nil, closingContent: "") == nil)
    }

    @Test("Carry-over quotes are capped")
    @MainActor
    func carryOverCap() {
        let long = String(repeating: "b", count: 500)
        let line = CompanionStateManager.carryOverText(
            diary: nil, closingRole: "user", closingContent: long)
        #expect(line != nil)
        #expect(line!.count < 200)
    }

    // MARK: - Prompt block

    @Test("promptContext carries traits and the latest diary line")
    @MainActor
    func promptBlockInjection() {
        let character = "test_evo_prompt"
        cleanup(character)
        defer { cleanup(character) }

        MemoryStore.shared.upsertTrait(
            character: character, trait: "Hums when thinking hard", weight: 2.0)
        _ = MemoryStore.shared.insertJournalEntry(
            character: character, conversationID: 777_001,
            diary: "We planned a tiny garden on the balcony.",
            opener: "", notificationLine: "")

        let block = CompanionStateManager.shared.promptContext(characterName: character)
        #expect(block.contains("Hums when thinking hard"))
        #expect(block.contains("We planned a tiny garden on the balcony."))

        // Compact mode still carries traits (capped) — used on the 1B tier.
        let compact = CompanionStateManager.shared.promptContext(
            characterName: character, compact: true)
        #expect(compact.contains("Hums when thinking hard"))
    }
}
