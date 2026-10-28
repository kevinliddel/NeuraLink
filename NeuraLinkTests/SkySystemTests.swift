//
//  SkySystemTests.swift
//  NeuraLinkTests
//
//  Created by Dedicatus on 17/04/2026.
//

import Testing
import Foundation
import simd
@testable import NeuraLink

@Suite("Sky System Tests")
struct SkySystemTests {

    private static let antananarivo = SkyLocation(latitude: -18.92, longitude: 47.52)
    private static let paris = SkyLocation(latitude: 48.87, longitude: 2.33)

    // MARK: - Where

    @Test("A time zone resolves to its city, an old name to the same place, an unknown zone to its offset")
    func testLocation() throws {
        let tana = SkyLocation(timeZone: try #require(TimeZone(identifier: "Indian/Antananarivo")))
        #expect(tana == Self.antananarivo)
        let calcutta = SkyLocation(timeZone: try #require(TimeZone(identifier: "Asia/Calcutta")))
        #expect(abs(calcutta.latitude - 22.53) < 0.01 && abs(calcutta.longitude - 88.37) < 0.01)
        let offset = SkyLocation(timeZone: try #require(TimeZone(secondsFromGMT: 3 * 3600)))
        #expect(offset.latitude == 0 && abs(offset.longitude - 45) < 1e-9)
    }

    // MARK: - Ephemeris, against Meeus's worked examples

    @Test("Sidereal time: Meeus example 12.a")
    func testSiderealTime() {
        // 1987 April 10, 0h UT: 13h10m46.3668s.
        let gmst = SkyEphemeris.greenwichSiderealTime(date(julianDay: 2_446_895.5))
        #expect(abs(gmst - 197.693195) < 1e-4)
    }

    @Test("Sun: Meeus example 25.a")
    func testSunPosition() {
        // 1992 October 13, 0h TD: α 198.38083°, δ −7.78507°.
        let sun = SkyEphemeris.sun(SkyEphemeris.centuries(date(julianDay: 2_448_908.5)))
        let rightAscension = SkyEphemeris.wrapped(SkyEphemeris.degrees(atan2(sun.y, sun.x)))
        #expect(abs(rightAscension - 198.38083) < 0.001)
        #expect(abs(SkyEphemeris.degrees(asin(sun.z)) - -7.78507) < 0.001)
    }

    @Test("Moon: Meeus example 47.a, to within the terms left out")
    func testMoonPosition() {
        // 1992 April 12, 0h TD: apparent λ 133.167265°, β −3.229126°,
        // Δ 368409.7 km from the full tables.
        let moon = SkyEphemeris.moon(SkyEphemeris.centuries(date(julianDay: 2_448_724.5)))
        #expect(abs(moon.longitude - 133.167265) < 0.03)
        #expect(abs(moon.latitude - -3.229126) < 0.01)
        #expect(abs(moon.distance - 368_409.7) < 100)
    }

    // MARK: - The sun over Antananarivo

    /// Sunrise and sunset (UTC) from sunrise-sunset.org, which runs NOAA's
    /// algorithm, for 18.92° S 47.52° E. Fetched 2026-10-27.
    @Test("Sunrise and sunset within two minutes of NOAA's", arguments: [
        ("2026-03-20T02:53:41Z", "2026-03-20T15:01:08Z"),
        ("2026-06-21T03:21:57Z", "2026-06-21T14:21:28Z"),
        ("2026-09-23T02:38:32Z", "2026-09-23T14:46:06Z"),
        ("2026-12-21T02:09:45Z", "2026-12-21T15:26:05Z")
    ])
    func testSunriseSunset(sunrise: String, sunset: String) throws {
        for published in [try utc(sunrise), try utc(sunset)] {
            // The upper limb on the horizon, refraction included: the
            // centre is 0.833° below it.
            let crossing = horizonCrossing(near: published, elevation: -0.833) {
                SkyBodies(at: $0, location: Self.antananarivo).sunDirection
            }
            #expect(abs(crossing.timeIntervalSince(published)) < 120, "\(published): \(crossing)")
        }
    }

    @Test("The noon sun stands at the latitude's height for the season, north or south")
    func testNoonSun() throws {
        // Antananarivo, June solstice: 90 − 18.92 − 23.44 = 47.6° up, north.
        let tanaNoon = try utc("2026-06-21T08:51:43Z")
        let tana = SkyBodies(at: tanaNoon, location: Self.antananarivo).sunDirection
        #expect(abs(elevation(tana) - 47.64) < 0.3)
        #expect(simd_dot(simd_normalize(SIMD3<Float>(tana.x, 0, tana.z)), compass(Self.antananarivo, at: tanaNoon).north) > 0.99)
        // Paris, same day: 90 − 48.87 + 23.44 = 64.6° up, south.
        let parisNoon = try utc("2026-06-21T11:52:00Z")
        let paris = SkyBodies(at: parisNoon, location: Self.paris).sunDirection
        #expect(abs(elevation(paris) - 64.57) < 0.5)
        #expect(simd_dot(simd_normalize(SIMD3<Float>(paris.x, 0, paris.z)), compass(Self.paris, at: parisNoon).north) < -0.99)
    }

    @Test("The sun sets just beside straight ahead, on the equator's side, every day, in either hemisphere",
          arguments: ["2026-03-20", "2026-06-21", "2026-09-23", "2026-12-21"])
    func testSunsetAhead(day: String) throws {
        for location in [Self.antananarivo, Self.paris] {
            let sun = { (instant: Date) in SkyBodies(at: instant, location: location).sunDirection }
            // From solar noon there, the first five minutes the sun is down.
            let noon = try utc("\(day)T12:00:00Z").addingTimeInterval(-location.longitude * 240)
            let dusk = try #require(stride(from: 0.0, through: 12 * 3600, by: 300)
                .map { noon.addingTimeInterval($0) }
                .first { elevation(sun($0)) < 0 })
            let sunset = sun(horizonCrossing(near: dusk, elevation: 0, direction: sun))
            // Degrees right of straight ahead (−Z): right in the south, left in the north.
            let bearing = Double(atan2(sunset.x, -sunset.z)) * 180 / .pi
            let expected = location.latitude < 0 ? SkyBodies.sunsetBearing : -SkyBodies.sunsetBearing
            #expect(abs(bearing - expected) < 0.05, "\(day), \(location.latitude)°: sets \(bearing)° off ahead")
        }
    }

    @Test("The sun rises in the east and sets in the west of the scene's compass")
    func testSunRisesInTheEast() throws {
        for (location, morning, evening) in [
            (Self.antananarivo, "2026-06-21T03:22:00Z", "2026-06-21T14:21:00Z"),
            (Self.paris, "2026-06-21T03:47:00Z", "2026-06-21T19:58:00Z")
        ] {
            let east = compass(location, at: try utc(morning)).east
            #expect(simd_dot(SkyBodies(at: try utc(morning), location: location).sunDirection, east) > 0.75)
            #expect(simd_dot(SkyBodies(at: try utc(evening), location: location).sunDirection, east) < -0.75)
        }
    }

    @Test("Sun and moon directions stay unit length through a day")
    func testDirectionsAreUnit() throws {
        let start = try utc("2026-10-27T00:00:00Z")
        for hour in 0..<24 {
            let bodies = SkyBodies(at: start.addingTimeInterval(Double(hour) * 3600), location: Self.antananarivo)
            #expect(abs(simd_length(bodies.sunDirection) - 1) < 1e-5)
            #expect(abs(simd_length(bodies.moonDirection) - 1) < 1e-5)
        }
    }

    // MARK: - The moon

    /// New, quarter and full moons of 2026 (UT) from Espenak's phase
    /// table (astropixels.com).
    @Test("Lit fraction at 2026's new, quarter and full moons", arguments: [
        ("2026-02-17T12:01:00Z", 0.0), ("2026-03-03T11:38:00Z", 1.0), ("2026-06-21T21:55:00Z", 0.5),
        ("2026-08-12T17:37:00Z", 0.0), ("2026-10-26T04:12:00Z", 1.0), ("2026-11-01T20:28:00Z", 0.5)
    ])
    func testMoonPhase(instant: String, lit: Double) throws {
        let bodies = SkyBodies(at: try utc(instant), location: Self.antananarivo)
        #expect(abs(Double(bodies.moonIllumination) - lit) < (lit == 0.5 ? 0.03 : 0.01))
        // Moonlight falls far faster than the lit fraction.
        if lit == 0.5 { #expect(bodies.moonBrightness > 0.05 && bodies.moonBrightness < 0.15) }
        if lit == 1 { #expect(bodies.moonBrightness > 0.85) }
    }

    @Test("Eclipses line the sun and moon up: the moon's latitude is right too")
    func testEclipses() throws {
        // Annular 2026-02-17 and total 2026-08-12 solar eclipses, total
        // 2026-03-03 lunar eclipse. Any other new or full moon may pass up
        // to 5° off.
        for (instant, solar) in [("2026-02-17T12:12:00Z", true), ("2026-08-12T17:46:00Z", true),
                                 ("2026-03-03T11:33:00Z", false)] {
            let t = SkyEphemeris.centuries(try utc(instant))
            let sun = SkyEphemeris.sun(t)
            let moon = SkyEphemeris.moon(t).direction
            let separation = SkyEphemeris.degrees(acos(simd_dot(solar ? sun : -sun, moon)))
            #expect(separation < 1.3, "\(instant): \(separation)°")
        }
    }

    // MARK: - The stars

    @Test("The sky turns about the south celestial pole, fixed at the latitude's height, once a sidereal day")
    func testCelestialPole() throws {
        let evening = try utc("2026-06-21T17:00:00Z")
        let morning = evening.addingTimeInterval(8 * 3600)
        // The pole and the equator of date, in the catalogue's J2000 frame.
        let precession = SkyEphemeris.precession(SkyEphemeris.centuries(evening)).transpose
        let pole = SIMD3<Float>(precession * [0, 0, -1])
        let equator = SIMD3<Float>(precession * [1, 0, 0])

        let first = SkyBodies(at: evening, location: Self.antananarivo).starRotation
        let second = SkyBodies(at: morning, location: Self.antananarivo).starRotation
        #expect(simd_distance(first * pole, second * pole) < 1e-4)
        #expect(abs(elevation(first * pole) - 18.92) < 0.01)
        let south = -compass(Self.antananarivo, at: evening).north
        #expect(simd_dot(simd_normalize(SIMD3<Float>((first * pole).x, 0, (first * pole).z)), south) > 0.9999)
        // Eight solar hours are 8.022 sidereal ones: 120.33°.
        let turned = acos(simd_dot(first * equator, second * equator)) * 180 / .pi
        #expect(abs(turned - 120.33) < 0.05)
        // A rotation: no stretch, no mirror.
        #expect(abs(simd_determinant(first) - 1) < 1e-4)
        let gram = first.transpose * first
        for k in 0..<3 { #expect(simd_distance(gram[k], matrix_identity_float3x3[k]) < 1e-4) }
    }

    @Test("The bright-star catalogue loads, brightest first: Sirius")
    func testStarCatalogue() throws {
        let stars = SkyStarCatalogue.load()
        #expect(stars.count > 280 && stars.count < 330)
        let sirius = try #require(stars.first)
        let ra: Float = 101.287 * .pi / 180, dec: Float = -16.716 * .pi / 180
        let expected = SIMD3<Float>(cos(dec) * cos(ra), cos(dec) * sin(ra), sin(dec))
        #expect(simd_distance(SIMD3<Float>(sirius.directionAndMagnitude.x, sirius.directionAndMagnitude.y,
                                           sirius.directionAndMagnitude.z), expected) < 1e-4)
        #expect(sirius.directionAndMagnitude.w == -1.46)
        #expect(MemoryLayout<SkyStarData>.stride == 32)
    }

    // MARK: - Lighting

    @Test("The key light never jumps: minute to minute through whole days", arguments: [
        "2026-06-20T21:00:00Z", "2026-08-11T21:00:00Z", "2026-10-25T21:00:00Z"  // local midnights
    ])
    func testKeyLightIsContinuous(midnight: String) throws {
        // It used to flip to the opposite horizon the instant the sun crossed
        // it — 180° in one frame, avatar lighting and every shadow at once.
        let start = try utc(midnight)
        var previous = SkyEnvironment.resolve(at: start, location: Self.antananarivo).keyLight.direction
        var worst: Float = 0
        for minute in 1...(24 * 60) {
            let instant = start.addingTimeInterval(Double(minute) * 60)
            let light = SkyEnvironment.resolve(at: instant, location: Self.antananarivo).keyLight
            let step = acos(min(1, simd_dot(previous, light.direction))) * 180 / .pi
            worst = max(worst, step)
            #expect(abs(simd_length(light.direction) - 1) < 1e-4)
            #expect(light.direction.y >= SkyKeyLight.minimumElevation - 1e-4,
                    "minute \(minute): light from \(light.direction.y), below the floor")
            previous = light.direction
        }
        #expect(worst < 8, "largest minute-to-minute turn \(worst)°")
    }

    @Test("The key light is the sun by day and the full moon by night")
    func testKeyLightSources() throws {
        let morning = SkyEnvironment.resolve(at: try utc("2026-10-26T07:00:00Z"), location: Self.antananarivo)
        #expect(simd_dot(morning.keyLight.direction, morning.sunDirection) > 0.9999)
        let midnight = SkyEnvironment.resolve(at: try utc("2026-10-25T21:00:00Z"), location: Self.antananarivo)
        #expect(simd_dot(midnight.keyLight.direction, midnight.moonDirection) > 0.9999)
        #expect(midnight.keyLight.shadowSoftness < morning.keyLight.shadowSoftness)
    }

    @Test("The avatar is lit from the camera's side; a light behind her rims her instead")
    func testAvatarKeyLight() throws {
        // Antananarivo, an hour before sunset: the sun low ahead, behind her.
        let evening = SkyEnvironment.resolve(at: try utc("2026-06-21T13:20:00Z"), location: Self.antananarivo)
        let key = evening.keyLight
        #expect(key.direction.z < -0.5)
        #expect(key.avatarDirection == SIMD3<Float>(key.direction.x, key.direction.y, -key.direction.z))
        #expect(simd_dot(simd_normalize(evening.rimLightDirection), key.direction) > 0.999)
        #expect(simd_distance(evening.rimLightColor, key.color) < 1e-4)
        // Morning: the sun behind the camera lights her face as it is, and
        // the rim stays the art light above-behind.
        let morning = SkyEnvironment.resolve(at: try utc("2026-06-21T05:00:00Z"), location: Self.antananarivo)
        #expect(morning.keyLight.direction.z > 0)
        #expect(morning.keyLight.avatarDirection == morning.keyLight.direction)
        #expect(morning.rimLightDirection.z < -0.9)
    }

    @Test("Moonlight follows the phase, above the floor a face reads at")
    func testNightKeyIntensity() throws {
        let fullMoon = SkyEnvironment.resolve(at: try utc("2026-10-25T21:00:00Z"), location: Self.antananarivo)
        let newMoon = SkyEnvironment.resolve(at: try utc("2026-11-08T21:00:00Z"), location: Self.antananarivo)
        #expect(newMoon.keyLight.intensity >= 0.40)
        #expect(fullMoon.keyLight.intensity > newMoon.keyLight.intensity + 0.1)
        #expect(fullMoon.keyLight.intensity < 0.70)
        let noon = SkyEnvironment.resolve(at: try utc("2026-10-26T09:00:00Z"), location: Self.antananarivo)
        #expect(noon.keyLight.intensity > 0.80)
    }

    @Test("Stars come out at night and stay in by day; clouds stay in range")
    func testStarsAndClouds() throws {
        let start = try utc("2026-10-26T21:00:00Z")
        for hour in 0..<24 {
            let env = SkyEnvironment.resolve(at: start.addingTimeInterval(Double(hour) * 3600),
                                             location: Self.antananarivo)
            #expect(env.cloudCoverage >= 0 && env.cloudCoverage <= 1)
            if env.sunDirection.y > 0.2 { #expect(env.starVisibility < 0.01) }
            if env.sunDirection.y < -0.4 { #expect(env.starVisibility > 0.9) }
        }
    }

    // MARK: - Clock override

    @Test("NL_SKY_DATE / NL_SKY_TIME / NL_SKY_ZONE start the clock elsewhere, NL_SKY_SPEED runs it faster")
    func testClockOverride() throws {
        var tick: TimeInterval = 0
        let real = { Date(timeIntervalSince1970: 1_800_000_000 + tick) }
        let provider = SkyTimeProvider.fromEnvironment(
            ["NL_SKY_DATE": "2026-06-21", "NL_SKY_TIME": "05:30", "NL_SKY_SPEED": "60",
             "NL_SKY_ZONE": "Indian/Antananarivo"], clock: real)
        #expect(provider.now() == (try utc("2026-06-21T02:30:00Z")))
        tick = 30  // 30 real seconds at ×60 = 30 sky minutes
        #expect(provider.now() == (try utc("2026-06-21T03:00:00Z")))
        #expect(provider.location == Self.antananarivo)

        let untouched = SkyTimeProvider.fromEnvironment([:], clock: real)
        #expect(untouched.now() == real())
    }

    // MARK: - SkyUniformsData layout

    @Test("SkyUniformsData stride is 224 bytes")
    func testUniformsLayout() {
        #expect(MemoryLayout<SkyUniformsData>.stride == 224)
    }
}

// MARK: - Helpers

private func utc(_ iso: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: iso))
}

private func date(julianDay: Double) -> Date {
    Date(timeIntervalSince1970: (julianDay - 2_440_587.5) * 86400)
}

/// Degrees above the horizon.
/// The scene's compass at `location` on the day of `instant`.
private func compass(_ location: SkyLocation, at instant: Date) -> (east: SIMD3<Float>, north: SIMD3<Float>) {
    let declination = SkyEphemeris.degrees(asin(SkyEphemeris.sun(SkyEphemeris.centuries(instant)).z))
    let (east, north) = SkyBodies.compass(latitude: location.latitude, sunDeclination: declination)
    return (SIMD3<Float>(east), SIMD3<Float>(north))
}

private func elevation(_ direction: SIMD3<Float>) -> Double {
    Double(asin(direction.y)) * 180 / .pi
}

/// When `direction` passes `elevation` degrees, within half an hour of
/// `near`, found by bisection.
private func horizonCrossing(
    near: Date, elevation target: Double, direction: (Date) -> SIMD3<Float>
) -> Date {
    var low = near.addingTimeInterval(-1800)
    var high = near.addingTimeInterval(1800)
    let rising = elevation(direction(low)) < target
    for _ in 0..<30 {
        let middle = low.addingTimeInterval(high.timeIntervalSince(low) / 2)
        if (elevation(direction(middle)) < target) == rising { low = middle } else { high = middle }
    }
    return low
}
