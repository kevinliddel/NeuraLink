//
//  CompanionStateStore.swift
//  NeuraLink
//
//  Observable relationship meter state for UI.
//

import Foundation
import Observation

@Observable
final class CompanionStateStore {
    static let shared = CompanionStateStore()

    var score: Double = 0.0  // 0...1
    var label: String = "New"

    private let store = MemoryStore.shared

    private init() {
        refresh()
    }

    func refresh() {
        let events = store.fetchChatEvents(limit: 500)
        let facts = store.fetchAllFacts()

        let userTurns = events.filter { $0.role == "user" && $0.kind == "message" }.count
        let pinned = events.filter { $0.pinned }.count

        // Simple bounded model:
        // - userTurns increases familiarity quickly at first, then saturates
        // - facts add a small bonus
        // - pinned events add a small bonus (user-curated importance)
        let turnsComponent = min(1.0, Double(userTurns) / 40.0)
        let factsComponent = min(1.0, Double(facts.count) / 25.0) * 0.25
        let pinnedComponent = min(1.0, Double(pinned) / 10.0) * 0.15

        let raw = turnsComponent * 0.6 + factsComponent + pinnedComponent
        score = min(max(raw, 0.0), 1.0)
        label = Self.labelForScore(score, turns: userTurns)
    }

    private static func labelForScore(_ score: Double, turns: Int) -> String {
        if turns < 3 { return "New" }
        switch score {
        case ..<0.33: return "Acquaintances"
        case ..<0.66: return "Friends"
        default: return "Close"
        }
    }
}
