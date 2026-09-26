//
//  FollowUpPlanner.swift
//  NeuraLink
//
//  Character-initiated follow-ups from future-dated facts. 
//  The pure planner turns dated user facts into `FollowUp` values (today / upcoming / afterwards); 
//  the coordinator words them, schedules the notification, and queues the in-conversation mention.
//
//  Created by Dedicatus on 27/09/2026.
//

import Foundation

nonisolated struct FollowUp: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable { case today, upcoming, afterwards }

    let unitID: Int64
    let kind: Kind
    let factText: String
    /// Event start (upcoming/today) or end (afterwards).
    let date: Date

    var id: String { "\(unitID):\(kind.rawValue)" }
}

nonisolated enum FollowUpPlanner {
    /// Facts spanning more than this never fire ("in September" is not a plan).
    static let maxSpan: TimeInterval = 3 * 86_400
    static let upcomingDays = 1...3
    static let afterwardsDays = 1...2

    private static var calendar: Calendar { MemoryTimelineModel.calendar }

    /// Planned follow-ups for `units` (dated world facts about the user),
    /// skipping fired pairs and muted units, most imminent first.
    static func plan(units: [MemoryUnit], fired: Set<String>, muted: Set<Int64>, now: Date = Date()) -> [FollowUp] {
        let today = calendar.startOfDay(for: now)
        var result: [FollowUp] = []
        for unit in units where unit.factType == .world && !muted.contains(unit.id) {
            guard let start = unit.occurredStart else { continue }
            let end = unit.occurredEnd ?? start
            guard end.timeIntervalSince(start) <= maxSpan else { continue }
            guard unit.entities.contains(where: { $0.lowercased() == "user" }) else { continue }

            let startDay = calendar.startOfDay(for: start)
            let endDay = calendar.startOfDay(for: end)
            let daysUntilStart = calendar.dateComponents([.day], from: today, to: startDay).day ?? 0
            let daysSinceEnd = calendar.dateComponents([.day], from: endDay, to: today).day ?? 0

            let kind: FollowUp.Kind?
            if startDay <= today, endDay >= today {
                kind = .today
            } else if upcomingDays.contains(daysUntilStart) {
                kind = .upcoming
            } else if afterwardsDays.contains(daysSinceEnd) {
                kind = .afterwards
            } else {
                kind = nil
            }
            guard let kind else { continue }
            let followUp = FollowUp(unitID: unit.id, kind: kind, factText: unit.text, date: kind == .afterwards ? end : start)
            if !fired.contains(followUp.id) { result.append(followUp) }
        }
        return result.sorted { abs($0.date.timeIntervalSince(now)) < abs($1.date.timeIntervalSince(now)) }
    }

    /// Notification fire time: 18:00 the day before an upcoming event,
    /// 19:00 the day after an event ended; nil for "today" (conversation only).
    static func notificationDate(for followUp: FollowUp, now: Date = Date()) -> Date? {
        switch followUp.kind {
        case .today:
            return nil
        case .upcoming:
            let dayBefore = calendar.date(byAdding: .day, value: -1, to: followUp.date) ?? followUp.date
            let at18 = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: dayBefore) ?? dayBefore
            return at18 > now ? at18 : nil
        case .afterwards:
            let dayAfter = calendar.date(byAdding: .day, value: 1, to: followUp.date) ?? followUp.date
            let at19 = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: dayAfter) ?? dayAfter
            return at19 > now ? at19 : nil
        }
    }
}

nonisolated enum FollowUpWording {
    /// Offline / no-LLM wording. `fact` is third person about the user.
    static func fallback(_ followUp: FollowUp) -> String {
        let fact = followUp.factText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch followUp.kind {
        case .today: return "Today's the day — \(fact)"
        case .upcoming: return "Coming up soon: \(fact)"
        case .afterwards: return "How did it go? \(fact)"
        }
    }

    static func prompt(_ followUp: FollowUp, character: String) -> (system: String, user: String) {
        let name = character.isEmpty ? "the user's AI companion" : character.capitalized
        let intent: String
        switch followUp.kind {
        case .today: intent = "it is happening today"
        case .upcoming: intent = "it is coming up in a day or two"
        case .afterwards: intent = "it just happened; ask how it went"
        }
        let system = "You are \(name). Write ONE short, warm spoken sentence to the user (second person) about the fact below, "
            + "given that \(intent). No preamble, no quotes, no emoji."
        return (system, "FACT: \(followUp.factText)")
    }
}

