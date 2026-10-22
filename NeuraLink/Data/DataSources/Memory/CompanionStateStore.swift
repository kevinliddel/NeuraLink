//
//  CompanionStateStore.swift
//  NeuraLink
//
//  Observable relationship meter state for UI: the bond with the character
//  on screen. Refreshed after every turn and on a character switch.
//

import Foundation
import Observation

@Observable
final class CompanionStateStore {
    static let shared = CompanionStateStore()

    var score: Double = 0.0  // 0...1
    var label: String = "New"
    /// Whose bond `score` and `label` describe (identity key).
    private(set) var character: String = ""

    private let store = MemoryStore.shared

    private init() {
        refresh()
    }

    func refresh() {
        // Single source of truth for the curve — shared with the prompt
        // block (CompanionStateManager) so the meter and the model never
        // disagree about the relationship stage.
        let key = RealtimeChatState.shared.selectedCharacterName
        let state = CompanionAffinity.compute(store: store, character: key)
        character = key
        score = state.score
        label = state.label
        // Count-based keepsakes (first hello, shared days) read the same
        // totals, so they unlock the moment the meter would move.
        CompanionMilestoneTracker.refreshDerived()
        CompanionSnapshotWriter.shared.scheduleRefresh()
    }
}
