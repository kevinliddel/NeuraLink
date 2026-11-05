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

    /// What this visit carries, frozen on the first prompt build.
    private struct Visit {
        let foregroundAt: Date
        let character: String
        let mood: CompanionMood?
        let awayLine: String?
        let lore: LoreFragment?
    }

    private var visit: Visit?

    init(store: MemoryStore = .shared) {
        self.store = store
    }

    // MARK: - Prompt

    /// Lines for the Companion State block. `absent` is whether a
    /// time-apart line exists (an hour or more away), the only time "while
    /// you were apart" makes sense. The lore line is skipped on the compact
    /// tier, where it would cost the small model too much attention.
    func lines(character: String, stage: String, absent: Bool, compact: Bool, now: Date = Date()) -> [String] {
        guard PresenceSettings.shared.innerLifeEnabled, !character.isEmpty else { return [] }
        let visit = refreshVisit(character: character, stage: stage, absent: absent, now: now)
        var out: [String] = []
        if let mood = visit.mood { out.append(mood.promptLine) }
        if let away = visit.awayLine {
            out.append("While you were apart, on your side: \"\(away)\" — bring it up early if it fits.")
        }
        if let lore = visit.lore, !compact { out.append(LoreRules.promptLine(for: lore)) }
        return out
    }

    /// Whether the mutual-sharing guidance applies: stories are open at
    /// this stage.
    func sharesInReturn(stage: String) -> Bool {
        PresenceSettings.shared.innerLifeEnabled && !LoreTier.unlocked(atStage: stage).isEmpty
    }

    /// The away line for the absence greeting: the one this visit holds,
    /// else the latest untold one (stamped told), since a greeting only
    /// fires after hours away.
    func awayLineForGreeting(character: String) -> String? {
        guard PresenceSettings.shared.innerLifeEnabled else { return nil }
        if let visit, visit.character == character { return visit.awayLine }
        return takeUntoldAwayLine(character: character)
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
            from: CharacterLoreCatalogue.fragments(for: character), stage: stage,
            reveals: store.loreReveals(character: character), now: now, roll: Double.random(in: 0..<1))
        if let lore {
            store.recordLoreReveal(character: character, fragmentID: lore.id)
            nlLog("[InnerLife] \(character) may share \(lore.id)", level: .info)
        }
        let fresh = Visit(
            foregroundAt: foregroundAt, character: character,
            mood: currentMood(character: character, now: now),
            awayLine: absent ? takeUntoldAwayLine(character: character) : nil,
            lore: lore)
        visit = fresh
        return fresh
    }

    private func currentMood(character: String, now: Date) -> CompanionMood? {
        guard let entry = store.latestJournalEntry(character: character),
            CompanionMood.applies(recordedAt: entry.createdAt, now: now)
        else { return nil }
        return CompanionMood.parse(entry.mood)
    }

    /// The latest reflection's away line if it has not been told, stamping
    /// it told.
    private func takeUntoldAwayLine(character: String) -> String? {
        guard let entry = store.latestJournalEntry(character: character),
            !entry.awayLine.isEmpty, !entry.awayTold
        else { return nil }
        store.markAwayTold(id: entry.id)
        return entry.awayLine
    }
}
