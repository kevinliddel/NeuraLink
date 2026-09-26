//
//  MemoryStore+Timeline.swift
//  NeuraLink
//
//  Date-range queries for the Memory timeline (docs/MEMORY_OWNERSHIP_PLAN.md
//  §M3) and pure month/day bucketing.
//
//  Created by Dedicatus on 27/09/2026.
//

import Foundation
import SQLCipher

extension MemoryStore {

    /// Units whose occurred span overlaps [start, end]; with `includeUndated`
    /// also knowledge and dialogue units *mentioned* in the range that have
    /// no occurred date.
    func fetchUnits(occurringBetween start: Date, and end: Date, includeUndated: Bool) -> [MemoryUnit] {
        lock.lock()
        defer { lock.unlock() }
        let startText = Self.sqliteFormatter.string(from: start)
        let endText = Self.sqliteFormatter.string(from: end)
        var query = """
        SELECT \(Self.unitColumns) FROM memories
        WHERE fact_type IN ('world', 'experience', 'observation')
          AND occurred_start IS NOT NULL AND occurred_start <= ?2
          AND COALESCE(occurred_end, occurred_start) >= ?1
        """
        if includeUndated {
            query += """

            OR (occurred_start IS NULL AND mentioned_at BETWEEN ?1 AND ?2)
            """
        }
        query += " ORDER BY COALESCE(occurred_start, mentioned_at) DESC;"
        return runUnitQuery(query) { statement in
            sqlite3_bind_text(statement, 1, (startText as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (endText as NSString).utf8String, -1, nil)
        }
    }

    /// Number of units with an occurred date (drives whether the timeline shows).
    func countDatedUnits() -> Int {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        var count = 0
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM memories WHERE occurred_start IS NOT NULL;", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            count = Int(sqlite3_column_int(statement, 0))
        }
        sqlite3_finalize(statement)
        return count
    }
}

/// Pure calendar helpers for the timeline, using ISO weeks like the rest
/// of the memory layer.
nonisolated enum MemoryTimelineModel {
    static let calendar: Calendar = {
        var cal = Calendar(identifier: .iso8601)
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }()

    struct Month: Hashable, Identifiable, Sendable {
        let year: Int
        let month: Int
        var id: String { "\(year)-\(month)" }

        var start: Date { calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date() }
        var end: Date { calendar.date(byAdding: DateComponents(month: 1, second: -1), to: start) ?? start }
        var label: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM"
            return formatter.string(from: start)
        }
    }

    /// The last `count` months ending with the month containing `now`, oldest first.
    static func recentMonths(count: Int, now: Date = Date()) -> [Month] {
        let current = calendar.dateComponents([.year, .month], from: now)
        return (0..<count).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .month, value: -offset, to: calendar.date(from: current) ?? now) else { return nil }
            let parts = calendar.dateComponents([.year, .month], from: date)
            return Month(year: parts.year ?? 0, month: parts.month ?? 0)
        }
    }

    /// Anchor date for placing a unit on the timeline.
    static func anchor(_ unit: MemoryUnit) -> Date { unit.occurredStart ?? unit.mentionedAt }

    /// Units per month (a unit belongs to the month of its anchor date).
    static func countsByMonth(_ units: [MemoryUnit], months: [Month]) -> [Month: Int] {
        var counts: [Month: Int] = [:]
        for unit in units {
            let parts = calendar.dateComponents([.year, .month], from: anchor(unit))
            let month = Month(year: parts.year ?? 0, month: parts.month ?? 0)
            if months.contains(month) { counts[month, default: 0] += 1 }
        }
        return counts
    }

    /// Units of `month` grouped by day, newest day first, newest unit first.
    static func daysInMonth(_ units: [MemoryUnit], month: Month) -> [(day: Date, units: [MemoryUnit])] {
        var groups: [Date: [MemoryUnit]] = [:]
        for unit in units {
            let date = anchor(unit)
            guard date >= month.start, date <= month.end else { continue }
            groups[calendar.startOfDay(for: date), default: []].append(unit)
        }
        return groups.keys.sorted(by: >).map { day in
            (day: day, units: groups[day]!.sorted { anchor($0) > anchor($1) })
        }
    }

    /// Units that occurred on today's month/day in a previous year.
    static func onThisDay(_ units: [MemoryUnit], now: Date = Date()) -> [MemoryUnit] {
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        return units.filter { unit in
            guard let start = unit.occurredStart else { return false }
            let parts = calendar.dateComponents([.year, .month, .day], from: start)
            return parts.month == today.month && parts.day == today.day && (parts.year ?? 0) < (today.year ?? 0)
        }
    }
}
