//
//  DailyGroundingTests.swift
//  NeuraLinkTests
//
//  Daily grounding lines (docs/LIVING_COMPANION.md): the schedule line's
//  window, order and wording, and the sleep summary's interval union and
//  thresholds.
//

import Foundation
import Testing

@testable import NeuraLink

@Suite("Daily grounding")
struct DailyGroundingTests {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }

    /// Tuesday 13 October 2026, 09:30.
    private let now = ISO8601DateFormatter().date(from: "2026-10-13T09:30:00Z") ?? .distantPast

    private func event(_ title: String, inHours start: Double, lasting: Double = 1, allDay: Bool = false) -> GroundingEvent {
        let begin = now.addingTimeInterval(start * 3_600)
        return GroundingEvent(title: title, start: begin, end: begin.addingTimeInterval(lasting * 3_600), isAllDay: allDay)
    }

    @Test("The schedule line keeps the next few events in the window, soonest first")
    func calendarLine() {
        let events = [
            event("Dinner with Ana", inHours: 9),
            event("Presentation", inHours: 4.5),
            event("Standup", inHours: -0.5, lasting: 1),          // under way
            event("Yesterday's call", inHours: -5, lasting: 1),   // over
            event("Flight", inHours: 20),                         // beyond the window
            event("Ana's birthday", inHours: -9.5, lasting: 24, allDay: true),    // started at midnight
            event("   ", inHours: 2)                              // untitled
        ]
        let line = DailyGrounding.calendarLine(events: events, now: now, calendar: calendar)
        #expect(line?.hasPrefix(
            "Today's schedule: Ana's birthday (all day); Standup (now); Presentation at 2:00 PM.") == true)
        #expect(line?.contains("never recite the list") == true)
        #expect(DailyGrounding.calendarLine(events: events, now: now, calendar: calendar, compact: true)
            == "Today: Ana's birthday (all day); Standup (now); Presentation at 2:00 PM.")
        #expect(DailyGrounding.calendarLine(events: [], now: now, calendar: calendar) == nil)
        #expect(DailyGrounding.calendarLine(events: [event("Flight", inHours: 20)], now: now, calendar: calendar) == nil)
    }

    @Test("Sleep hours are the union of intervals, and only a short night is mentioned")
    func sleep() {
        let midnight = now.addingTimeInterval(-9.5 * 3_600)
        func span(_ from: Double, _ to: Double) -> DateInterval {
            DateInterval(start: midnight.addingTimeInterval(from * 3_600), end: midnight.addingTimeInterval(to * 3_600))
        }
        // Two sources overlapping 1–3 h: 0–3 and 2–4.5 cover 4.5 h, not 5.5.
        #expect(DailyGrounding.unionHours([span(2, 4.5), span(0, 3)]) == 4.5)

        let short = DailyGrounding.summary(asleep: [span(0, 3), span(2, 4.5)], inBed: [span(-0.5, 5)])
        #expect(short == SleepSummary(asleepHours: 4.5, inBedHours: 5.5))
        #expect(DailyGrounding.sleepLine(summary: short)?.hasPrefix("Sleep last night: about 4.5 hours asleep") == true)
        #expect(DailyGrounding.sleepLine(summary: short, compact: true) == "Sleep: about 4.5 h last night (short).")

        let fine = DailyGrounding.summary(asleep: [span(0, 7.25)], inBed: [])
        #expect(DailyGrounding.sleepLine(summary: fine) == nil)

        let bedOnly = DailyGrounding.summary(asleep: [], inBed: [span(1, 6)])
        #expect(DailyGrounding.sleepLine(summary: bedOnly)?.contains("about 5 hours in bed") == true)
        #expect(DailyGrounding.sleepLine(summary: DailyGrounding.summary(asleep: [], inBed: [span(0, 8)])) == nil)
        #expect(DailyGrounding.summary(asleep: [], inBed: []) == nil)
        #expect(DailyGrounding.sleepLine(summary: nil) == nil)
        #expect(DailyGrounding.formatHours(6.96) == "7")
        #expect(DailyGrounding.formatHours(4.3) == "4.5")
    }
}
