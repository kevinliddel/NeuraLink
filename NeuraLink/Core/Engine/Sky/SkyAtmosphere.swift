//
//  SkyAtmosphere.swift
//  NeuraLink
//
//  The Earth's clear atmosphere, as Hillaire models it ("A Scalable and
//  Production Ready Sky and Atmosphere Rendering Technique", 2020):
//  Rayleigh scattering by the air, Mie scattering and absorption by fine
//  aerosols, and absorption by the ozone layer, each thinning with height.
//  Distances are in km, coefficients per km.
//
//  The GPU draws the sky from it (SkyAtmosphere.metal, three lookup tables).
//  The CPU keeps what it needs from the same model: the colour sunlight has
//  after its way through the air, and how bright the sky is where the eye
//  adapts to it through the day and twilight.
//
//  Created by Dedicatus on 28/10/2026.
//

import Foundation
import simd

/// The atmosphere as the GPU reads it. Matches `SkyAtmosphereParams` in
/// SkyAtmosphereCommon.metal: 6 × 16 = 96 bytes.
struct SkyAtmosphereParams {
    /// rgb = Rayleigh scattering, w = its scale height.
    var rayleigh: SIMD4<Float>
    /// rgb = Mie scattering, w = its scale height.
    var mieScattering: SIMD4<Float>
    /// rgb = Mie extinction, w = the Mie phase asymmetry g.
    var mieExtinction: SIMD4<Float>
    /// rgb = ozone absorption, w = the height of the ozone layer's peak.
    var ozone: SIMD4<Float>
    /// rgb = ground albedo, w = the ozone layer's half width.
    var groundAlbedo: SIMD4<Float>
    /// x = ground radius, y = top of the atmosphere, z = the camera's height
    /// above the ground, w unused.
    var radii: SIMD4<Float>
}

/// What one sky-view update lights the sky with. Matches `SkyViewParams` in
/// SkyAtmosphereCommon.metal.
struct SkyViewParams {
    /// xyz = toward the sun, w = its light, exposure folded in.
    var sun: SIMD4<Float>
    /// xyz = toward the moon, w = its light, exposure folded in.
    var moon: SIMD4<Float>
}

