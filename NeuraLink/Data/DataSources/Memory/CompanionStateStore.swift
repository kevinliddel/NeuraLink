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
        // Single source of truth for the curve — shared with the prompt
        // block (CompanionStateManager) so the meter and the model never
        // disagree about the relationship stage.
        let state = CompanionAffinity.compute(store: store)
        score = state.score
        label = state.label
    }
}
