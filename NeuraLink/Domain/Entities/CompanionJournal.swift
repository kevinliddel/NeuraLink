//
//  CompanionJournal.swift
//  NeuraLink
//
//  Domain entities for the companion's between-session life — Living
//  Companion Phase 0 (docs/LIVING_COMPANION_PLAN.md §0.3). Rows are written
//  by the end-of-session reflection (Phase 1) and read by the proactive
//  greeting (Phase 3), the prompt block (Phase 2), and the Journal UI.
//
//  Created by Dedicatus on 07/09/2026.
//

import Foundation

/// One reflection over one conversation: what the companion "thought" about
/// it, how it wants to open next time, and the push-notification line.
struct JournalEntry: Identifiable, Equatable {
    let id: Int64
    let character: String
    let conversationID: Int64
    let diary: String
    let opener: String
    let notificationLine: String
    let notified: Bool
    let openerUsed: Bool
    let createdAt: Date
}

/// A distilled personality trait the companion has picked up ("teases the
/// user about coffee"). Capped per character; weight decays when unused.
struct PersonaTrait: Identifiable, Equatable {
    let id: Int64
    let character: String
    let trait: String
    let weight: Double
    let createdAt: Date
    let updatedAt: Date
}