/// Runs the planner, words the results and delivers them.
final class FollowUpCoordinator {
    static let shared = FollowUpCoordinator()

    static let mentionLimit = 2
    static let maxTokens = 60
    private static let lastNotificationDayKey = "com.neuralink.presence.followUpNotificationDay"

    private let store: MemoryStore
    private let llm: MemoryLLM
    /// Wordings to bring up in the current/next session (≤ mentionLimit).
    private(set) var pendingMentions: [FollowUp] = []
    private var mentionTexts: [String: String] = [:]

    init(store: MemoryStore = .shared, llm: MemoryLLM = LiveMemoryLLM()) {
        self.store = store
        self.llm = llm
    }

    /// Prompt block for the session instructions / local Tier 3.
    func mentionBlock() -> String {
        let lines = pendingMentions.compactMap { mentionTexts[$0.id] }
        guard !lines.isEmpty else { return "" }
        return "\n[Things to bring up naturally, once]\n" + lines.map { "- \($0)" }.joined(separator: "\n") + "\n"
    }

    /// Upcoming items for the Memory page hero card.
    func upcoming(now: Date = Date()) -> [FollowUp] {
        FollowUpPlanner.plan(units: candidates(now: now), fired: [], muted: store.mutedFollowUpUnits(), now: now)
            .filter { $0.kind != .afterwards }
    }

    private func candidates(now: Date) -> [MemoryUnit] {
        store.fetchUnits(
            occurringBetween: now.addingTimeInterval(-3 * 86_400), and: now.addingTimeInterval(14 * 86_400),
            includeUndated: false)
    }

    /// Plans, words and delivers. Safe to call often; fired pairs never repeat.
    func planAndDeliver(now: Date = Date()) async {
        guard PresenceSettings.shared.followUpsEnabled, MemorySettings.shared.isEnabled else { return }
        let character = RealtimeChatState.shared.selectedCharacterName
        let planned = FollowUpPlanner.plan(
            units: candidates(now: now), fired: store.firedFollowUps(), muted: store.mutedFollowUpUnits(), now: now)
        guard !planned.isEmpty else { return }

        var notified = Self.notifiedToday(now: now)
        for followUp in planned {
            let text = await wording(for: followUp, character: character)
            // In-conversation mention (today and upcoming), capped.
            if followUp.kind != .afterwards || pendingMentions.isEmpty, pendingMentions.count < Self.mentionLimit {
                pendingMentions.append(followUp)
                mentionTexts[followUp.id] = text
            }
            // At most one notification per day.
            if !notified, PresenceSettings.shared.isNotificationsEnabled,
               let fireAt = FollowUpPlanner.notificationDate(for: followUp, now: now) {
                let scheduled = await CompanionNotificationScheduler.scheduleFollowUp(
                    characterName: character, body: text, unitID: followUp.unitID, fireAt: fireAt)
                if scheduled {
                    notified = true
                    Self.markNotified(now: now)
                }
            }
            store.recordFollowUp(unitID: followUp.unitID, kind: followUp.kind.rawValue)
        }
        if !pendingMentions.isEmpty {
            OpenAIRealtimeManager.postInstructionsChanged(reason: "follow-ups")
        }
        nlLog("[FollowUp] planned \(planned.count), pending mentions \(pendingMentions.count)", level: .info)
    }

    /// Clears mentions once a session has had the chance to use them.
    func consumeMentions() {
        pendingMentions.removeAll()
        mentionTexts.removeAll()
    }

    private func wording(for followUp: FollowUp, character: String) async -> String {
        guard llm.tier != .none else { return FollowUpWording.fallback(followUp) }
        let prompt = FollowUpWording.prompt(followUp, character: character)
        guard let raw = await llm.complete(system: prompt.system, user: prompt.user, maxTokens: Self.maxTokens) else {
            return FollowUpWording.fallback(followUp)
        }
        let line = raw.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\""))) ?? ""
        return (8...200).contains(line.count) ? line : FollowUpWording.fallback(followUp)
    }

    private static func notifiedToday(now: Date) -> Bool {
        UserDefaults.standard.string(forKey: lastNotificationDayKey) == dayKey(now)
    }

    private static func markNotified(now: Date) {
        UserDefaults.standard.set(dayKey(now), forKey: lastNotificationDayKey)
    }

    private static func dayKey(_ date: Date) -> String {
        let parts = MemoryTimelineModel.calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}
