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

    /// Current fraction of the day [0, 1] where 0.0 = midnight, 0.5 = noon.
    func dayFraction() -> Float {
        let cal = Calendar.current
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
}
