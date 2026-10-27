//
//  SkyColorPalette.swift
//  NeuraLink
//
//  Created by Dedicatus on 17/04/2026.
//

import simd

/// Full sky and lighting state derived from the current local hour.
struct SkyEnvironment {

    // MARK: - Sky

    /// Unit vector pointing FROM the scene TOWARD the sun (below the horizon at night).
    let sunDirection: SIMD3<Float>

    /// Colour of the sun's disc in the sky. Not the key light's colour,
    /// which is the moon's at night.
    let sunColor: SIMD3<Float>

    /// Unit vector FROM the scene TOWARD the moon.
    let moonDirection: SIMD3<Float>

    /// Lit fraction of the moon's disc [0, 1].
    let moonIllumination: Float

    /// [0,1] cloud coverage fraction.
    let cloudCoverage: Float

    /// Cloud layer horizontal scroll speed (UV units/s).
    let cloudSpeed: Float

    /// Atmospheric turbidity [2,10]: 2 = crystal clear, 10 = hazy.
    let turbidity: Float

    /// Normalised star field brightness [0,1]: 0 = day, 1 = full night sky.
    let starVisibility: Float

    /// Sky gradient bottom colour (horizon level).
    let skyColorLow: SIMD3<Float>

    /// Sky gradient top colour (zenith level).
    let skyColorHigh: SIMD3<Float>

    // MARK: - VRM Lighting

    /// The one light the avatar, its self-shadow and every ground shadow
    /// follow — see `SkyKeyLight`.
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

    /// Where the night light comes from when the moon is down: high and a
    /// little in front, so a face still reads.
    static let nightSkyDirection = simd_normalize(SIMD3<Float>(0.25, 0.9, 0.35))

    /// Blends the sun's light into the night's as the sun goes down.
    /// `dayFactor` keeps today's colour and intensity curve; the direction
    /// changes hands between −6° and +5° of solar elevation.
    static func resolve(
        sun: SIMD3<Float>, sunColor: SIMD3<Float>, moon: SIMD3<Float>, moonIllumination: Float,
        dayFactor: Float
    ) -> SkyKeyLight {
        let moonColor = SIMD3<Float>(0.55, 0.60, 0.85)  // cool blue moonlight
        let moonIntensity: Float = 0.50
        let sunIntensity: Float = 0.30 + dayFactor * 0.90

        // At night: the moon while it is up, the sky above otherwise.
        let moonUp = skySmooth(-0.05, 0.15, moon.y) * min(1, moonIllumination * 2)
        let night = simd_normalize(simd_mix(nightSkyDirection, raised(moon), SIMD3<Float>(repeating: moonUp)))

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

    /// Computes the full sky and lighting environment from the given local hour [0, 24).
    static func resolve(hour: Float) -> SkyEnvironment {
        let h = (hour.truncatingRemainder(dividingBy: 24) + 24)
            .truncatingRemainder(dividingBy: 24)

        // Hour angle relative to noon: 0 at noon, ±π at midnight.
        // Sun sweeps east (+X) → overhead (+Y) → west (−X) → underground.
        let angle = (h - 12.0) * .pi / 12.0

        // Unit sun direction: already normalised because sin²+cos²=1.
        let sunDir = SIMD3<Float>(-sin(angle), cos(angle), 0.0)

        // dayFactor: 0 when sun is well below horizon, 1 at full day.
        // Transition starts slightly below horizon so dusk/dawn looks natural.
        let dayFactor = skySmooth(-0.15, 0.20, sunDir.y)
        let sunsetFactor =
            min(1.0, max(0.0, 1.0 - abs(sunDir.y) * 3.5))
            * (sunDir.y > -0.1 ? 1.0 : 0.0)

        // The moon stays the sun's mirror, always full, until it has an
        // orbit of its own.
        let moonDir = -sunDir
        let moonIllumination: Float = 1

        // Sun colour — orange at the horizon, white as it rises.
        let noonColor = SIMD3<Float>(1.00, 0.96, 0.86)
        let horizonColor = SIMD3<Float>(1.00, 0.52, 0.10)
        let sunColor = skyLerp(horizonColor, noonColor, dayFactor * (1.0 - sunsetFactor * 0.8))
        let keyLight = SkyKeyLight.resolve(
            sun: sunDir, sunColor: sunColor, moon: moonDir, moonIllumination: moonIllumination,
            dayFactor: dayFactor)

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

        // Rim light: fixed, comes from above-behind to separate model from sky.
        let rimDir = simd_normalize(SIMD3<Float>(0.0, 0.3, -1.0))
        let rimColor = SIMD3<Float>(0.85, 0.90, 1.00)
        let rimIntensity: Float = 0.12 + dayFactor * 0.12

        // Sky gradient colours — simple palette keyed on sun elevation.
        let tDawn = skySmooth(-0.12, -0.02, sunDir.y)  // 0=deep night → 1=just below horizon
        let tDay = skySmooth(-0.02, 0.20, sunDir.y)  // 0=near horizon → 1=full daytime

        let nightLow = SIMD3<Float>(0.051, 0.075, 0.129)  // 0x0d1321 dark sky
        let nightHigh = SIMD3<Float>(0.110, 0.137, 0.192)  // 0x1c2331 night sky
        let horizonLow = SIMD3<Float>(1.000, 0.784, 0.196)  // warm golden yellow at sunrise
        let horizonHigh = SIMD3<Float>(0.600, 0.400, 0.647)  // soft rose / purple
        let dayLow = SIMD3<Float>(0.529, 0.808, 0.922)  // 0x87ceeb sky blue
        let dayHigh = SIMD3<Float>(0.149, 0.302, 0.600)  // deep blue zenith

        var gradLow = skyLerp(nightLow, horizonLow, tDawn)
        gradLow = skyLerp(gradLow, dayLow, tDay)
        var gradHigh = skyLerp(nightHigh, horizonHigh, tDawn)
        gradHigh = skyLerp(gradHigh, dayHigh, tDay)

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
            moonIllumination: moonIllumination,
            cloudCoverage: 0.50 + sunsetFactor * 0.10,
            cloudSpeed: 0.008 + dayFactor * 0.018,
            turbidity: 2.0 + sunsetFactor * 5.0,
            starVisibility: min(1.0, max(0.0, -sunDir.y * 2.8)),
            skyColorLow: gradLow,
            skyColorHigh: gradHigh,
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
