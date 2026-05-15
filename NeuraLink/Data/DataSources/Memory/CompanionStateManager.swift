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

    func promptContext(characterName: String) -> String {
        // Facts can exist even if memory is disabled; timeline-derived familiarity needs memory.
        let facts = store.fetchAllFacts()
        let events = memorySettings.isEnabled ? store.fetchChatEvents(limit: 120) : []

        let preferenceLines = Self.preferenceSummary(from: facts)
        let familiarity = Self.familiarityLabel(from: events)
        let tone = Self.recentTone(from: events)

        // If nothing meaningful is known, don't inject noise.
        if preferenceLines.isEmpty && familiarity == nil && tone == nil { return "" }

        var out = "\n[Companion State]\n"
        out += "- Character: \(characterName)\n"
        if let familiarity { out += "- Familiarity: \(familiarity)\n" }
        if let tone { out += "- Recent tone: \(tone)\n" }
        if !preferenceLines.isEmpty {
            out += "- Known preferences:\n"
            for line in preferenceLines.prefix(6) {
                out += "  - \(line)\n"
            }
        }
        out += """
        - Behavior guidance: Keep personality consistent across turns. Use known preferences naturally when relevant. \
        Avoid mentioning that you have a "relationship meter" or internal state.
        [End Companion State]\n
        """
        return out
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

    private static func familiarityLabel(from events: [ChatEventItem]) -> String? {
        let userTurns = events.filter { $0.role == "user" && $0.kind == "message" }.count
        guard userTurns > 0 else { return nil }

        // Very lightweight curve: first 5 turns -> new, 5–25 -> friendly, 25+ -> close.
        if userTurns < 5 { return "New (≈\(userTurns) turns)" }
        if userTurns < 25 { return "Friendly (≈\(userTurns) turns)" }
        return "Close (≈\(userTurns) turns)"
    }

    private static func recentTone(from events: [ChatEventItem]) -> String? {
        let recentUser = events
            .filter { $0.role == "user" && $0.kind == "message" }
            .prefix(6)
        guard !recentUser.isEmpty else { return nil }

        // Tiny heuristic — good enough to steer warmth, not for "sentiment analysis".
        let positive = ["thanks", "thank you", "love", "great", "awesome", "good", "nice", "amazing"]
        let negative = ["hate", "annoy", "angry", "mad", "upset", "sad", "terrible", "bad"]

        var score = 0
        for e in recentUser {
            let t = e.detail.lowercased()
            if positive.contains(where: { t.contains($0) }) { score += 1 }
            if negative.contains(where: { t.contains($0) }) { score -= 1 }
        }

        if score >= 2 { return "Positive" }
        if score <= -2 { return "Negative" }
        return "Neutral"
    }
}
