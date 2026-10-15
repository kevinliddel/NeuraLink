//
//  DailyGrounding.swift
//  NeuraLink
//
//  Passive, real-world context for the Companion State block — Living
//  Companion (docs/LIVING_COMPANION.md): what is on the user's calendar in
//  the next hours, and how last night's sleep went. Pure formatting and
//  arithmetic; the EventKit and HealthKit reads live in Data/Grounding.
//
//  Created by Dedicatus on 15/10/2026.
//

import Foundation

/// One calendar event, stripped to what the persona may mention.
struct GroundingEvent: Equatable, Sendable {
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
}

/// Last night, as HealthKit recorded it. `asleepHours` needs sleep stages
/// (an Apple Watch or a sleep app); the iPhone alone gives time in bed.
struct SleepSummary: Equatable, Sendable {
    let asleepHours: Double?
    let inBedHours: Double?
}

enum DailyGrounding {

    /// How far ahead the schedule line looks.
    static let calendarWindowHours = 12.0
    /// Events quoted at most; more than this is a list, not a thought.
    static let maxEvents = 3
    /// Below these the night was short enough to mention.
    static let shortSleepHours = 5.5
    static let shortInBedHours = 6.0

    // MARK: - Calendar

    /// Events still to come (or under way) within the window, soonest first.
    static func upcoming(_ events: [GroundingEvent], now: Date) -> [GroundingEvent] {
        let horizon = now.addingTimeInterval(calendarWindowHours * 3_600)
        return events
            .filter { $0.end > now && $0.start < horizon && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.start < $1.start }
    }

    /// "Today's schedule: Presentation at 2:00 PM; Dinner with Ana at 6:30 PM.
    /// …" or nil when nothing is coming up.
    static func calendarLine(events: [GroundingEvent], now: Date, calendar: Calendar, compact: Bool = false) -> String? {
        let soon = Array(upcoming(events, now: now).prefix(maxEvents))
        guard !soon.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        let items = soon.map { event -> String in
            if event.isAllDay { return "\(event.title) (all day)" }
            if event.start <= now { return "\(event.title) (now)" }
            return "\(event.title) at \(formatter.string(from: event.start))"
        }
        let list = items.joined(separator: "; ")
        if compact { return "Today: \(list)." }
        return "Today's schedule: \(list). Wish them luck or ask how it went when it fits naturally; "
            + "never recite the list."
    }

    // MARK: - Sleep

    /// Hours covered by the intervals, overlaps counted once (HealthKit can
    /// hold the same night from two sources).
    static func unionHours(_ intervals: [DateInterval]) -> Double {
        var total: TimeInterval = 0
        var current: DateInterval?
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let open = current, interval.start <= open.end {
                current = DateInterval(start: open.start, end: max(open.end, interval.end))
            } else {
                if let open = current { total += open.duration }
                current = interval
            }
        }
        if let open = current { total += open.duration }
        return total / 3_600
    }

    /// Nil when HealthKit had nothing for the night.
    static func summary(asleep: [DateInterval], inBed: [DateInterval]) -> SleepSummary? {
        guard !asleep.isEmpty || !inBed.isEmpty else { return nil }
        return SleepSummary(
            asleepHours: asleep.isEmpty ? nil : unionHours(asleep),
            inBedHours: inBed.isEmpty ? nil : unionHours(inBed))
    }

    /// A line only when the night was short; a normal night says nothing.
    static func sleepLine(summary: SleepSummary?, compact: Bool = false) -> String? {
        guard let summary else { return nil }
        if let asleep = summary.asleepHours {
            guard asleep < shortSleepHours else { return nil }
            let hours = formatHours(asleep)
            if compact { return "Sleep: about \(hours) h last night (short)." }
            return "Sleep last night: about \(hours) hours asleep — a short night. Go gentle, "
                + "notice it if it fits, and don't lecture them about sleep."
        }
        if let inBed = summary.inBedHours {
            guard inBed < shortInBedHours else { return nil }
            let hours = formatHours(inBed)
            if compact { return "Sleep: about \(hours) h in bed last night (short)." }
            return "Sleep last night: about \(hours) hours in bed, no sleep stages recorded — likely a short "
                + "night. Go gentle and don't lecture them about sleep."
        }
        return nil
    }

    /// 4.5 → "4.5", 7.0 → "7".
    static func formatHours(_ hours: Double) -> String {
        let half = (hours * 2).rounded() / 2
        return half == half.rounded() ? String(Int(half)) : String(half)
    }
}
