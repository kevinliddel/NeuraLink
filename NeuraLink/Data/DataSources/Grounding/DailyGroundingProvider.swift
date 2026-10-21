//
//  DailyGroundingProvider.swift
//  NeuraLink
//
//  Fetches the calendar and sleep lines once per foreground visit and
//  holds them for the Companion State block (docs/LIVING_COMPANION.md),
//  the same freeze the time-apart line uses, so the block reads the same
//  on every turn of a session. When a fetch lands after the first block
//  was built, the Realtime instructions are refreshed.
//
//  Created by Dedicatus on 15/10/2026.
//

import Foundation
import Observation

@Observable
final class DailyGroundingProvider {
    static let shared = DailyGroundingProvider()

    private(set) var calendarEvents: [GroundingEvent] = []
    private(set) var sleep: SleepSummary?
    /// When the visit's values were taken; what the lines are formatted against.
    private(set) var takenAt: Date?
    private var fetchedForVisit: Date?
    private var fetchTask: Task<Void, Never>?

    private init() {}

    /// Fetches for the current visit unless already done. Cheap to call
    /// from every prompt build.
    func refreshIfNeeded() {
        let visit = InteractionClock.shared.foregroundAt
        guard fetchedForVisit != visit else { return }
        fetchedForVisit = visit
        fetchTask?.cancel()
        let settings = GroundingSettings.shared
        guard settings.isCalendarEnabled || settings.isSleepEnabled else {
            calendarEvents = []
            sleep = nil
            takenAt = nil
            return
        }
        fetchTask = Task { [weak self] in
            let now = Date()
            let events = settings.isCalendarEnabled ? CalendarGrounding.shared.upcomingEvents(now: now) : []
            let night = settings.isSleepEnabled ? await SleepGrounding.shared.lastNight(now: now) : nil
            guard let self, !Task.isCancelled else { return }
            let changed = events != self.calendarEvents || night != self.sleep
            self.calendarEvents = events
            self.sleep = night
            self.takenAt = now
            nlLog("[Grounding] \(events.count) event(s), sleep \(night == nil ? "none" : "known")", level: .info)
            if changed {
                NotificationCenter.default.post(name: .realtimeInstructionsDidChange, object: nil)
            }
        }
    }

    /// The block's lines for this visit; empty until the fetch has landed.
    func lines(compact: Bool, calendar: Calendar = .current) -> [String] {
        guard let takenAt else { return [] }
        var out: [String] = []
        if let line = DailyGrounding.calendarLine(events: calendarEvents, now: takenAt, calendar: calendar, compact: compact) {
            out.append(line)
        }
        if let line = DailyGrounding.sleepLine(summary: sleep, compact: compact) {
            out.append(line)
        }
        return out
    }

    /// Settings changed: forget the visit so the next build re-fetches.
    func invalidate() {
        fetchedForVisit = nil
        refreshIfNeeded()
    }
}
