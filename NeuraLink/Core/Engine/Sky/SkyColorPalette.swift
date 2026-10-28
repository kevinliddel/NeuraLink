//
//  SkyColorPalette.swift
//  NeuraLink
//
//  Created by Dedicatus on 17/04/2026.
//

import Foundation
import simd

/// Full sky and lighting state for one place at one instant.
struct SkyEnvironment {

    // MARK: - Sky

    /// Unit vector pointing FROM the scene TOWARD the sun (below the horizon at night).
    let sunDirection: SIMD3<Float>

    /// Colour of the sun's disc in the sky: its light after the air it
    /// crosses (`SkyAtmosphere.lightColor`). Not the key light's colour,
    /// which is the moon's at night.
    let sunColor: SIMD3<Float>

    /// Unit vector FROM the scene TOWARD the moon.
    let moonDirection: SIMD3<Float>

    /// Lit fraction of the moon's disc [0, 1].
    let moonIllumination: Float

    /// Moonlight against a full moon's [0, 1].
    let moonBrightness: Float

    /// Star catalogue (J2000 equatorial) → scene: see `SkyBodies`.
    let starRotation: simd_float3x3

    /// [0,1] cloud coverage fraction.
    let cloudCoverage: Float

    /// Cloud layer horizontal scroll speed (UV units/s).
    let cloudSpeed: Float

    /// Normalised star field brightness [0,1]: 0 = day, 1 = full night sky.
    let starVisibility: Float

    /// The night's own glow (airglow and starlight) at the horizon, already
    /// weighted by how dark it is: nothing by day, coming in under
    /// twilight. The atmosphere itself is the GPU's (`SkyAtmosphere`).
    let nightGlowLow: SIMD3<Float>

    /// The night's own glow at the zenith, weighted the same.
    let nightGlowHigh: SIMD3<Float>

    // MARK: - VRM Lighting

    /// The one light the ground, the environment and every shadow on them
    /// follow, and the avatar too, turned to the camera's side — see
    /// `SkyKeyLight`.
    let keyLight: SkyKeyLight

    let fillLightDirection: SIMD3<Float>
    let fillLightColor: SIMD3<Float>
    let fillLightIntensity: Float

    let rimLightDirection: SIMD3<Float>
    let rimLightColor: SIMD3<Float>
    let rimLightIntensity: Float

    let ambientColor: SIMD3<Float>
}

/// The scene's key light: the sun by day, the moon (or the night sky above)
/// by night.
///
/// It used to jump straight to the opposite horizon the instant the sun
/// crossed it, in four places at once, so the avatar's lit side, its
/// self-shadow and every ground shadow swung across in one frame at dawn and
/// dusk. Now there is one light, and through twilight it travels from the
/// sun to the night light OVER the sky: the shadows shorten and turn instead
/// of flipping.
struct SkyKeyLight {
    /// Unit vector FROM the scene TOWARD the light. Never lower than
    /// `minimumElevation`: a light on the horizon throws endless shadows.
    let direction: SIMD3<Float>
    let color: SIMD3<Float>
    let intensity: Float
    /// Shadow-filter width the terrain and environment shaders take.
    let shadowSoftness: Float

    /// sin(≈7°).
    static let minimumElevation: Float = 0.12

    /// `direction` as the avatar takes it: turned onto the camera's side
    /// (+Z) when the light stands behind her, so her face stays lit while
    /// the sun goes down behind her, in view. The real light then rims her
    /// (`SkyEnvironment.rimLightDirection`), and her shadow on the ground
    /// still falls from it, toward the camera. A mirror in the camera's
    /// plane, so it moves as smoothly as `direction` does.
    var avatarDirection: SIMD3<Float> { SIMD3<Float>(direction.x, direction.y, abs(direction.z)) }

    /// Where the night light comes from when the moon is down: high and a
    /// little in front, so a face still reads.
    static let nightSkyDirection = simd_normalize(SIMD3<Float>(0.25, 0.9, 0.35))

    /// Blends the sun's light into the night's as the sun goes down.
    /// `dayFactor` keeps today's colour and intensity curve; the direction
    /// changes hands between −6° and +5° of solar elevation.
    static func resolve(
        sun: SIMD3<Float>, sunColor: SIMD3<Float>, moon: SIMD3<Float>, moonIllumination: Float,
        moonBrightness: Float, dayFactor: Float
    ) -> SkyKeyLight {
        let moonColor = SIMD3<Float>(0.55, 0.60, 0.85)  // cool blue moonlight
        let sunIntensity: Float = 0.30 + dayFactor * 0.90

        // At night: the moon while it is up and more than a crescent, the
        // sky above otherwise. A full moon lights the avatar a little more
        // than a moonless sky; neither drops below a level a face reads at.
        let moonRisen = skySmooth(-0.05, 0.15, moon.y)
        let moonUp = moonRisen * min(1, moonIllumination * 2)
        let night = simd_normalize(simd_mix(nightSkyDirection, raised(moon), SIMD3<Float>(repeating: moonUp)))
        let moonIntensity: Float = 0.42 + 0.16 * moonRisen * moonBrightness

        // Sun → night over the top. The lift term keeps the path in the
        // upper sky even when the two lights sit on opposite horizons, where
        // a plain mix would pass through zero length.
        let toSun = skySmooth(-0.10, 0.08, sun.y)
        let lift = SIMD3<Float>(0, 0.6 * sin(Float.pi * toSun), 0)
        let direction = simd_normalize(
            simd_mix(night, raised(sun), SIMD3<Float>(repeating: toSun)) + lift)

        return SkyKeyLight(
            direction: direction,
            color: skyLerp(moonColor, sunColor, dayFactor),
            intensity: moonIntensity + (sunIntensity - moonIntensity) * dayFactor,
            shadowSoftness: 1.5 + toSun * 1.0)
    }

