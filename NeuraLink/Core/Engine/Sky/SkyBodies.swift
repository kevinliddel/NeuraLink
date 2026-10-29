//
//  SkyBodies.swift
//  NeuraLink
//
//  The sun, the moon and the stars where they stand for one place at one
//  instant, in the scene's own axes (+Y up, the camera on +Z).
//
//  The compass is chosen, not fixed: the camera looks toward the day's
//  sunset, so the sun goes down beside the avatar every evening, in view,
//  and the moons that set in the west (crescent to first quarter in the
//  evening, full at dawn) go down there too. The compass turns with the
//  sun's declination, under half a degree a day. It is only ever a turn
//  about the vertical, never a mirror: the sun still rises in the east.
//  The avatar's own light is kept on the camera's side (`SkyKeyLight`).
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

    /// How far from straight ahead (degrees) the sunset point is put, to the
    /// equator's side: right of the camera in the south, left in the north.
    /// The setting sun comes down from that side, and straight ahead is
    /// where the avatar stands; at 10° it sets clear of her, inside even a
    /// portrait phone's view (about ±15°).
    static let sunsetBearing: Double = 10

    /// The scene's east and north for an observer at `latitude` (degrees) on
    /// a day the sun's declination is `sunDeclination`: turned so the point
    /// where the sun sets lies `sunsetBearing` off straight ahead (−Z).
    static func compass(latitude: Double, sunDeclination: Double) -> (east: SIMD3<Double>, north: SIMD3<Double>) {
        // The sunset point in (east, north): where the sun's daily circle
        // meets the horizon going down. Due north or south when it never
        // sets or never rises (the polar day and night).
        let sunsetNorth = min(1, max(-1,
            sin(SkyEphemeris.radians(sunDeclination)) / cos(SkyEphemeris.radians(latitude))))
        let sunsetEast = -(1 - sunsetNorth * sunsetNorth).squareRoot()
        // Facing the sunset, north is on the right.
        let side = SkyEphemeris.radians(latitude < 0 ? sunsetBearing : -sunsetBearing)
        let (aheadX, aheadZ) = (sin(side), -cos(side))
        // East and north such that sunsetEast·east + sunsetNorth·north lies
        // ahead, with north = up × east (a turn about +Y, not a mirror).
        let east = SIMD3<Double>(
            sunsetEast * aheadX - sunsetNorth * aheadZ, 0, sunsetNorth * aheadX + sunsetEast * aheadZ)
        return (east, [east.z, 0, -east.x])
    }

    init(at date: Date, location: SkyLocation) {
        let t = SkyEphemeris.centuries(date)
        let localSiderealTime = SkyEphemeris.greenwichSiderealTime(date) + location.longitude
        let sun = SkyEphemeris.sun(t)
        let moon = SkyEphemeris.moon(t)
        let (east, north) = Self.compass(
            latitude: location.latitude, sunDeclination: SkyEphemeris.degrees(asin(sun.z)))
        let scene = simd_double3x3(columns: (east, north, [0, 1, 0]))
            * SkyEphemeris.horizon(siderealTime: localSiderealTime, latitude: location.latitude)

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
