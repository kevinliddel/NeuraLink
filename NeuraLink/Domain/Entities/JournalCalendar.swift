//
//  JournalCalendar.swift
//  NeuraLink
//
//  Pure month-grid math and per-day activity for the companion journal's
//  calendar — Living Companion (docs/LIVING_COMPANION.md). Day keys are
//  `calendar.startOfDay` values in the calendar's time zone, so a late-night
//  chat lands on the day the user experienced it, not the UTC day SQLite
//  stored. Framework-free and unit-tested.
//
//  Created by Dedicatus on 13/10/2026.
//

import Foundation

/// A user turn's instant and conversation (feeds the calendar's day counts).
struct UserTurnStamp: Equatable, Sendable {
    let conversationID: Int64
    let at: Date
}

/// Everything that happened on one local day, as the journal calendar shows it.
struct JournalDayActivity: Equatable, Sendable {
    var turnsByConversation: [Int64: Int] = [:]
    var diaryEntries: [JournalEntry] = []
    var keepsakes: [CompanionMilestone] = []

    var talked: Bool { !turnsByConversation.isEmpty }
    var isEmpty: Bool { !talked && diaryEntries.isEmpty && keepsakes.isEmpty }
}

enum JournalCalendarModel {

    struct Month: Hashable, Sendable {
        let year: Int
        let month: Int
    }

    struct Summary: Equatable, Sendable {
        let daysTalked: Int
        let diaryEntries: Int
        let keepsakes: Int
    }

    static let rowCount = 6
    static let columnCount = 7

    static func month(containing date: Date, calendar: Calendar) -> Month {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return Month(year: parts.year ?? 1, month: parts.month ?? 1)
    }

    static func start(of month: Month, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: month.year, month: month.month, day: 1)) ?? Date()
    }

    /// First instant of the following month (exclusive upper bound).
    static func end(of month: Month, calendar: Calendar) -> Date {
        calendar.date(byAdding: .month, value: 1, to: start(of: month, calendar: calendar)) ?? Date()
    }

    static func shifted(_ month: Month, by delta: Int, calendar: Calendar) -> Month {
        let date = calendar.date(byAdding: .month, value: delta, to: start(of: month, calendar: calendar)) ?? Date()
        return self.month(containing: date, calendar: calendar)
    }

    /// "October 2026" in the calendar's locale.
    static func title(for month: Month, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter.string(from: start(of: month, calendar: calendar))
    }

    /// Weekday initials starting from the calendar's first weekday.
    static func weekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = max(0, min(symbols.count - 1, calendar.firstWeekday - 1))
        return Array(symbols[first...] + symbols[..<first])
    }

    /// Six rows of seven day starts; nil pads days outside the month so the
    /// grid never changes height between months.
    static func grid(for month: Month, calendar: Calendar) -> [[Date?]] {
        let start = start(of: month, calendar: calendar)
        let dayCount = calendar.range(of: .day, in: .month, for: start)?.count ?? 30
        let weekday = calendar.component(.weekday, from: start)
        let leading = (weekday - calendar.firstWeekday + columnCount) % columnCount
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<dayCount {
            cells.append(calendar.date(byAdding: .day, value: offset, to: start))
        }
        let total = rowCount * columnCount
        while cells.count < total { cells.append(nil) }
        return stride(from: 0, to: total, by: columnCount).map { Array(cells[$0..<$0 + columnCount]) }
    }

    /// Groups turns, diary entries and keepsakes by local day.
    static func activity(
        turns: [UserTurnStamp], entries: [JournalEntry], keepsakes: [CompanionMilestone], calendar: Calendar
    ) -> [Date: JournalDayActivity] {
        var days: [Date: JournalDayActivity] = [:]
        for turn in turns {
            days[calendar.startOfDay(for: turn.at), default: JournalDayActivity()]
                .turnsByConversation[turn.conversationID, default: 0] += 1
        }
        for entry in entries {
            days[calendar.startOfDay(for: entry.createdAt), default: JournalDayActivity()].diaryEntries.append(entry)
        }
        for keepsake in keepsakes {
            days[calendar.startOfDay(for: keepsake.achievedAt), default: JournalDayActivity()].keepsakes.append(keepsake)
        }
        return days
    }

    static func summary(of activity: [Date: JournalDayActivity], in month: Month, calendar: Calendar) -> Summary {
        let inMonth = activity.filter { contains(month, day: $0.key, calendar: calendar) }.values
        return Summary(
            daysTalked: inMonth.filter(\.talked).count,
            diaryEntries: inMonth.reduce(0) { $0 + $1.diaryEntries.count },
            keepsakes: inMonth.reduce(0) { $0 + $1.keepsakes.count })
    }

    /// Days of `month` with a diary entry or keepsake, newest first (the
    /// month overview list; plain "talked" days stay as dots on the grid).
    static func storyDays(in activity: [Date: JournalDayActivity], month: Month, calendar: Calendar) -> [Date] {
        activity
            .filter { contains(month, day: $0.key, calendar: calendar) }
            .filter { !$0.value.diaryEntries.isEmpty || !$0.value.keepsakes.isEmpty }
            .keys.sorted(by: >)
    }

    static func contains(_ month: Month, day: Date, calendar: Calendar) -> Bool {
        day >= start(of: month, calendar: calendar) && day < end(of: month, calendar: calendar)
    }
}
