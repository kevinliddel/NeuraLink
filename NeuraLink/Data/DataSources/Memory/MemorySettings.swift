//
//  MemorySettings.swift
//  NeuraLink
//
//  User controls for long-term memory storage (RAG + chat timeline).
//

import Foundation
import Observation

@Observable
final class MemorySettings {
    static let shared = MemorySettings()

    private enum Key {
        static let isEnabled = "com.neuralink.memory.enabled"
        static let autoForgetDays = "com.neuralink.memory.autoforget_days"
        static let similarityFloor = "com.neuralink.memory.similarity_floor"
        static let recencyHalfLifeDays = "com.neuralink.memory.recency_halflife_days"
        static let recencyWeight = "com.neuralink.memory.recency_weight"
    }

    /// Defaults for the RAG scoring tunables — these reproduce the values
    /// that were hard-coded in `RAGManager.rankedMemories` before they were
    /// made user-tunable.
    static let defaultSimilarityFloor = 0.5
    static let defaultRecencyHalfLifeDays = 14.0
    static let defaultRecencyWeight = 0.25

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Key.isEnabled) }
    }

    /// 0 disables auto-forget. Otherwise prune items older than N days (pinned items are kept).
    var autoForgetDays: Int {
        didSet { UserDefaults.standard.set(autoForgetDays, forKey: Key.autoForgetDays) }
    }

    // MARK: - Retrieval tuning (RAG scoring)
    //
    // score = sim × ((1 − recencyWeight) + recencyWeight × exp(−ageDays / recencyHalfLifeDays))
    //             × (pinned ? 1.15 : 1.0),  candidates with sim ≤ similarityFloor are dropped

    /// Candidates with cosine similarity at or below this floor are dropped
    /// before ranking. Higher = stricter retrieval — surfaced as the
    /// "Memory Quality" slider in settings.
    var similarityFloor: Double {
        didSet { UserDefaults.standard.set(similarityFloor, forKey: Key.similarityFloor) }
    }

    /// Half-life, in days, of the exponential recency boost.
    var recencyHalfLifeDays: Double {
        didSet { UserDefaults.standard.set(recencyHalfLifeDays, forKey: Key.recencyHalfLifeDays) }
    }

    /// Share of the score driven by recency (0 = pure similarity ranking).
    var recencyWeight: Double {
        didSet { UserDefaults.standard.set(recencyWeight, forKey: Key.recencyWeight) }
    }

    private init() {
        if UserDefaults.standard.object(forKey: Key.isEnabled) == nil {
            isEnabled = true
        } else {
            isEnabled = UserDefaults.standard.bool(forKey: Key.isEnabled)
        }

        autoForgetDays = UserDefaults.standard.integer(forKey: Key.autoForgetDays)

        if UserDefaults.standard.object(forKey: Key.similarityFloor) == nil {
            similarityFloor = Self.defaultSimilarityFloor
        } else {
            similarityFloor = UserDefaults.standard.double(forKey: Key.similarityFloor)
        }

        if UserDefaults.standard.object(forKey: Key.recencyHalfLifeDays) == nil {
            recencyHalfLifeDays = Self.defaultRecencyHalfLifeDays
        } else {
            recencyHalfLifeDays = UserDefaults.standard.double(forKey: Key.recencyHalfLifeDays)
        }

        if UserDefaults.standard.object(forKey: Key.recencyWeight) == nil {
            recencyWeight = Self.defaultRecencyWeight
        } else {
            recencyWeight = UserDefaults.standard.double(forKey: Key.recencyWeight)
        }
    }
}
