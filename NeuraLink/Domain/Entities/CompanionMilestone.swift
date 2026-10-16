//
//  CompanionMilestone.swift
//  NeuraLink
//
//  Keepsake milestones — Living Companion (docs/LIVING_COMPANION.md).
//  Small shared "firsts" the companion and the user collect together: the
//  first hello, a week / a month / a hundred days of talking, the first
//  shared song, game, photo and diary entry. Framework-free so the rules
//  stay unit-testable; rows live in `companion_milestones`.
//
//  Created by Dedicatus on 12/10/2026.
//

import Foundation

/// Every keepsake the journal can show. Raw values are the stored keys —
/// never rename one without a migration.
enum MilestoneKind: String, CaseIterable, Sendable {
    case firstConversation = "first_conversation"
    case sevenDays = "days_together_7"
    case thirtyDays = "days_together_30"
    case hundredDays = "days_together_100"
    case firstSharedSong = "first_shared_song"
    case firstGame = "first_game"
    case firstPhoto = "first_photo"
    case firstDiary = "first_diary"

    /// Badge title; also what the persona is told to celebrate.
    var title: String {
        switch self {
        case .firstConversation: return "First hello"
        case .sevenDays: return "One week together"
        case .thirtyDays: return "30 days together"
        case .hundredDays: return "100 days together"
        case .firstSharedSong: return "First shared song"
        case .firstGame: return "First game together"
        case .firstPhoto: return "First photo shared"
        case .firstDiary: return "First diary entry"
        }
    }

    /// One line under the badge.
    var detail: String {
        switch self {
        case .firstConversation: return "The day you first spoke."
        case .sevenDays: return "Seven different days of talking."
        case .thirtyDays: return "A month of showing up for each other."
        case .hundredDays: return "A hundred days — this is a habit now."
        case .firstSharedSong: return "The first song you identified together."
        case .firstGame: return "Your first mini-game."
        case .firstPhoto: return "The first picture you showed them."
        case .firstDiary: return "The first time they wrote about you."
        }
    }

    /// SF Symbol for the badge.
    var symbol: String {
        switch self {
        case .firstConversation: return "hand.wave.fill"
        case .sevenDays: return "7.circle.fill"
        case .thirtyDays: return "calendar.badge.checkmark"
        case .hundredDays: return "sparkles"
        case .firstSharedSong: return "music.note"
        case .firstGame: return "gamecontroller.fill"
        case .firstPhoto: return "photo.on.rectangle"
        case .firstDiary: return "book.closed.fill"
        }
    }

    /// Distinct days the user must have spoken on; nil for event milestones.
    var daysRequired: Int? {
        switch self {
        case .sevenDays: return 7
        case .thirtyDays: return 30
        case .hundredDays: return 100
        default: return nil
        }
    }
}

/// One collected keepsake for one character.
struct CompanionMilestone: Identifiable, Equatable, Sendable {
    let kind: MilestoneKind
    let character: String
    let achievedAt: Date
    /// When the persona first brought it up; nil until then.
    let celebratedAt: Date?

    var id: String { kind.rawValue }
    var celebrated: Bool { celebratedAt != nil }
}

/// Pure rules (unit-tested): which count-based milestones hold, and the
/// prompt line for fresh, not-yet-celebrated ones.
enum MilestoneRules {

    /// A milestone older than this is history, not news — the persona
    /// should not congratulate the user on something from last month.
    static let celebrationWindow: TimeInterval = 7 * 86_400

    /// Once shown, the line stays in the prompt this long so the
    /// `[Companion State]` block is stable across a session: the local
    /// path rebuilds it every turn and reuses the KV prefix, and Realtime
    /// re-sends instructions mid-session.
    static let celebrationHold: TimeInterval = 2 * 3_600

    /// Count-based milestones satisfied by the given totals, in unlock order.
    static func derivedKinds(userTurns: Int, sharedDays: Int) -> [MilestoneKind] {
        var kinds: [MilestoneKind] = []
        if userTurns > 0 { kinds.append(.firstConversation) }
        for kind in MilestoneKind.allCases {
            if let required = kind.daysRequired, sharedDays >= required { kinds.append(kind) }
        }
        return kinds
    }

    /// Milestones worth bringing up now: reached recently, and either never
    /// mentioned or first mentioned within the hold.
    static func pending(in milestones: [CompanionMilestone], now: Date = Date()) -> [CompanionMilestone] {
        milestones.filter { milestone in
            guard now.timeIntervalSince(milestone.achievedAt) < celebrationWindow else { return false }
            guard let shown = milestone.celebratedAt else { return true }
            return now.timeIntervalSince(shown) < celebrationHold
        }
    }

    /// The `[Companion State]` line for `pending` milestones; nil when none.
    static func celebrationLine(for milestones: [CompanionMilestone], now: Date = Date()) -> String? {
        let fresh = pending(in: milestones, now: now)
        guard !fresh.isEmpty else { return nil }
        let titles = fresh.map(\.kind.title).joined(separator: "; ")
        return "Keepsake to celebrate together, once and naturally: \(titles). "
            + "Bring it up warmly in your own words — no ceremony, no statistics."
    }
}