nonisolated enum SkyAtmosphere {

    static let groundRadius: Float = 6_360
    static let topRadius: Float = 6_460
    /// Where the sky is seen from: a little above the ground, so a ray just
    /// below the horizon still runs some way through the air.
    static let cameraHeight: Float = 0.2

    static let rayleighScattering = SIMD3<Float>(5.802, 13.558, 33.1) * 1e-3
    static let rayleighScaleHeight: Float = 8
    static let mieScattering: Float = 3.996e-3
    static let mieExtinction: Float = 4.40e-3
    static let mieScaleHeight: Float = 1.2
    /// Mie scattering's forward peak: the bright glow around the sun.
    static let mieAsymmetry: Float = 0.8
    static let ozoneAbsorption = SIMD3<Float>(0.650, 1.881, 0.085) * 1e-3
    /// A tent-shaped layer, densest 25 km up and gone 15 km either side.
    static let ozoneCentre: Float = 25
    static let ozoneHalfWidth: Float = 15
    static let groundAlbedo: Float = 0.3

    static let gpuParams = SkyAtmosphereParams(
        rayleigh: SIMD4<Float>(rayleighScattering, rayleighScaleHeight),
        mieScattering: SIMD4<Float>(SIMD3<Float>(repeating: mieScattering), mieScaleHeight),
        mieExtinction: SIMD4<Float>(SIMD3<Float>(repeating: mieExtinction), mieAsymmetry),
        ozone: SIMD4<Float>(ozoneAbsorption, ozoneCentre),
        groundAlbedo: SIMD4<Float>(SIMD3<Float>(repeating: groundAlbedo), ozoneHalfWidth),
        radii: SIMD4<Float>(groundRadius, topRadius, cameraHeight, 0))

    // MARK: - The medium

    /// Scattering and extinction `height` km above the ground.
    static func medium(atHeight height: Float) -> (rayleigh: SIMD3<Float>, mie: Float, extinction: SIMD3<Float>) {
        let rayleigh = rayleighScattering * exp(-height / rayleighScaleHeight)
        let mieDensity = exp(-height / mieScaleHeight)
        let ozone = max(0, 1 - abs(height - ozoneCentre) / ozoneHalfWidth)
        return (rayleigh, mieScattering * mieDensity,
                rayleigh + SIMD3<Float>(repeating: mieExtinction * mieDensity) + ozoneAbsorption * ozone)
    }

    // MARK: - Light through the air

    /// The fraction of light from `elevation` (radians) that reaches a point
    /// `height` km up, per channel. Zero once the ray meets the Earth.
    static func transmittance(elevation: Float, fromHeight height: Float = cameraHeight) -> SIMD3<Float> {
        let start = SIMD3<Float>(0, groundRadius + height, 0)
        let direction = SIMD3<Float>(cos(elevation), sin(elevation), 0)
        if hitsGround(from: start, toward: direction) { return .zero }
        let length = distanceToTop(from: start, toward: direction)
        // Squared spacing: dense near the start, where the air is.
        let steps = 64
        var depth = SIMD3<Float>.zero
        var previous: Float = 0
        for step in 1...steps {
            let next = length * pow(Float(step) / Float(steps), 2)
            let point = start + direction * ((previous + next) / 2)
            depth += medium(atHeight: simd_length(point) - groundRadius).extinction * (next - previous)
            previous = next
        }
        return exp(-depth)
    }

    /// The colour of light from `elevation` as it reaches the ground: the
    /// transmittance, its brightest channel 1. White-gold overhead, orange
    /// low, red on the horizon. Below the horizon, the horizon's.
    static func lightColor(elevation: Float) -> SIMD3<Float> {
        let light = transmittance(elevation: max(elevation, 0))
        return light / max(simd_reduce_max(light), 1e-6)
    }

    // MARK: - The eye

    /// The sky's luminance along `view` with the sun `sunElevation` radians
    /// up toward +X, against the sun's light above the air: single
    /// scattering, enough to follow how the sky's brightness moves through
    /// the day and twilight.
    static func skyLuminance(toward view: SIMD3<Float>, sunElevation: Float) -> Float {
        let sun = SIMD3<Float>(cos(sunElevation), sin(sunElevation), 0)
        let cosine = simd_dot(view, sun)
        let rayleighPhase = 3 / (16 * Float.pi) * (1 + cosine * cosine)
        let g = mieAsymmetry
        let miePhase = 3 / (8 * Float.pi) * (1 - g * g) * (1 + cosine * cosine)
            / ((2 + g * g) * pow(1 + g * g - 2 * g * cosine, 1.5))
        let start = SIMD3<Float>(0, groundRadius + cameraHeight, 0)
        let length = distanceToTop(from: start, toward: view)
        let steps = 48
        var luminance = SIMD3<Float>.zero
        var throughput = SIMD3<Float>(repeating: 1)
        var previous: Float = 0
        for step in 1...steps {
            let next = length * pow(Float(step) / Float(steps), 2)
            let point = start + view * ((previous + next) / 2)
            let air = medium(atHeight: simd_length(point) - groundRadius)
            let sunlight = hitsGround(from: point, toward: sun)
                ? .zero : transmittanceAlong(from: point, toward: sun)
            let scattered = sunlight * (air.rayleigh * rayleighPhase + SIMD3<Float>(repeating: air.mie * miePhase))
            let stepTransmittance = exp(-air.extinction * (next - previous))
            luminance += throughput * scattered * (1 - stepTransmittance) / air.extinction
            throughput *= stepTransmittance
            previous = next
        }
        return simd_dot(luminance, SIMD3<Float>(0.2126, 0.7152, 0.0722))
    }

    /// The sky the eye adapts to: the glow low on the horizon toward the
    /// sun, plus the sky overhead. Their sum holds nearly steady from
    /// mid-morning to noon. Through twilight the glow fades far more slowly
    /// than the zenith does, so it stays where the sun went down while the
    /// sky above deepens.
    static func adaptingLuminance(sunElevation: Float) -> Float {
        let low: Float = 3 * .pi / 180
        return skyLuminance(toward: SIMD3<Float>(cos(low), sin(low), 0), sunElevation: sunElevation)
            + 8 * skyLuminance(toward: SIMD3<Float>(0, 1, 0), sunElevation: sunElevation)
    }

    /// How much the sky is brightened to be seen: more as it darkens, as an
    /// eye adapts, but only by `adaptation` of the drop, so twilight still
    /// deepens. 1 at the reference sun (30° up) and near it to noon; a
    /// little under around sunrise and sunset, when the glow around the low
    /// sun is brightest.
    static func exposure(sunElevation: Float) -> Float {
        let luminance = max(adaptingLuminance(sunElevation: sunElevation), referenceLuminance * darkestAdapted)
        return pow(referenceLuminance / luminance, adaptation)
    }

    /// The share of a darkening the eye makes up for.
    static let adaptation: Float = 0.8
    /// Below this fraction of the reference, the eye adapts no more: the
    /// last of the twilight fades into the night's own glow.
    static let darkestAdapted: Float = 3e-4
    static let referenceLuminance = adaptingLuminance(sunElevation: 30 * .pi / 180)

    // MARK: - Geometry

    private static func hitsGround(from point: SIMD3<Float>, toward direction: SIMD3<Float>) -> Bool {
        // A hair inside the ground, so a point on it doesn't shadow itself.
        let radius = groundRadius - 0.01
        let b = simd_dot(point, direction)
        let c = simd_length_squared(point) - radius * radius
        return b < 0 && b * b - c >= 0
    }

    private static func distanceToTop(from point: SIMD3<Float>, toward direction: SIMD3<Float>) -> Float {
        let b = simd_dot(point, direction)
        let c = simd_length_squared(point) - topRadius * topRadius
        return -b + (b * b - c).squareRoot()
    }

    /// Transmittance from `point` to space along `direction` (no ground test).
    private static func transmittanceAlong(from point: SIMD3<Float>, toward direction: SIMD3<Float>) -> SIMD3<Float> {
        let length = distanceToTop(from: point, toward: direction)
        let steps = 24
        var depth = SIMD3<Float>.zero
        var previous: Float = 0
        for step in 1...steps {
            let next = length * pow(Float(step) / Float(steps), 2)
            let sample = point + direction * ((previous + next) / 2)
            depth += medium(atHeight: simd_length(sample) - groundRadius).extinction * (next - previous)
            previous = next
        }
        return exp(-depth)
    }
}
