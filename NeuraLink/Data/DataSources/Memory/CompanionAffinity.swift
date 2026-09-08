//
//  CompanionAffinity.swift
//  NeuraLink
//
//  The ONE relationship curve — Living Companion Phase 2
//  (docs/LIVING_COMPANION_PLAN.md §⑤). Before this, the UI meter
//  (CompanionStateStore: turns/40 curve) and the prompt block
//  (CompanionStateManager: <5/<25 turn bands) computed familiarity
//  independently and could disagree. Both now derive from here.
//
//  Created by Dedicatus on 08/09/2026.
//

import Foundation

enum CompanionAffinity {

    struct State: Equatable {
        let score: Double  // 0...1
        let label: String
        let userTurns: Int
    }

    /// Cross-session familiarity from total user turns + stored facts.
    static func compute(store: MemoryStore = .shared) -> State {
        let userTurns = store.countMessages(role: "user", kind: "message")
        let factCount = store.fetchAllFacts().count
        let score = score(turns: userTurns, factCount: factCount)
        return State(score: score, label: label(forScore: score, turns: userTurns), userTurns: userTurns)
    }

    // MARK: - Pure curve (unit-tested)

    /// Turns saturate quickly (40 → full 0.7 component); facts add a small
    /// bonus (25 → full 0.25). Ceiling is 0.95 by design — "perfect" is
    /// never reached.
    static func score(turns: Int, factCount: Int) -> Double {
        let turnsComponent = min(1.0, Double(turns) / 40.0)
        let factsComponent = min(1.0, Double(factCount) / 25.0) * 0.25
        return min(max(turnsComponent * 0.7 + factsComponent, 0.0), 1.0)
    }

    static func label(forScore score: Double, turns: Int) -> String {
        if turns < 3 { return "New" }
        switch score {
        case ..<0.33: return "Acquaintances"
        case ..<0.66: return "Friends"
        default: return "Close"
        }
    }
}
