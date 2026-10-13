//
//  CompanionAbsenceTests.swift
//  NeuraLinkTests
//
//  The "time apart" wording in the Companion State block
//  (docs/LIVING_COMPANION.md).
//

import Foundation
import Testing

@testable import NeuraLink

@Suite("Companion absence")
struct CompanionAbsenceTests {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }

    /// Tuesday 13 October 2026, 09:30 UTC.
    private let now = ISO8601DateFormatter().date(from: "2026-10-13T09:30:00Z") ?? .distantPast

    private func describe(hoursAgo: Double) -> String? {
        CompanionAbsence.describe(lastTalkedAt: now.addingTimeInterval(-hoursAgo * 3_600), now: now, calendar: calendar)
    }

    @Test("Short gaps say nothing; same-day gaps are counted in hours")
    func sameDay() {
        #expect(describe(hoursAgo: 0.5) == nil)
        #expect(describe(hoursAgo: 1) == "earlier today, about an hour ago")
        #expect(describe(hoursAgo: 5) == "earlier today, about 5 hours ago")
    }

    @Test("Day gaps name the day and time of day the user was last here")
    func dayGaps() {
        #expect(describe(hoursAgo: 14.5) == "yesterday (Monday evening)")           // Mon 19:00
        #expect(describe(hoursAgo: 3 * 24 + 15.5) == "4 days ago (Friday evening)")  // Fri 18:00
        #expect(describe(hoursAgo: 9 * 24) == "about a week ago (Sunday morning)")
        #expect(describe(hoursAgo: 21 * 24) == "3 weeks ago")
        #expect(describe(hoursAgo: 40 * 24) == "about a month ago")
        #expect(describe(hoursAgo: 100 * 24) == "about 3 months ago")
    }

    @Test("The prompt line states the present and asks for a natural acknowledgement")
    func line() {
        let lastTalked = now.addingTimeInterval(-3 * 86_400)
        let full = CompanionAbsence.line(lastTalkedAt: lastTalked, now: now, calendar: calendar)
        #expect(full?.hasPrefix("Time apart: you last talked 3 days ago (Saturday morning); it's Tuesday morning now.") == true)
        #expect(full?.contains("without guilt-tripping") == true)

        let compact = CompanionAbsence.line(lastTalkedAt: lastTalked, now: now, calendar: calendar, compact: true)
        #expect(compact == "Time apart: last talked 3 days ago (Saturday morning); now Tuesday morning.")
        #expect(CompanionAbsence.line(lastTalkedAt: now.addingTimeInterval(-600), now: now, calendar: calendar) == nil)
    }
}
