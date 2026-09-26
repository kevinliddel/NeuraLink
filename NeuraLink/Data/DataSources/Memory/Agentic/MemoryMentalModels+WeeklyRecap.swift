//
//  MemoryMentalModels+WeeklyRecap.swift
//  NeuraLink
//
//  The weekly recap standing question (docs/MEMORY_OWNERSHIP_PLAN.md §M1):
//  a per-character summary of the last seven days built from dated facts,
//  observations and journal entries, refreshed when the ISO week changes
//  or new memories arrive, and surfaced as a card in the Memory page with
//  an "Ask about it" follow-up.
//
//  Created by Dedicatus on 27/09/2026.
//

import Foundation

extension MemoryMentalModels {

    static let weeklyRecapSlug = "weekly_recap"
    static let recapWindow: TimeInterval = 7 * 86_400
    nonisolated static let recapAskMarker = "ASK:"

    static func weeklyRecapQuestion(character: String) -> String {
        "Summarise the past 7 days with the user as \(character.capitalized): what you talked about, what changed in their life, "
            + "in two or three short sentences. Then on a final line starting with \"\(recapAskMarker)\" write one question worth asking them next time."
    }

    /// Summary text and the follow-up question parsed from a recap.
    nonisolated static func recapParts(_ content: String) -> (summary: String, ask: String) {
        var summary: [String] = []
        var ask = ""
        for line in content.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix(recapAskMarker) {
                ask = String(trimmed.dropFirst(recapAskMarker.count)).trimmingCharacters(in: .whitespaces)
            } else if !trimmed.isEmpty {
                summary.append(trimmed)
            }
        }
        return (summary.joined(separator: " "), ask)
    }

    /// ISO-week key ("2026-W39") used for staleness and card dismissal.
    nonisolated static func weekKey(for date: Date) -> String {
        let cal = MemoryTimelineModel.calendar
        let parts = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return "\(parts.yearForWeekOfYear ?? 0)-W\(parts.weekOfYear ?? 0)"
    }

    /// The recap is due when the ISO week changed since the last refresh,
    /// or when it is stale like any other model.
    nonisolated static func isRecapDue(_ model: MentalModel, latestMemoryID: Int64, now: Date = Date()) -> Bool {
        guard let refreshed = model.lastRefreshed else { return true }
        if weekKey(for: refreshed) != weekKey(for: now) { return true }
        return model.isStale && latestMemoryID > model.lastMemoryID
    }

    /// Evidence for the recap: units dated or mentioned in the last 7 days
    /// (observations preferred over the facts they cover) plus the week's
    /// diary entries. Nil when the week holds nothing.
    func weeklyEvidence(character: String, now: Date = Date()) -> String? {
        let start = now.addingTimeInterval(-Self.recapWindow)
        let units = MemoryStore.shared.fetchUnits(occurringBetween: start, and: now, includeUndated: true)
            .filter { $0.factType != .raw }
        let covered = Set(units.filter { $0.factType == .observation }.flatMap(\.sourceIDs))
        let hits = units
            .filter { $0.factType == .observation || !covered.contains($0.id) }
            .prefix(16)
            .map { MemoryRecallHit(unit: $0, score: 0, arms: []) }
        var lines = MemoryRecall.bulletLines(Array(hits))
        let diaries = MemoryStore.shared.journalEntries(character: character, limit: 10)
            .filter { $0.createdAt >= start }
            .map { "- Diary: \($0.diary)" }
        lines.append(contentsOf: diaries.prefix(5))
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Prompt block line for the recap (compact).
    nonisolated static func recapPromptLine(_ content: String) -> String {
        let summary = recapParts(content).summary
        return summary.isEmpty ? "" : String(summary.prefix(240))
    }

    // MARK: - Ask about it

    /// Delivers the recap's follow-up: into the live session when one is
    /// running, otherwise as the next session's opener.
    func askAboutRecap(character: String) {
        guard let model = MemoryStore.shared.fetchMentalModel(character: character, slug: Self.weeklyRecapSlug) else { return }
        let ask = Self.recapParts(model.content).ask
        guard !ask.isEmpty else { return }
        let event = "[The user tapped “Ask about it” on your weekly recap. Bring this up now, in your own words: \(ask)]"
        let live: Bool
        switch RealtimeChatState.shared.status {
        case .ready, .listening, .thinking, .speaking: live = true
        default: live = false
        }
        if live, ProactivePresenceManager.shared.engage(with: event) { return }
        _ = MemoryStore.shared.insertJournalEntry(
            character: character, conversationID: 0, diary: "Weekly recap follow-up", opener: ask, notificationLine: "")
        nlLog("[Recap] follow-up stored as next opener", level: .info)
    }
}
