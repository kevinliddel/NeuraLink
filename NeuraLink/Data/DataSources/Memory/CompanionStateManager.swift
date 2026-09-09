//
//  CompanionStateManager.swift
//  NeuraLink
//
//  Derives a lightweight "relationship meter" state from facts + recent interactions.
//  Injected into prompts for more consistent personality over time.
//

import Foundation

final class CompanionStateManager {
    static let shared = CompanionStateManager()

    private let store = MemoryStore.shared
    private let memorySettings = MemorySettings.shared

    private init() {}

    /// The single prompt hook shared by both engines (local buildSystemContent
    /// + OpenAI session instructions). `compact` trims the block for the
    /// 1B-model tier, where every system token eats attention budget.
    func promptContext(characterName: String, compact: Bool = false) -> String {
        // Facts can exist even if memory is disabled; dialogue-derived familiarity needs memory.
        let facts = store.fetchAllFacts()
        let events = memorySettings.isEnabled ? store.fetchRecentMessagesAcrossAll(limit: 120) : []

        let preferenceLines = Self.preferenceSummary(from: facts)
        // Same curve as the UI meter (CompanionAffinity) — Phase 2 unification.
        let affinity = CompanionAffinity.compute(store: store)
        let familiarity = affinity.userTurns > 0
            ? "\(affinity.label) (≈\(affinity.userTurns) turns)" : nil
        let tone = Self.recentTone(from: events)
        let traits = store.traits(character: characterName, limit: compact ? 2 : 3)
        let carryOver = carryOverLine(characterName: characterName)

        // If nothing meaningful is known, don't inject noise.
        if preferenceLines.isEmpty && familiarity == nil && tone == nil
            && traits.isEmpty && carryOver == nil {
            return ""
        }

        var out = "\n[Companion State]\n"
        out += "- Character: \(characterName)\n"
        if let familiarity { out += "- Familiarity: \(familiarity)\n" }
        if let tone { out += "- Recent tone: \(tone)\n" }
        if !preferenceLines.isEmpty {
            out += "- Known preferences:\n"
            for line in preferenceLines.prefix(compact ? 3 : 6) {
                out += "  - \(line)\n"
            }
        }
        if !traits.isEmpty {
            out += "- Personality you've grown with this user:\n"
            for trait in traits {
                out += "  - \(trait.trait)\n"
            }
        }
        if let carryOver { out += "- \(carryOver)\n" }
        out += """
        - Behavior guidance: Keep personality consistent across turns. Use known preferences naturally when relevant. \
        Pick up threads from your last conversation naturally when relevant — never act like a stranger. \
        Avoid mentioning that you have a "relationship meter" or internal state.
        [End Companion State]\n
        """
        return out
    }

    // MARK: - Cross-session carry-over (Phase 6 ②)

    /// What carries over from last time: the reflection diary when one exists
    /// (< 7 days — the rich, in-voice memory), else the closing exchange of
    /// the most recent past conversation (< 48 h) so a new session never
    /// starts cold even with Companion Presence disabled.
    private func carryOverLine(characterName: String) -> String? {
        if let entry = store.latestJournalEntry(character: characterName),
            Date().timeIntervalSince(entry.createdAt) < 7 * 86_400,
            !entry.diary.isEmpty {
            return Self.carryOverText(
                diary: String(entry.diary.prefix(200)), closingRole: nil, closingContent: nil)
        }

        let active = ConversationStore.shared.activeConversationID
        guard
            let previous = store.fetchConversations(matching: "").first(where: { $0.id != active }),
            Date().timeIntervalSince(previous.updatedAt) < 48 * 3600,
            let closing = store.fetchMessages(conversationID: previous.id)
                .last(where: { $0.kind == "message" && !$0.content.isEmpty })
        else { return nil }
        return Self.carryOverText(
            diary: nil, closingRole: closing.role, closingContent: closing.content)
    }

    /// Pure formatter (unit-tested): diary wins; otherwise quote the closing
    /// line of the previous conversation, attributed to whoever said it.
    static func carryOverText(diary: String?, closingRole: String?, closingContent: String?) -> String? {
        if let diary, !diary.isEmpty {
            return "Last session, you privately noted: \(diary)"
        }
        guard let closingContent, !closingContent.isEmpty else { return nil }
        let quoted = String(closingContent.prefix(140))
        let who = closingRole == "user" ? "the user saying" : "you saying"
        return "Your previous conversation ended with \(who): \"\(quoted)\""
    }

    private static func preferenceSummary(from facts: [FactItem]) -> [String] {
        // Keep it simple: focus on the most common preference predicates.
        let preferencePredicates = Set([
            "likes", "dislikes", "loves", "hates", "prefers", "favorite", "favourite"
        ])

        var lines: [String] = []
        for f in facts {
            let p = f.predicate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard preferencePredicates.contains(p) else { continue }
            let subject = f.subject.isEmpty ? "User" : f.subject
            lines.append("\(subject) \(f.predicate) \(f.object)")
        }

        // De-dupe while preserving order.
        var seen = Set<String>()
        return lines.filter { seen.insert($0.lowercased()).inserted }
    }

    private static func recentTone(from events: [ConversationMessage]) -> String? {
        let recentUser = events
            .filter { $0.role == "user" && $0.kind == "message" }
            .prefix(6)
        guard !recentUser.isEmpty else { return nil }

        // Tiny heuristic — good enough to steer warmth, not for "sentiment analysis".
        let positive = ["thanks", "thank you", "love", "great", "awesome", "good", "nice", "amazing"]
        let negative = ["hate", "annoy", "angry", "mad", "upset", "sad", "terrible", "bad"]

        var score = 0
        for e in recentUser {
            let t = e.content.lowercased()
            if positive.contains(where: { t.contains($0) }) { score += 1 }
            if negative.contains(where: { t.contains($0) }) { score -= 1 }
        }

        if score >= 2 { return "Positive" }
        if score <= -2 { return "Negative" }
        return "Neutral"
    }
}
