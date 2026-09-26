//
//  MemoryTemporalParser.swift
//  NeuraLink
//
//  Rule-based temporal query analyser for the temporal arm of recall and
//  for resolving relative dates at retain time (docs/AGENTIC_MEMORY.md
//  §Temporal). Hindsight uses `dateparser`; on-device we combine
//  NSDataDetector (absolute dates) with a small set of relative-expression
//  rules ("yesterday", "last week", "3 days ago", "in March").
//
//  Created by Dedicatus on 25/09/2026.
//

import Foundation

struct MemoryTimeWindow: Equatable {
    let start: Date
    let end: Date

    var midpoint: Date { start.addingTimeInterval(end.timeIntervalSince(start) / 2) }
    var halfSpanDays: Double { max(0.5, end.timeIntervalSince(start) / 86_400 / 2) }

    func contains(_ date: Date) -> Bool { date >= start && date <= end }

    /// 1 at the window midpoint, 0 at (or beyond) either edge.
    func proximity(of date: Date) -> Double {
        let daysFromMid = abs(date.timeIntervalSince(midpoint)) / 86_400
        return 1 - min(daysFromMid / halfSpanDays, 1)
    }
}

enum MemoryTemporalParser {

    /// ISO 8601 = Monday-first weeks, so "last week" is Mon–Sun and a
    /// weekend (Sat–Sun) never straddles two weeks.
    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .iso8601)
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }()

    private static let monthNames = [
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december"
    ]

    /// Returns the time window a query refers to, or nil when it has no
    /// temporal expression. `now` is injectable for tests.
    static func window(in text: String, now: Date = Date()) -> MemoryTimeWindow? {
        let lower = text.lowercased()

        if let relative = relativeWindow(in: lower, now: now) { return relative }
        if let named = namedMonthWindow(in: lower, now: now) { return named }
        if let detected = detectorWindow(in: text, now: now) { return detected }
        return nil
    }

    // MARK: - Relative expressions

    private static func relativeWindow(in lower: String, now: Date) -> MemoryTimeWindow? {
        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let joined = words.joined(separator: " ")

        // "tonight"/"later" are plans, not recall — deliberately not temporal.
        if joined.contains("today") || joined.contains("this morning") || joined.contains("this afternoon") {
            return day(containing: now)
        }
        if joined.contains("this weekend") || joined.contains("last weekend") {
            return weekendWindow(now: now, previous: joined.contains("last weekend"))
        }
        if joined.contains("yesterday") { return day(containing: shift(now, .day, -1)) }
        if joined.contains("tomorrow") { return day(containing: shift(now, .day, 1)) }
        if joined.contains("last night") { return day(containing: shift(now, .day, -1)) }
        if joined.contains("this week") { return period(.weekOfYear, containing: now) }
        if joined.contains("last week") { return period(.weekOfYear, containing: shift(now, .weekOfYear, -1)) }
        if joined.contains("this month") { return period(.month, containing: now) }
        if joined.contains("last month") { return period(.month, containing: shift(now, .month, -1)) }
        if joined.contains("this year") { return period(.year, containing: now) }
        if joined.contains("last year") { return period(.year, containing: shift(now, .year, -1)) }
        if joined.contains("recently") || joined.contains("lately") || joined.contains("these days") {
            return MemoryTimeWindow(start: shift(now, .day, -14), end: now)
        }

        // "<n> <unit>(s) ago" / "a <unit> ago" / "few <unit>s ago"
        for (index, word) in words.enumerated() where word == "ago" && index >= 2 {
            let unitWord = words[index - 1]
            let countWord = words[index - 2]
            let count: Int
            switch countWord {
            case "a", "an", "one": count = 1
            case "couple": count = 2
            case "few", "several": count = 3
            default: count = Int(countWord) ?? wordNumber(countWord) ?? 0
            }
            guard count > 0, let unit = unit(for: unitWord) else { continue }
            let anchor = shift(now, unit, -count)
            switch unit {
            case .day: return day(containing: anchor)
            case .weekOfYear: return period(.weekOfYear, containing: anchor)
            case .month: return period(.month, containing: anchor)
            default: return period(.year, containing: anchor)
            }
        }
        return nil
    }

    private static func wordNumber(_ word: String) -> Int? {
        let table = ["two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                     "eight": 8, "nine": 9, "ten": 10]
        return table[word]
    }

    private static func unit(for word: String) -> Calendar.Component? {
        switch word {
        case "day", "days": return .day
        case "week", "weeks": return .weekOfYear
        case "month", "months": return .month
        case "year", "years": return .year
        default: return nil
        }
    }

    // MARK: - Month names

    private static func namedMonthWindow(in lower: String, now: Date) -> MemoryTimeWindow? {
        for (index, name) in monthNames.enumerated() {
            guard let range = lower.range(of: "\\b\(name)\\b", options: .regularExpression) else { continue }
            // Optional explicit year right after the month name.
            let after = lower[range.upperBound...].trimmingCharacters(in: .whitespaces)
            let yearToken = after.prefix(4)
            var year = calendar.component(.year, from: now)
            if yearToken.count == 4, let explicit = Int(yearToken) { year = explicit }
            var components = DateComponents()
            components.year = year
            components.month = index + 1
            components.day = 1
            guard let start = calendar.date(from: components) else { return nil }
            // A future month with no explicit year almost always means last year's.
            let resolvedStart = (start > now && yearToken.count != 4)
                ? shift(start, .year, -1) : start
            return period(.month, containing: resolvedStart)
        }
        return nil
    }

    // MARK: - Absolute dates

    private static func detectorWindow(in text: String, now: Date) -> MemoryTimeWindow? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = detector.firstMatch(in: text, options: [], range: range), let date = match.date else {
            return nil
        }
        // A bare year like "2015" spans the whole year (Hindsight's coarse-date rule).
        if let matched = Range(match.range, in: text), text[matched].count == 4,
           Int(text[matched]) != nil {
            return period(.year, containing: date)
        }
        return day(containing: date)
    }

    // MARK: - Helpers

    static func day(containing date: Date) -> MemoryTimeWindow {
        let start = calendar.startOfDay(for: date)
        return MemoryTimeWindow(start: start, end: start.addingTimeInterval(86_400 - 1))
    }

    static func period(_ component: Calendar.Component, containing date: Date) -> MemoryTimeWindow {
        guard let interval = calendar.dateInterval(of: component, for: date) else { return day(containing: date) }
        return MemoryTimeWindow(start: interval.start, end: interval.end.addingTimeInterval(-1))
    }

    /// Sat–Sun of the current ISO week, or of the previous one. On a Monday
    /// "last weekend" is therefore the weekend that just ended.
    private static func weekendWindow(now: Date, previous: Bool) -> MemoryTimeWindow {
        let week = period(.weekOfYear, containing: previous ? shift(now, .weekOfYear, -1) : now)
        let saturday = calendar.startOfDay(for: shift(week.start, .day, 5))
        return MemoryTimeWindow(start: saturday, end: week.end)
    }

    private static func shift(_ date: Date, _ component: Calendar.Component, _ value: Int) -> Date {
        calendar.date(byAdding: component, value: value, to: date) ?? date
    }

    /// Absolute date span for a fact's `when` string ("2026-09-20",
    /// "2026-09-20/2026-09-22", "2026-09", "2026", or a relative phrase
    /// resolved against `reference`). Nil when unparseable.
    static func span(from when: String, reference: Date) -> (Date, Date)? {
        let trimmed = when.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "none", trimmed.lowercased() != "null" else { return nil }
        let parts = trimmed.split(separator: "/").map(String.init)
        if parts.count == 2, let a = isoWindow(parts[0]), let b = isoWindow(parts[1]) {
            return (a.start, b.end)
        }
        if let iso = isoWindow(trimmed) { return (iso.start, iso.end) }
        if let window = window(in: trimmed, now: reference) { return (window.start, window.end) }
        return nil
    }

    private static func isoWindow(_ value: String) -> MemoryTimeWindow? {
        let pieces = value.split(separator: "-").compactMap { Int($0) }
        guard let year = pieces.first, (1900...2200).contains(year) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = pieces.count > 1 ? pieces[1] : 1
        components.day = pieces.count > 2 ? pieces[2] : 1
        guard let date = calendar.date(from: components) else { return nil }
        switch pieces.count {
        case 1: return period(.year, containing: date)
        case 2: return period(.month, containing: date)
        default: return day(containing: date)
        }
    }
}
