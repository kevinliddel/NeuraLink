//
//  SkyTimeProvider.swift
//  NeuraLink
//
//  Created by Dedicatus on 17/04/2026.
//

import Foundation

/// Provides time-of-day information from the device's local timezone.
struct SkyTimeProvider {

    /// Overridable time source — swap in tests for deterministic output.
    var now: () -> Date = { Date() }

    /// Zone the hour is read in: the device's, unless a test pins one.
    var timeZone: TimeZone = .current

    /// Current fraction of the day [0, 1] where 0.0 = midnight, 0.5 = noon.
    func dayFraction() -> Float {
        var cal = Calendar.current
        cal.timeZone = timeZone
        let comps = cal.dateComponents([.hour, .minute, .second], from: now())
        let secs = Float(comps.hour ?? 0) * 3600
            + Float(comps.minute ?? 0) * 60
            + Float(comps.second ?? 0)
        return secs / 86400.0
    }

    /// Current local hour in the range [0, 24).
    func currentHour() -> Float {
        dayFraction() * 24.0
    }

    /// The device clock, or one started elsewhere for checking a dawn or a
    /// moonrise without waiting for it: `NL_SKY_DATE` (yyyy-MM-dd) and/or
    /// `NL_SKY_TIME` (HH:mm) set where it starts, `NL_SKY_SPEED` how many
    /// times faster than real time it runs (60 = a minute a second).
    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        clock: @escaping () -> Date = { Date() }
    ) -> SkyTimeProvider {
        let date = environment["NL_SKY_DATE"]
        let time = environment["NL_SKY_TIME"]
        let speed = environment["NL_SKY_SPEED"].flatMap(Double.init) ?? 1
        guard date != nil || time != nil || speed != 1 else { return SkyTimeProvider(now: clock) }

        let launch = clock()
        var calendar = Calendar.current
        calendar.timeZone = .current
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: launch)
        if let date {
            let numbers = date.split(separator: "-").compactMap { Int($0) }
            if numbers.count == 3 { (parts.year, parts.month, parts.day) = (numbers[0], numbers[1], numbers[2]) }
        }
        if let time {
            let numbers = time.split(separator: ":").compactMap { Int($0) }
            if numbers.count >= 2 { (parts.hour, parts.minute, parts.second) = (numbers[0], numbers[1], 0) }
        }
        let start = calendar.date(from: parts) ?? launch
        nlLog("[Sky] clock overridden: starts \(start), ×\(speed)", level: .info)
        return SkyTimeProvider(now: { start.addingTimeInterval(clock().timeIntervalSince(launch) * speed) })
    }
}
