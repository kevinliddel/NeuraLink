//
//  SkyBodies.swift
//  NeuraLink
//
//  The sun, the moon and the stars where they stand for one place at one
//  instant, in the scene's own axes (+Y up, the camera on +Z).
//
//  The compass is chosen, not fixed: the noon sun always stands on the
//  camera's side, so the avatar is lit from the front through the middle of
//  the day. That puts north at +Z in the southern hemisphere (Madagascar's
//  noon sun is in the north) and south at +Z in the northern. Either way the
//  sun still rises in the east and sets in the west: the two layouts are
//  one turned 180° about the vertical, not mirrored.
//
//  Created by Dedicatus on 27/10/2026.
//

import Foundation
import simd

nonisolated struct SkyBodies {

    /// Unit vector FROM the scene TOWARD the sun.
    let sunDirection: SIMD3<Float>

    /// Unit vector FROM the scene TOWARD the moon, as seen from the
    /// Earth's surface (the moon is close enough to sit up to 1° lower than
    /// from the Earth's centre).
    let moonDirection: SIMD3<Float>

    /// Lit fraction of the moon's disc [0, 1].
    let moonIllumination: Float

    /// Moonlight against a full moon's [0, 1]. It falls much faster than the
    /// lit fraction: a quarter moon gives about a tenth.
    let moonBrightness: Float

    /// Turns the catalogue's star directions (J2000 equatorial) into the
    /// scene's: precession to date, sidereal time, latitude and the compass.
    let starRotation: simd_float3x3

    /// The scene's east and north for an observer at `latitude`.
    static func compass(latitude: Double) -> (east: SIMD3<Double>, north: SIMD3<Double>) {
        latitude < 0 ? ([-1, 0, 0], [0, 0, 1]) : ([1, 0, 0], [0, 0, -1])
    }

    init(at date: Date, location: SkyLocation) {
        let t = SkyEphemeris.centuries(date)
        let localSiderealTime = SkyEphemeris.greenwichSiderealTime(date) + location.longitude
        let (east, north) = Self.compass(latitude: location.latitude)
        let scene = simd_double3x3(columns: (east, north, [0, 1, 0]))
            * SkyEphemeris.horizon(siderealTime: localSiderealTime, latitude: location.latitude)

        let sun = SkyEphemeris.sun(t)
        let moon = SkyEphemeris.moon(t)
        sunDirection = SIMD3<Float>(simd_normalize(scene * sun))
        // Seen from the surface, one Earth radius up, not the centre.
        let earthRadii = moon.distance / 6378.14
        moonDirection = SIMD3<Float>(simd_normalize(scene * moon.direction * earthRadii - [0, 1, 0]))

        // The phase angle (sun–moon–Earth) is, near enough, 180° less the
        // elongation (sun–Earth–moon): the sun is 400 times farther.
        let cosElongation = min(1, max(-1, simd_dot(sun, moon.direction)))
        moonIllumination = Float((1 - cosElongation) / 2)
        let phaseAngle = 180 - SkyEphemeris.degrees(acos(cosElongation))
        // Lunar magnitude against full (Allen): the moon dims far faster
        // than it narrows, its rough surface shadowing itself.
        let dimming = 0.026 * phaseAngle + 4e-9 * pow(phaseAngle, 4)
        moonBrightness = Float(pow(10, -0.4 * dimming))

        let stars = scene * SkyEphemeris.precession(t)
        starRotation = simd_float3x3(
            SIMD3<Float>(stars.columns.0), SIMD3<Float>(stars.columns.1), SIMD3<Float>(stars.columns.2))
    }
}