    /// `direction` lifted to at least `minimumElevation`, keeping its azimuth.
    private static func raised(_ direction: SIMD3<Float>) -> SIMD3<Float> {
        guard direction.y < minimumElevation else { return direction }
        let horizontal = SIMD2<Float>(direction.x, direction.z)
        let length = simd_length(horizontal)
        guard length > 1e-4 else { return SIMD3<Float>(0, 1, 0) }
        let scale = sqrt(1 - minimumElevation * minimumElevation) / length
        return SIMD3<Float>(horizontal.x * scale, minimumElevation, horizontal.y * scale)
    }
}

// MARK: - Factory

extension SkyEnvironment {

    /// The sky over `location` at `date`.
    static func resolve(at date: Date, location: SkyLocation) -> SkyEnvironment {
        resolve(SkyBodies(at: date, location: location))
    }

    /// Colours and lights for wherever the sun and moon stand. The palette
    /// keys on the sun's elevation alone.
    static func resolve(_ bodies: SkyBodies) -> SkyEnvironment {
        let sunDir = bodies.sunDirection
        let moonDir = bodies.moonDirection

        // dayFactor: 0 when sun is well below horizon, 1 at full day.
        // Transition starts slightly below horizon so dusk/dawn looks natural.
        let dayFactor = skySmooth(-0.15, 0.20, sunDir.y)
        let sunsetFactor =
            min(1.0, max(0.0, 1.0 - abs(sunDir.y) * 3.5))
            * (sunDir.y > -0.1 ? 1.0 : 0.0)

        // The sun's colour after the air it crosses: white-gold high, orange
        // low, red on the horizon. The key light takes it where the key
        // stands, never lower than its floor.
        let sunElevation = asin(min(1, max(-1, sunDir.y)))
        let sunColor = SkyAtmosphere.lightColor(elevation: sunElevation)
        let keyLight = SkyKeyLight.resolve(
            sun: sunDir,
            sunColor: SkyAtmosphere.lightColor(elevation: max(sunElevation, asin(SkyKeyLight.minimumElevation))),
            moon: moonDir, moonIllumination: bodies.moonIllumination,
            moonBrightness: bodies.moonBrightness, dayFactor: dayFactor)

        // Fill light: soft sky-blue from the opposite side of the sun.
        let fillDir = simd_normalize(
            SIMD3<Float>(-sunDir.x * 0.6, 0.5, 0.8)
        )
        let fillColor = skyLerp(
            SIMD3<Float>(0.25, 0.28, 0.45),  // night: dim cool blue
            SIMD3<Float>(0.45, 0.60, 0.85),  // day: sky blue
            dayFactor
        )
        let fillIntensity: Float = 0.20 + dayFactor * 0.18

        // Rim light: from above-behind, to separate the model from the sky.
        // While the key light stands behind the avatar (the sun going down
        // in view) it is that light, in its colour, a little stronger. Kept
        // modest: MToon shares its lights out, so a strong back light would
        // take the face's.
        let behind = skySmooth(0.0, 0.5, -keyLight.direction.z)
        let rimDir = simd_normalize(simd_mix(
            simd_normalize(SIMD3<Float>(0.0, 0.3, -1.0)), keyLight.direction, SIMD3<Float>(repeating: behind)))
        let rimColor = skyLerp(SIMD3<Float>(0.85, 0.90, 1.00), keyLight.color, behind)
        let rimIntensity: Float = 0.12 + dayFactor * 0.12 + behind * 0.12

        // The night's own glow, today's night palette: it comes in as the
        // twilight the atmosphere draws fades, from the sun 1° down to 9°.
        let nightWeight = skySmooth(-0.02, -0.16, sunDir.y)
        let nightLow = SIMD3<Float>(0.051, 0.075, 0.129)  // 0x0d1321 dark sky
        let nightHigh = SIMD3<Float>(0.110, 0.137, 0.192)  // 0x1c2331 night sky

        // Scene ambient — never drops below a moonlit floor so the model stays readable.
        let nightAmbient = SIMD3<Float>(0.13, 0.13, 0.20)
        let dawnAmbient = SIMD3<Float>(0.10, 0.08, 0.11)
        let noonAmbient = SIMD3<Float>(0.18, 0.18, 0.18)
        let dayAmbient = skyLerp(dawnAmbient, noonAmbient, dayFactor * (1.0 - sunsetFactor * 0.5))
        let ambient = skyLerp(nightAmbient, dayAmbient, dayFactor)

        return SkyEnvironment(
            sunDirection: sunDir,
            sunColor: sunColor,
            moonDirection: moonDir,
            moonIllumination: bodies.moonIllumination,
            moonBrightness: bodies.moonBrightness,
            starRotation: bodies.starRotation,
            cloudCoverage: 0.50 + sunsetFactor * 0.10,
            cloudSpeed: 0.008 + dayFactor * 0.018,
            starVisibility: min(1.0, max(0.0, -sunDir.y * 2.8)),
            nightGlowLow: nightLow * nightWeight,
            nightGlowHigh: nightHigh * nightWeight,
            keyLight: keyLight,
            fillLightDirection: fillDir,
            fillLightColor: fillColor,
            fillLightIntensity: fillIntensity,
            rimLightDirection: rimDir,
            rimLightColor: rimColor,
            rimLightIntensity: rimIntensity,
            ambientColor: ambient
        )
    }
}

// MARK: - Private helpers

private func skySmooth(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    let t = min(1.0, max(0.0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3.0 - 2.0 * t)
}

private func skyLerp(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
    a + (b - a) * t
}
