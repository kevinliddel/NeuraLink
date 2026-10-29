//
//  SkyLocation.swift
//  NeuraLink
//
//  Where on Earth the sky is drawn for, without asking: the place the
//  device's time zone is named after, from a bundled table of the tz
//  database's zones (sky_zones.txt, scripts/make_sky_tables.py). The
//  Antananarivo zone puts the sun within a few minutes of its real rise and
//  set anywhere in Madagascar, and no location permission is involved.
//
//  Created by Dedicatus on 27/10/2026.
//

import Foundation

nonisolated struct SkyLocation: Equatable {

    /// Degrees, north positive.
    let latitude: Double

    /// Degrees, east positive.
    let longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// The zone's own city. A zone the table does not know (GMT, a fixed
    /// offset) gets the equator, at the longitude its UTC offset stands for.
    init(timeZone: TimeZone) {
        if let known = Self.zones[timeZone.identifier] {
            self = known
        } else {
            self.init(latitude: 0, longitude: Double(timeZone.secondsFromGMT()) / 240)
        }
    }

    private static let zones: [String: SkyLocation] = {
        guard let url = Bundle.main.url(forResource: "sky_zones", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [:] }
        var zones: [String: SkyLocation] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: " ")
            guard fields.count == 3, let latitude = Double(fields[1]), let longitude = Double(fields[2])
            else { continue }
            zones[String(fields[0])] = SkyLocation(latitude: latitude, longitude: longitude)
        }
        return zones
    }()
}
