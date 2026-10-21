//
//  CalendarGrounding.swift
//  NeuraLink
//
//  EventKit read behind the schedule line (docs/LIVING_COMPANION.md). Its
//  own store, separate from ReminderSkill's: that one asks for reminders,
//  this one for calendar events.
//
//  Created by Dedicatus on 15/10/2026.
//

import EventKit
import Foundation

final class CalendarGrounding {
    static let shared = CalendarGrounding()

    private let store = EKEventStore()

    private init() {}

    var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Asks for full calendar access (the only level that reads titles).
    func requestAccess() async -> Bool {
        if isAuthorized { return true }
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        nlLog("[Grounding] calendar access \(granted ? "granted" : "denied")", level: .info)
        return granted
    }

    /// Events under way or starting within the window, as plain values.
    func upcomingEvents(now: Date = Date()) -> [GroundingEvent] {
        guard isAuthorized else { return [] }
        let end = now.addingTimeInterval(DailyGrounding.calendarWindowHours * 3_600)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        return store.events(matching: predicate).map {
            GroundingEvent(title: $0.title ?? "", start: $0.startDate, end: $0.endDate, isAllDay: $0.isAllDay)
        }
    }
}
