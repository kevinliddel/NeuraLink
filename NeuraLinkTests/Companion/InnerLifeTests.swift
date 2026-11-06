//
//  InnerLifeTests.swift
//  NeuraLinkTests
//
//  Inner life (docs/Companion/LIVING_COMPANION.md): lore tiers open with
//  the relationship stage and are offered untold-first, the reflection's
//  AWAY / MOOD lines are parsed and stored, the mood weights idles and
//  rests on the face, and the visit holds its lines. Shares the app-host
//  MemoryStore singleton; every test namespaces its character and cleans up.
//

import Foundation
import Testing

@testable import NeuraLink

@MainActor
@Suite("Inner life")
struct InnerLifeTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func cleanup(_ character: String) {
        MemoryStore.shared.deleteJournal(character: character)
        MemoryStore.shared.deleteLoreReveals(character: character)
    }

    // MARK: - Lore

    @Test("Tiers open with the stage: nothing before Friends, everything at Close")
    func tiersByStage() {
        #expect(LoreTier.unlocked(atStage: "New").isEmpty)
        #expect(LoreTier.unlocked(atStage: "Acquaintances").isEmpty)
        #expect(LoreTier.unlocked(atStage: "Friends") == [.friends])
        #expect(LoreTier.unlocked(atStage: "Good Friends") == [.friends, .goodFriends])
        #expect(LoreTier.unlocked(atStage: "Close") == LoreTier.allCases)
    }

    @Test("Every bundled character has three fragments per tier, with stable unique ids")
    func catalogue() {
        for character in CharacterLoreCatalogue.characters {
            let fragments = CharacterLoreCatalogue.fragments(for: character)
            #expect(Set(fragments.map(\.id)).count == fragments.count)
            for tier in LoreTier.allCases {
                #expect(fragments.filter { $0.tier == tier }.count == 3, "\(character) \(tier)")
            }
            for fragment in fragments {
                #expect(fragment.id.hasPrefix("\(character)."))
                #expect((40...260).contains(fragment.text.count), "\(fragment.id)")
            }
        }
        #expect(CharacterLoreCatalogue.fragments(for: "OZ").count == 9)
        #expect(CharacterLoreCatalogue.fragments(for: "imported-vrm").isEmpty)
    }

    @Test("An untold story from the highest open tier is offered first; the roll picks among them")
    func offerUntoldFirst() {
        let fragments = CharacterLoreCatalogue.fragments(for: "oz")
        #expect(LoreRules.offer(from: fragments, stage: "New", reveals: [], now: now, roll: 0) == nil)
        #expect(LoreRules.offer(from: fragments, stage: "Friends", reveals: [], now: now, roll: 0)?.id == "oz.friends.1")
        #expect(LoreRules.offer(from: fragments, stage: "Close", reveals: [], now: now, roll: 0)?.id == "oz.close.1")
        #expect(LoreRules.offer(from: fragments, stage: "Close", reveals: [], now: now, roll: 0.99)?.id == "oz.close.3")

        // Close all told: the next tier down still has untold ones.
        let closeTold = (1...3).map { LoreReveal(fragmentID: "oz.close.\($0)", revealedAt: now) }
        #expect(LoreRules.offer(from: fragments, stage: "Close", reveals: closeTold, now: now, roll: 0.5)?.id == "oz.goodFriends.2")
    }

    @Test("Told stories rest for three days, then the oldest comes back")
    func retellAfterRest() {
        let fragments = CharacterLoreCatalogue.fragments(for: "oz").filter { $0.tier == .friends }
        let fresh = fragments.map { LoreReveal(fragmentID: $0.id, revealedAt: now.addingTimeInterval(-3600)) }
        #expect(LoreRules.offer(from: fragments, stage: "Friends", reveals: fresh, now: now, roll: 0) == nil)

        var rested = fresh
        rested[1] = LoreReveal(fragmentID: "oz.friends.2", revealedAt: now.addingTimeInterval(-4 * 86_400))
        #expect(LoreRules.offer(from: fragments, stage: "Friends", reveals: rested, now: now, roll: 0)?.id == "oz.friends.2")
    }

    @Test("Prompt lines quote the story and ask for one natural telling")
    func loreLine() {
        let fragment = CharacterLoreCatalogue.fragments(for: "sonya")[0]
        let line = LoreRules.promptLine(for: fragment)
        #expect(line.contains("\"\(fragment.text)\""))
        #expect(line.contains("never more than once"))
        #expect(LoreRules.mutualSharingGuidance.contains("something real of your own"))
    }

    // MARK: - Mood

    @Test("MOOD words parse case-insensitively, with synonyms; junk is nil")
    func moodParse() {
        #expect(CompanionMood.parse("Wistful.") == .wistful)
        #expect(CompanionMood.parse("  playful ") == .playful)
        #expect(CompanionMood.parse("Happy, mostly") == .bright)
        #expect(CompanionMood.parse("tired") == .weary)
        #expect(CompanionMood.parse("purple") == nil)
        #expect(CompanionMood.parse("") == nil)
    }

    @Test("The resting face fades out over ten minutes and a mood lasts a day")
    func moodFade() {
        #expect(CompanionMood.faceStrength(elapsed: 0) == 1)
        #expect(abs(CompanionMood.faceStrength(elapsed: 300) - 0.5) < 0.001)
        #expect(CompanionMood.faceStrength(elapsed: 600) == 0)
        #expect(CompanionMood.faceStrength(elapsed: 3_600) == 0)
        #expect(CompanionMood.applies(recordedAt: now.addingTimeInterval(-23 * 3600), now: now))
        #expect(!CompanionMood.applies(recordedAt: now.addingTimeInterval(-25 * 3600), now: now))
    }

    @Test("Quiet moods favour the resting idles, lively moods the energetic ones")
    func idleWeights() {
        #expect(CompanionMood.wistful.idleWeight(forClip: "relax") > CompanionMood.wistful.idleWeight(forClip: "neutral_2"))
        #expect(CompanionMood.wistful.idleWeight(forClip: "male_powerful") < 1)
        #expect(CompanionMood.bright.idleWeight(forClip: "male_powerful") > 1)
        #expect(CompanionMood.bright.idleWeight(forClip: "waiting") < 1)
        #expect(CompanionMood.tender.idleWeight(forClip: "relax") == 1)
        for mood in CompanionMood.allCases {
            let face = mood.restingFace
            #expect(face.happy >= 0 && face.relaxed >= 0 && face.sad >= 0)
            #expect(max(face.happy, face.relaxed, face.sad) <= 0.25, "\(mood) rests too hard")
        }
    }

    @Test("Weighted pick lands by cumulative weight and is nil without any")
    func weightedPick() {
        let items = ["a", "b", "c"]
        let weights = ["a": 1.0, "b": 2.0, "c": 1.0]
        #expect(CompanionMood.pick(items, weight: { weights[$0] ?? 0 }, roll: 0.1) == "a")
        #expect(CompanionMood.pick(items, weight: { weights[$0] ?? 0 }, roll: 0.5) == "b")
        #expect(CompanionMood.pick(items, weight: { weights[$0] ?? 0 }, roll: 0.9) == "c")
        #expect(CompanionMood.pick(items, weight: { _ in 0 }, roll: 0.5) == nil)
        #expect(CompanionMood.pick([String](), weight: { _ in 1 }, roll: 0.5) == nil)
    }

    // MARK: - Reflection and store

    @Test("The reflection's AWAY and MOOD lines are parsed; an unknown mood becomes none")
    func parseAwayAndMood() {
        let raw = """
        DIARY: We talked about the sea.
        OPENER: Did you get there?
        NOTIFY: Come tell me.
        AWAY: I rearranged the shelf again,
        by colour this time.
        MOOD: Playful!
        TRAIT: likes the coast
        """
        let reflection = ReflectionManager.parse(raw)
        #expect(reflection?.awayLine == "I rearranged the shelf again, by colour this time.")
        #expect(reflection?.mood == "playful")
        #expect(reflection?.trait == "likes the coast")

        let odd = ReflectionManager.parse("DIARY: Fine.\nMOOD: purple")
        #expect(odd?.mood == "")
        #expect(odd?.awayLine == "")
        #expect(ReflectionManager.systemInstruction(character: "oz").contains("MOOD: one word"))
    }

    @Test("Away line and mood round-trip through the journal, and the line is told once")
    func journalRoundTrip() {
        let character = "innerlife-test-journal"
        cleanup(character)
        defer { cleanup(character) }

        let id = MemoryStore.shared.insertJournalEntry(
            character: character, conversationID: 0, diary: "d", opener: "o", notificationLine: "n",
            awayLine: "I dreamed of rain.", mood: "wistful")
        #expect(id > 0)
        let entry = MemoryStore.shared.latestJournalEntry(character: character)
        #expect(entry?.awayLine == "I dreamed of rain.")
        #expect(entry?.mood == "wistful")
        #expect(entry?.awayTold == false)

        MemoryStore.shared.markAwayTold(id: id)
        #expect(MemoryStore.shared.latestJournalEntry(character: character)?.awayTold == true)
    }

    @Test("Lore reveals are recorded per fragment, read newest first and wiped by reset")
    func loreReveals() {
        let character = "innerlife-test-lore"
        cleanup(character)
        defer { cleanup(character) }

        MemoryStore.shared.recordLoreReveal(character: character, fragmentID: "oz.friends.1")
        MemoryStore.shared.recordLoreReveal(character: character, fragmentID: "oz.friends.2")
        MemoryStore.shared.recordLoreReveal(character: character, fragmentID: "oz.friends.1")
        let reveals = MemoryStore.shared.loreReveals(character: character)
        #expect(reveals.count == 2)
        #expect(Set(reveals.map(\.fragmentID)) == ["oz.friends.1", "oz.friends.2"])

        MemoryStore.shared.deleteLoreReveals(character: character)
        #expect(MemoryStore.shared.loreReveals(character: character).isEmpty)
    }

    @Test("A visit holds its mood and away lines, and tells the away line once")
    func visitLines() {
        let character = "innerlife-test-visit"
        cleanup(character)
        defer { cleanup(character) }
        let wasEnabled = PresenceSettings.shared.innerLifeEnabled
        PresenceSettings.shared.innerLifeEnabled = true
        defer { PresenceSettings.shared.innerLifeEnabled = wasEnabled }

        _ = MemoryStore.shared.insertJournalEntry(
            character: character, conversationID: 0, diary: "d", opener: "o", notificationLine: "n",
            awayLine: "I watched the rain for a while.", mood: "calm")
        let inner = CompanionInnerLife(store: .shared)

        let lines = inner.lines(character: character, stage: "Friends", absent: true, compact: false)
        #expect(lines.count == 2, "\(lines)")
        #expect(lines.first?.contains("calm") == true)
        #expect(lines.last?.contains("I watched the rain for a while.") == true)
        // Same visit, same lines; the away line was stamped told on the first build.
        #expect(inner.lines(character: character, stage: "Friends", absent: true, compact: false) == lines)
        #expect(MemoryStore.shared.latestJournalEntry(character: character)?.awayTold == true)
        #expect(inner.awayLineForGreeting(character: character) == "I watched the rain for a while.")
        // No lore for a character without a catalogue, so the compact tier reads the same.
        #expect(inner.lines(character: character, stage: "Friends", absent: true, compact: true) == lines)
        #expect(inner.sharesInReturn(stage: "Friends"))
        #expect(!inner.sharesInReturn(stage: "New"))
    }

    @Test("The greeting works the away line in after the saved thought")
    func greetingAwayLine() {
        let plain = ProactivePresenceManager.greetingEvent(opener: "Did you get there?", hoursAway: 7, timeOfDay: "morning")
        let withAway = ProactivePresenceManager.greetingEvent(
            opener: "Did you get there?", hoursAway: 7, timeOfDay: "morning", awayLine: "I dreamed of rain.")
        #expect(plain.hasSuffix("\"Did you get there?\"*"))
        #expect(withAway.contains("\"Did you get there?\""))
        #expect(withAway.contains("while you were apart: \"I dreamed of rain.\""))
        #expect(withAway.hasSuffix("*"))
        #expect(ProactivePresenceManager.greetingEvent(opener: nil, hoursAway: 7, timeOfDay: "morning", awayLine: "")
            == ProactivePresenceManager.greetingEvent(opener: nil, hoursAway: 7, timeOfDay: "morning"))
    }

    @Test("Inner life is on in Balanced and Lively, off in Quiet")
    func presets() {
        #expect(!AutonomyPreset.quiet.flags.innerLife)
        #expect(AutonomyPreset.balanced.flags.innerLife)
        #expect(AutonomyPreset.lively.flags.innerLife)
    }
}
