//
//  SkyTimeProvider.swift
//  NeuraLink
//
//  Created by Dedicatus on 17/04/2026.
//

import Foundation

/// When and where the sky is drawn for: the device's clock, and the place
/// its time zone is named after.
struct SkyTimeProvider {

    /// Overridable time source — swap in tests for deterministic output.
    var now: () -> Date = { Date() }

    /// The device's zone, followed when the user travels, unless a test or
    /// `NL_SKY_ZONE` pins one. It names the place too (`location`).
    var timeZone: TimeZone = .autoupdatingCurrent

    /// Where the sun, moon and stars are worked out for.
    var location: SkyLocation { SkyLocation(timeZone: timeZone) }

    /// The device clock, or one started elsewhere for checking a dawn or a
    /// moonrise without waiting for it: `NL_SKY_DATE` (yyyy-MM-dd) and/or
    /// `NL_SKY_TIME` (HH:mm) set where it starts, `NL_SKY_SPEED` how many
    /// times faster than real time it runs (60 = a minute a second), and
    /// `NL_SKY_ZONE` (an IANA name, e.g. Europe/Paris) the place and the
    /// zone those are read in.
    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        clock: @escaping () -> Date = { Date() }
    ) -> SkyTimeProvider {
        let date = environment["NL_SKY_DATE"]
        let time = environment["NL_SKY_TIME"]
        let speed = environment["NL_SKY_SPEED"].flatMap(Double.init) ?? 1
        let zone = environment["NL_SKY_ZONE"].flatMap(TimeZone.init(identifier:))
        guard date != nil || time != nil || speed != 1 || zone != nil else { return SkyTimeProvider(now: clock) }

        let launch = clock()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone ?? .current
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
        nlLog("[Sky] clock overridden: starts \(start), ×\(speed), in \(calendar.timeZone.identifier)", level: .info)
        return SkyTimeProvider(
            now: { start.addingTimeInterval(clock().timeIntervalSince(launch) * speed) },
            timeZone: calendar.timeZone)
    }
}
