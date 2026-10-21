//
//  CompanionAbsence.swift
//  NeuraLink
//
//  How long the user has been away, worded for the `[Companion State]`
//  block — Living Companion (docs/LIVING_COMPANION.md). Pure and
//  unit-tested; `CompanionStateManager` freezes the inputs per foreground
//  visit so the block reads the same on every turn of a session.
//
//  Created by Dedicatus on 13/10/2026.
//

import Foundation

enum CompanionAbsence {

    /// Gaps shorter than this are not worth a line.
    static let minimumGap: TimeInterval = 3_600

    /// "yesterday (Sunday evening)", "3 days ago (Friday evening)",
    /// "about a week ago (Monday morning)", "3 weeks ago", "about a month
    /// ago", "about 3 months ago"; nil under `minimumGap`.
    static func describe(lastTalkedAt: Date, now: Date, calendar: Calendar) -> String? {
        let gap = now.timeIntervalSince(lastTalkedAt)
        guard gap >= minimumGap else { return nil }
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: lastTalkedAt), to: calendar.startOfDay(for: now)
        ).day ?? 0
        let when = "\(weekday(of: lastTalkedAt, calendar: calendar)) \(timeOfDay(of: lastTalkedAt, calendar: calendar))"
        switch days {
        case 0:
            let hours = Int(gap / 3_600)
            return hours == 1 ? "earlier today, about an hour ago" : "earlier today, about \(hours) hours ago"
        case 1: return "yesterday (\(when))"
        case 2...6: return "\(days) days ago (\(when))"
        case 7...13: return "about a week ago (\(when))"
        case 14...29: return "\(days / 7) weeks ago"
        case 30...59: return "about a month ago"
        default: return "about \(days / 30) months ago"
        }
    }

    /// The full prompt line, or nil when the gap is too short to matter.
    static func line(lastTalkedAt: Date, now: Date, calendar: Calendar, compact: Bool = false) -> String? {
        guard let gap = describe(lastTalkedAt: lastTalkedAt, now: now, calendar: calendar) else { return nil }
        let present = "\(weekday(of: now, calendar: calendar)) \(timeOfDay(of: now, calendar: calendar))"
        if compact { return "Time apart: last talked \(gap); now \(present)." }
        return "Time apart: you last talked \(gap); it's \(present) now. If the gap feels notable, "
            + "acknowledge it naturally — glad to see them, curious what they've been up to — "
            + "without guilt-tripping or counting days at them."
    }

    static func weekday(of date: Date, calendar: Calendar) -> String {
        let index = calendar.component(.weekday, from: date) - 1
        let symbols = calendar.weekdaySymbols
        return symbols.indices.contains(index) ? symbols[index] : ""
    }

    static func timeOfDay(of date: Date, calendar: Calendar) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<9: return "early morning"
        case 9..<12: return "morning"
        case 12..<17: return "afternoon"
        case 17..<22: return "evening"
        default: return "late night"
        }
    }
}
