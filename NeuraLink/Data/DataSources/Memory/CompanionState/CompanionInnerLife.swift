//
//  CompanionInnerLife.swift
//  NeuraLink
//
//  The companion's own side of the relationship — Inner life
//  (docs/Companion/LIVING_COMPANION.md): a story about itself that the
//  relationship stage has unlocked, what it did while the user was away
//  (from the last reflection, told once), and the mood that session left.
//  All three are chosen once per foreground visit and held, the way the
//  time-apart line is, so the prompt block stays stable for the session.
//
//  Created by Dedicatus on 05/11/2026.
//

import Foundation

final class CompanionInnerLife {
    static let shared = CompanionInnerLife()

    private let store: MemoryStore
    /// Where a character's stories come from: the bundled catalogue, or
    /// what a test hands in.
    private let fragments: (String) -> [LoreFragment]

    /// What this visit carries, frozen on the first prompt build.
    private struct Visit {
        let foregroundAt: Date
        let character: String
        let mood: CompanionMood?
        let awayLine: String?
        let lore: LoreFragment?
        /// The story has gone into a prompt and been stamped revealed.
        var loreOffered = false
    }

    private var visit: Visit?

    init(store: MemoryStore = .shared, fragments: @escaping (String) -> [LoreFragment] = CharacterLoreCatalogue.fragments(for:)) {
        self.store = store
        self.fragments = fragments
    }

    // MARK: - Prompt

    /// Lines for the Companion State block. `absent` is whether a
    /// time-apart line exists (an hour or more away), the only time "while
    /// you were apart" makes sense. The lore line is skipped on the compact
    /// tier, where it would cost the small model too much attention — and
    /// a story that was never put to the model is not stamped shared.
    func lines(character: String, stage: String, absent: Bool, compact: Bool, now: Date = Date()) -> [String] {
        guard PresenceSettings.shared.innerLifeEnabled, !character.isEmpty else { return [] }
        let visit = refreshVisit(character: character, stage: stage, absent: absent, now: now)
        var out: [String] = []
        if let mood = visit.mood { out.append(mood.promptLine) }
        if let away = visit.awayLine {
            out.append("While you were apart, on your side: \"\(away)\" — bring it up early if it fits.")
        }
        if let lore = visit.lore, !compact {
            out.append(LoreRules.promptLine(for: lore))
            offerLore(lore, character: character)
        }
        return out
    }

    /// Whether the mutual-sharing guidance applies: stories are open at
    /// this stage.
    func sharesInReturn(stage: String) -> Bool {
        PresenceSettings.shared.innerLifeEnabled && !LoreTier.unlocked(atStage: stage).isEmpty
    }

    /// The away line for the absence greeting, left untold until the
    /// greeting that carries it is accepted (`awayLineTold`), so a rejected
    /// cue keeps it for the next try. Nil once this visit's prompt block
    /// has been built: the block either carries the line or found none, and
    /// the greeting must not say it a second time.
    func awayLineForGreeting(character: String) -> String? {
        guard PresenceSettings.shared.innerLifeEnabled else { return nil }
        if let visit, visit.character == character { return nil }
        return untoldAwayEntry(character: character)?.awayLine
    }

    /// The greeting carried `line`: stamp it told so the prompt block does
    /// not repeat it. A line that is no longer the untold one is left alone.
    func awayLineTold(character: String, line: String) {
        guard let entry = untoldAwayEntry(character: character), entry.awayLine == line else { return }
        store.markAwayTold(id: entry.id)
    }

    // MARK: - Body

    /// The mood the body carries into this session; nil is neutral.
    func bodyMood(character: String, now: Date = Date()) -> CompanionMood? {
        guard PresenceSettings.shared.innerLifeEnabled else { return nil }
        return currentMood(character: character, now: now)
    }

    // MARK: - Visit

    private func refreshVisit(character: String, stage: String, absent: Bool, now: Date) -> Visit {
        let foregroundAt = InteractionClock.shared.foregroundAt
        if let visit, visit.foregroundAt == foregroundAt, visit.character == character { return visit }

        let lore = LoreRules.offer(
            from: fragments(character), stage: stage,
            reveals: store.loreReveals(character: character), now: now, roll: Double.random(in: 0..<1))
        let fresh = Visit(
            foregroundAt: foregroundAt, character: character,
            mood: currentMood(character: character, now: now),
            awayLine: absent ? takeUntoldAwayLine(character: character) : nil,
            lore: lore)
        visit = fresh
        return fresh
    }

    /// Stamps the story revealed the first time a prompt carries it; a
    /// visit whose prompts all left it out keeps it eligible for next time.
    private func offerLore(_ lore: LoreFragment, character: String) {
        guard visit?.loreOffered == false else { return }
        store.recordLoreReveal(character: character, fragmentID: lore.id)
        visit?.loreOffered = true
        nlLog("[InnerLife] \(character) may share \(lore.id)", level: .info)
    }

    private func currentMood(character: String, now: Date) -> CompanionMood? {
        guard let entry = store.latestJournalEntry(character: character),
            CompanionMood.applies(recordedAt: entry.createdAt, now: now)
        else { return nil }
        return CompanionMood.parse(entry.mood)
    }

    /// The latest reflection's entry while its away line is untold.
    private func untoldAwayEntry(character: String) -> JournalEntry? {
        guard let entry = store.latestJournalEntry(character: character),
            !entry.awayLine.isEmpty, !entry.awayTold
        else { return nil }
        return entry
    }

    /// The latest untold away line, stamped told — the prompt block carries
    /// it for the rest of the visit.
    private func takeUntoldAwayLine(character: String) -> String? {
        guard let entry = untoldAwayEntry(character: character) else { return nil }
        store.markAwayTold(id: entry.id)
        return entry.awayLine
    }
}
