//
//  MemoryMentalModels+WeeklyRecap.swift
//  NeuraLink
//
//  The weekly recap standing question (docs/MEMORY_OWNERSHIP.md): a
//  per-character summary of the week — Monday to now — built from dated
//  facts, observations and journal entries. It is a weekend thing: written
//  on Saturday/Sunday (refreshed there as new memories arrive), and only
//  shown — card, prompt line — on that weekend, as the week's wrap-up.
//
//  Created by Dedicatus on 27/09/2026.
//

import Foundation

extension MemoryMentalModels {

    static let weeklyRecapSlug = "weekly_recap"
    nonisolated static let recapAskMarker = "ASK:"

    static func weeklyRecapQuestion(character: String) -> String {
        "Summarise this week (Monday until today) with the user as \(RealtimeChatState.displayName(for: character)): what you talked about, what changed in their life, "
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

    /// Saturday or Sunday, local time.
    nonisolated static func isWeekend(_ date: Date) -> Bool {
        MemoryTimelineModel.calendar.isDateInWeekend(date)
    }

    /// Monday 00:00 of `date`'s ISO week.
    nonisolated static func weekStart(for date: Date) -> Date {
        MemoryTimelineModel.calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }

    /// Only on a weekend: due when this week has no recap yet, or when it is
    /// stale with memories newer than the last one written.
    nonisolated static func isRecapDue(_ model: MentalModel, latestMemoryID: Int64, now: Date = Date()) -> Bool {
        guard isWeekend(now) else { return false }
        guard let refreshed = model.lastRefreshed else { return true }
        if weekKey(for: refreshed) != weekKey(for: now) { return true }
        return model.isStale && latestMemoryID > model.lastMemoryID
    }

    /// Shown (Memory page card, prompt line) only on the weekend it was
    /// written for — never last week's on a Tuesday.
    nonisolated static func isRecapVisible(_ model: MentalModel, now: Date = Date()) -> Bool {
        guard !model.content.isEmpty, isWeekend(now), let refreshed = model.lastRefreshed else { return false }
        return weekKey(for: refreshed) == weekKey(for: now)
    }

    /// Evidence for the recap: units dated or mentioned since Monday
    /// (observations preferred over the facts they cover) plus the week's
    /// diary entries. Nil when the week holds nothing.
    func weeklyEvidence(character: String, now: Date = Date()) -> String? {
        let start = Self.weekStart(for: now)
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
