//
//  JournalCalendarTests.swift
//  NeuraLinkTests
//
//  Journal calendar (docs/LIVING_COMPANION.md): month-grid math, local-day
//  grouping, month summaries, and the message-table reads behind them.
//

import Foundation
import Testing

@testable import NeuraLink

@MainActor
@Suite("Journal calendar")
struct JournalCalendarTests {

    /// Antananarivo (UTC+3), so UTC evenings cross into the next local day.
    private func calendar(firstWeekday: Int) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Indian/Antananarivo") ?? .current
        cal.locale = Locale(identifier: "en_US_POSIX")
        cal.firstWeekday = firstWeekday
        return cal
    }

    private func utc(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso) ?? .distantPast
    }

    private let october = JournalCalendarModel.Month(year: 2026, month: 10)

    @Test("The grid is six rows of seven, padded to the calendar's first weekday")
    func gridShape() {
        // 1 October 2026 is a Thursday.
        let sunday = JournalCalendarModel.grid(for: october, calendar: calendar(firstWeekday: 1))
        #expect(sunday.count == 6)
        #expect(sunday.allSatisfy { $0.count == 7 })
        #expect(sunday[0].prefix(4).allSatisfy { $0 == nil })
        #expect(sunday[0][4].map { calendar(firstWeekday: 1).component(.day, from: $0) } == 1)
        #expect(sunday.flatMap { $0 }.compactMap { $0 }.count == 31)

        let monday = JournalCalendarModel.grid(for: october, calendar: calendar(firstWeekday: 2))
        #expect(monday[0].prefix(3).allSatisfy { $0 == nil })
        #expect(monday[0][3].map { calendar(firstWeekday: 2).component(.day, from: $0) } == 1)
        #expect(JournalCalendarModel.weekdaySymbols(calendar: calendar(firstWeekday: 2)).first == "M")
    }

    @Test("Months shift across year boundaries and title in the calendar's locale")
    func monthMath() {
        let cal = calendar(firstWeekday: 2)
        #expect(JournalCalendarModel.shifted(JournalCalendarModel.Month(year: 2026, month: 12), by: 1, calendar: cal)
            == JournalCalendarModel.Month(year: 2027, month: 1))
        #expect(JournalCalendarModel.shifted(JournalCalendarModel.Month(year: 2026, month: 1), by: -1, calendar: cal)
            == JournalCalendarModel.Month(year: 2025, month: 12))
        #expect(JournalCalendarModel.title(for: october, calendar: cal) == "October 2026")
        #expect(JournalCalendarModel.end(of: october, calendar: cal)
            == JournalCalendarModel.start(of: JournalCalendarModel.Month(year: 2026, month: 11), calendar: cal))
    }

    @Test("Activity lands on the local day, and the month summary counts it")
    func activityGrouping() {
        let cal = calendar(firstWeekday: 2)
        // 22:30 UTC on the 12th is 01:30 on the 13th in Antananarivo.
        let lateTurn = UserTurnStamp(conversationID: 7, at: utc("2026-10-12T22:30:00Z"))
        let noonTurn = UserTurnStamp(conversationID: 7, at: utc("2026-10-13T09:00:00Z"))
        let otherChat = UserTurnStamp(conversationID: 9, at: utc("2026-10-05T10:00:00Z"))
        let entry = JournalEntry(
            id: 1, character: "miku", conversationID: 7, diary: "We talked late.", opener: "", notificationLine: "",
            notified: false, openerUsed: false, createdAt: utc("2026-10-13T10:00:00Z"))
        let keepsake = CompanionMilestone(
            kind: .firstSharedSong, character: "miku", achievedAt: utc("2026-10-05T10:05:00Z"), celebratedAt: nil)

        let activity = JournalCalendarModel.activity(
            turns: [lateTurn, noonTurn, otherChat], entries: [entry], keepsakes: [keepsake], calendar: cal)
        let thirteenth = cal.startOfDay(for: utc("2026-10-13T05:00:00Z"))
        let fifth = cal.startOfDay(for: utc("2026-10-05T05:00:00Z"))

        #expect(activity[thirteenth]?.turnsByConversation == [7: 2])
        #expect(activity[thirteenth]?.diaryEntries == [entry])
        #expect(activity[fifth]?.keepsakes == [keepsake])
        #expect(activity[cal.startOfDay(for: utc("2026-10-12T05:00:00Z"))] == nil)

        let summary = JournalCalendarModel.summary(of: activity, in: october, calendar: cal)
        #expect(summary == JournalCalendarModel.Summary(daysTalked: 2, diaryEntries: 1, keepsakes: 1))
        #expect(JournalCalendarModel.storyDays(in: activity, month: october, calendar: cal) == [thirteenth, fifth])
        #expect(JournalCalendarModel.summary(
            of: activity, in: JournalCalendarModel.Month(year: 2026, month: 9), calendar: cal).daysTalked == 0)
    }

    @Test("Turn stamps and the last-turn-before query read the messages table")
    func storeQueries() {
        let store = MemoryStore.shared
        let id = store.insertConversation(title: "calendar-test")
        defer { store.deleteConversation(id: id) }
        store.insertMessage(conversationID: id, role: "user", kind: "message", content: "hi")
        store.insertMessage(conversationID: id, role: "assistant", kind: "message", content: "hello")
        let now = Date()

        let stamps = store.userTurnStamps(between: now.addingTimeInterval(-120), and: now.addingTimeInterval(120))
            .filter { $0.conversationID == id }
        #expect(stamps.count == 1)

        #expect((store.lastUserMessageAt(before: now.addingTimeInterval(120)) ?? .distantPast) >= now.addingTimeInterval(-120))
        let cutoff = now.addingTimeInterval(-3_600)
        #expect((store.lastUserMessageAt(before: cutoff) ?? .distantPast) < cutoff)
    }
}
