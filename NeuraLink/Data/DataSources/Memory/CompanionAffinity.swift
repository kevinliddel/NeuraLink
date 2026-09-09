//
//  CompanionAffinity.swift
//  NeuraLink
//
//  The ONE relationship curve, shared by the UI meter (CompanionStateStore)
//  and the prompt block (CompanionStateManager).
//
//  v2 (2026-09-09): rebuilt to feel like a connection between two people
//  rather than an XP bar. The old model saturated at 40 user turns — one
//  chatty evening. Now:
//    • shared DAYS dominate (45%) — you can't grind a friendship overnight,
//    • depth (35%) — facts learned + sessions meaningful enough to reflect on,
//    • volume (20%) — matters least, saturates slowest (150 turns),
//    • absence cools the bond gently (never below 0.65× — an old friend
//      cools, but never resets to a stranger),
//    • ceiling stays 0.95 — "perfect" is never reached.
//
//  Each stage also carries behavior guidance so the persona ACTS the stage:
//  reserved when new, warm as friends, at ease when close.
//

import Foundation

enum CompanionAffinity {

    struct State: Equatable {
        let score: Double  // 0...1
        let label: String
        let userTurns: Int
    }

    /// Everything the curve looks at — gathered by `compute`, pure in `score`.
    struct Inputs: Equatable {
        var turns: Int
        var factCount: Int
        var sharedDays: Int
        var reflectionCount: Int
        /// Days since the user last spoke; nil before the first ever turn.
        var daysSinceLastSeen: Double?
    }

    // Saturation points, tuned so "Close" takes weeks of genuine contact.
    static let daysToSaturate = 30.0
    static let factsToSaturate = 20.0
    static let reflectionsToSaturate = 12.0
    static let turnsToSaturate = 150.0

    static func compute(store: MemoryStore = .shared) -> State {
        let turns = store.countMessages(role: "user", kind: "message")
        let inputs = Inputs(
            turns: turns,
            factCount: store.fetchAllFacts().count,
            sharedDays: store.distinctUserMessageDays(),
            reflectionCount: store.journalEntryCount(),
            daysSinceLastSeen: store.lastUserMessageAt()
                .map { Date().timeIntervalSince($0) / 86_400.0 }
        )
        let score = score(inputs)
        return State(score: score, label: label(forScore: score, turns: turns), userTurns: turns)
    }

    // MARK: - Pure curve (unit-tested)

    static func score(_ inputs: Inputs) -> Double {
        guard inputs.turns > 0 else { return 0 }

        let days = min(1.0, Double(inputs.sharedDays) / daysToSaturate) * 0.45
        let depth = (min(1.0, Double(inputs.factCount) / factsToSaturate) * 0.5
            + min(1.0, Double(inputs.reflectionCount) / reflectionsToSaturate) * 0.5) * 0.35
        let volume = min(1.0, Double(inputs.turns) / turnsToSaturate) * 0.20

        let raw = (days + depth + volume) * recencyFactor(daysSince: inputs.daysSinceLastSeen)
        return min(max(raw, 0.0), 0.95)
    }

    /// Absence cooling: full strength up to 3 days apart, then a gentle
    /// linear fade to a 0.65 floor at 45 days. An old friend cools —
    /// never resets to a stranger.
    static func recencyFactor(daysSince: Double?) -> Double {
        guard let days = daysSince, days > 3 else { return 1.0 }
        if days >= 45 { return 0.65 }
        return 1.0 - 0.35 * (days - 3) / 42.0
    }

    /// Five stages so the journey stays visible even though it's slower now.
    static func label(forScore score: Double, turns: Int) -> String {
        if turns < 3 { return "New" }
        switch score {
        case ..<0.25: return "Acquaintances"
        case ..<0.50: return "Friends"
        case ..<0.75: return "Good Friends"
        default: return "Close"
        }
    }

    // MARK: - Stage personality (injected into the prompt)

    /// How the persona should BEHAVE at each stage — this is what makes the
    /// meter feel real: the character earns familiarity instead of acting
    /// like a lifelong friend in the first minute.
    static func stageGuidance(for label: String) -> String {
        switch label {
        case "New":
            return "You've only just met. Be polite, a little reserved, and genuinely curious — "
                + "no pet names, no assumed familiarity. Earn their trust by listening."
        case "Acquaintances":
            return "You're still getting to know each other. Friendly but keep a respectful "
                + "distance; show real interest, remember what they share, no teasing yet."
        case "Friends":
            return "You're friends now. Relaxed and warm; callbacks to shared moments are "
                + "welcome and gentle teasing is fine."
        case "Good Friends":
            return "You know each other well. Comfortable, playful and honest — you can "
                + "reference your shared history freely and call them out kindly."
        case "Close":
            return "You're genuinely close. Deep familiarity: affectionate, at ease, honest "
                + "with your opinions, and you care about the small details of their life."
        default:
            return "Match your warmth to how well you actually know each other."
        }
    }
}
