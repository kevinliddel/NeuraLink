//
//  SkyEphemeris.swift
//  NeuraLink
//
//  Where the sun and moon really are, from the instant alone: the
//  low-precision solar position of Meeus, Astronomical Algorithms ch. 25
//  (the NOAA calculator's, about 0.01°), the largest terms of the lunar
//  theory of ch. 47 (about 0.1°), and Greenwich sidereal time (ch. 12) to
//  turn them, and the stars, into one observer's sky. Pure functions of a
//  Date in double precision; `SkyBodies` places the results in the scene.
//
//  Created by Dedicatus on 27/10/2026.
//

import Foundation
import simd

nonisolated enum SkyEphemeris {

    /// Julian day of an instant (UT; the minute TT runs ahead is ignored).
    static func julianDay(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86400 + 2_440_587.5
    }

    /// Julian centuries since J2000.0.
    static func centuries(_ date: Date) -> Double {
        (julianDay(date) - 2_451_545) / 36525
    }

    /// Greenwich mean sidereal time in degrees [0, 360). Meeus 12.4.
    static func greenwichSiderealTime(_ date: Date) -> Double {
        let days = julianDay(date) - 2_451_545
        let t = days / 36525
        return wrapped(280.46061837 + 360.98564736629 * days + 0.000387933 * t * t - t * t * t / 38_710_000)
    }

    /// Mean obliquity of the ecliptic in degrees. Meeus 22.2.
    static func obliquity(_ t: Double) -> Double {
        23.439291111 - 0.0130041667 * t - 1.639e-7 * t * t + 5.036e-7 * t * t * t
    }

    // MARK: - Sun

    /// The sun as a unit vector in the equatorial frame of date (x toward
    /// the equinox, z toward the north celestial pole): apparent position,
    /// aberration and nutation in longitude included. Meeus ch. 25.
    static func sun(_ t: Double) -> SIMD3<Double> {
        let meanLongitude = 280.46646 + 36000.76983 * t + 0.0003032 * t * t
        let anomaly = radians(357.52911 + 35999.05029 * t - 0.0001537 * t * t)
        let centre = (1.914602 - 0.004817 * t - 0.000014 * t * t) * sin(anomaly)
            + (0.019993 - 0.000101 * t) * sin(2 * anomaly)
            + 0.000289 * sin(3 * anomaly)
        let node = radians(125.04 - 1934.136 * t)
        let longitude = meanLongitude + centre - 0.00569 - 0.00478 * sin(node)
        return equatorial(longitude: longitude, latitude: 0, obliquity: obliquity(t) + 0.00256 * cos(node))
    }

    // MARK: - Moon

    struct Moon {
        /// Geocentric ecliptic longitude and latitude, degrees.
        let longitude: Double
        let latitude: Double
        /// Earth centre to moon centre, km.
        let distance: Double
        /// Unit vector in the equatorial frame of date.
        let direction: SIMD3<Double>
    }

    /// The moon from the largest terms of Meeus ch. 47 (tables 47.A and
    /// 47.B down to about 0.002°; the rest add up to well under the stylised
    /// disc's size).
    static func moon(_ t: Double) -> Moon {
        let meanLongitude = 218.3164477 + 481267.88123421 * t - 0.0015786 * t * t
        let elongation = 297.8501921 + 445267.1114034 * t - 0.0018819 * t * t
        let sunAnomaly = 357.5291092 + 35999.0502909 * t - 0.0001536 * t * t
        let moonAnomaly = 134.9633964 + 477198.8675055 * t + 0.0087414 * t * t
        let node = 93.2720950 + 483202.0175233 * t - 0.0036539 * t * t
        // Terms that carry the sun's anomaly shrink with the Earth's
        // orbital eccentricity.
        let eccentricity = 1 - 0.002516 * t - 0.0000074 * t * t

        func argument(_ term: LunarTerm) -> (angle: Double, scale: Double) {
            let angle = radians(term.d * elongation + term.m * sunAnomaly + term.mp * moonAnomaly + term.f * node)
            let scale = abs(term.m) == 1 ? eccentricity : abs(term.m) == 2 ? eccentricity * eccentricity : 1
            return (angle, scale)
        }
        var sumLongitude = 0.0
        var sumDistance = 0.0
        for term in longitudeTerms {
            let (angle, scale) = argument(term)
            sumLongitude += term.sine * scale * sin(angle)
            sumDistance += term.cosine * scale * cos(angle)
        }
        var sumLatitude = 0.0
        for term in latitudeTerms {
            let (angle, scale) = argument(term)
            sumLatitude += term.sine * scale * sin(angle)
        }
        let a1 = radians(119.75 + 131.849 * t)
        let a2 = radians(53.09 + 479264.290 * t)
        let a3 = radians(313.45 + 481266.484 * t)
        let lPrime = radians(meanLongitude)
        let mPrime = radians(moonAnomaly)
        let f = radians(node)
        sumLongitude += 3958 * sin(a1) + 1962 * sin(lPrime - f) + 318 * sin(a2)
        sumLatitude += -2235 * sin(lPrime) + 382 * sin(a3) + 175 * sin(a1 - f) + 175 * sin(a1 + f)
            + 127 * sin(lPrime - mPrime) - 115 * sin(lPrime + mPrime)

        let ascendingNode = radians(125.04 - 1934.136 * t)
        let longitude = wrapped(meanLongitude + sumLongitude / 1_000_000 - 0.00478 * sin(ascendingNode))
        let latitude = sumLatitude / 1_000_000
        return Moon(
            longitude: longitude, latitude: latitude,
            distance: 385_000.56 + sumDistance / 1000,
            direction: equatorial(longitude: longitude, latitude: latitude, obliquity: obliquity(t)))
    }

    // MARK: - Frames

    /// Ecliptic (longitude, latitude in degrees) to an equatorial unit vector.
    static func equatorial(longitude: Double, latitude: Double, obliquity: Double) -> SIMD3<Double> {
        let lambda = radians(longitude), beta = radians(latitude), epsilon = radians(obliquity)
        return SIMD3(
            cos(beta) * cos(lambda),
            cos(beta) * sin(lambda) * cos(epsilon) - sin(beta) * sin(epsilon),
            cos(beta) * sin(lambda) * sin(epsilon) + sin(beta) * cos(epsilon))
    }

    /// Equatorial frame of date → the observer's east, north, up, at local
    /// sidereal time `siderealTime` and `latitude` (degrees).
    static func horizon(siderealTime: Double, latitude: Double) -> simd_double3x3 {
        let theta = radians(siderealTime), phi = radians(latitude)
        return simd_double3x3(rows: [
            SIMD3(-sin(theta), cos(theta), 0),
            SIMD3(-sin(phi) * cos(theta), -sin(phi) * sin(theta), cos(phi)),
            SIMD3(cos(phi) * cos(theta), cos(phi) * sin(theta), sin(phi))
        ])
    }

    /// J2000 equatorial → equatorial of date: the equinox has slid west
    /// along the ecliptic (general precession, about 50″ a year, 0.36° by
    /// 2026), so every star's ecliptic longitude has grown by as much.
    static func precession(_ t: Double) -> simd_double3x3 {
        let slide = (5029.0966 * t + 1.11113 * t * t) / 3600
        let epsilon = obliquity(0)
        func moved(_ v: SIMD3<Double>) -> SIMD3<Double> {
            let longitude = atan2(v.y * cos(radians(epsilon)) + v.z * sin(radians(epsilon)), v.x)
            let latitude = asin(-v.y * sin(radians(epsilon)) + v.z * cos(radians(epsilon)))
            return equatorial(
                longitude: degrees(longitude) + slide, latitude: degrees(latitude), obliquity: epsilon)
        }
        return simd_double3x3(columns: (moved([1, 0, 0]), moved([0, 1, 0]), moved([0, 0, 1])))
    }

    // MARK: - Helpers

    static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

    static func wrapped(_ degrees: Double) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// One row of Meeus tables 47.A/47.B: multiples of D, M, M′, F, and the
    /// sine (longitude or latitude, 1e-6°) and cosine (distance, metres)
    /// coefficients.
    struct LunarTerm {
        let d: Double, m: Double, mp: Double, f: Double, sine: Double, cosine: Double
        init(_ d: Double, _ m: Double, _ mp: Double, _ f: Double, _ sine: Double, _ cosine: Double = 0) {
            (self.d, self.m, self.mp, self.f, self.sine, self.cosine) = (d, m, mp, f, sine, cosine)
        }
    }

    private static let longitudeTerms: [LunarTerm] = [
        LunarTerm(0, 0, 1, 0, 6_288_774, -20_905_355), LunarTerm(2, 0, -1, 0, 1_274_027, -3_699_111),
        LunarTerm(2, 0, 0, 0, 658_314, -2_955_968), LunarTerm(0, 0, 2, 0, 213_618, -569_925),
        LunarTerm(0, 1, 0, 0, -185_116, 48_888), LunarTerm(0, 0, 0, 2, -114_332, -3_149),
        LunarTerm(2, 0, -2, 0, 58_793, 246_158), LunarTerm(2, -1, -1, 0, 57_066, -152_138),
        LunarTerm(2, 0, 1, 0, 53_322, -170_733), LunarTerm(2, -1, 0, 0, 45_758, -204_586),
        LunarTerm(0, 1, -1, 0, -40_923, -129_620), LunarTerm(1, 0, 0, 0, -34_720, 108_743),
        LunarTerm(0, 1, 1, 0, -30_383, 104_755), LunarTerm(2, 0, 0, -2, 15_327, 10_321),
        LunarTerm(0, 0, 1, 2, -12_528), LunarTerm(0, 0, 1, -2, 10_980, 79_661),
        LunarTerm(4, 0, -1, 0, 10_675, -34_782), LunarTerm(0, 0, 3, 0, 10_034, -23_210),
        LunarTerm(4, 0, -2, 0, 8_548, -21_636), LunarTerm(2, 1, -1, 0, -7_888, 24_208),
        LunarTerm(2, 1, 0, 0, -6_766, 30_824), LunarTerm(1, 0, -1, 0, -5_163, -8_379),
        LunarTerm(1, 1, 0, 0, 4_987, -16_675), LunarTerm(2, -1, 1, 0, 4_036, -12_831),
        LunarTerm(2, 0, 2, 0, 3_994, -10_445), LunarTerm(4, 0, 0, 0, 3_861, -11_650),
        LunarTerm(2, 0, -3, 0, 3_665, 14_403), LunarTerm(0, 1, -2, 0, -2_689, -7_003),
        LunarTerm(2, 0, -1, 2, -2_602), LunarTerm(2, -1, -2, 0, 2_390, 10_056),
        LunarTerm(1, 0, 1, 0, -2_348, 6_322), LunarTerm(2, -2, 0, 0, 2_236, -9_884)
    ]

    private static let latitudeTerms: [LunarTerm] = [
        LunarTerm(0, 0, 0, 1, 5_128_122), LunarTerm(0, 0, 1, 1, 280_602), LunarTerm(0, 0, 1, -1, 277_693),
        LunarTerm(2, 0, 0, -1, 173_237), LunarTerm(2, 0, -1, 1, 55_413), LunarTerm(2, 0, -1, -1, 46_271),
        LunarTerm(2, 0, 0, 1, 32_573), LunarTerm(0, 0, 2, 1, 17_198), LunarTerm(2, 0, 1, -1, 9_266),
        LunarTerm(0, 0, 2, -1, 8_822), LunarTerm(2, -1, 0, -1, 8_216), LunarTerm(2, 0, -2, -1, 4_324),
        LunarTerm(2, 0, 1, 1, 4_200), LunarTerm(2, 1, 0, -1, -3_359), LunarTerm(2, -1, -1, 1, 2_463),
        LunarTerm(2, -1, 0, 1, 2_211), LunarTerm(2, -1, -1, -1, 2_065), LunarTerm(0, 1, -1, -1, -1_870),
        LunarTerm(4, 0, -1, -1, 1_828), LunarTerm(0, 1, 0, 1, -1_794)
    ]
}
