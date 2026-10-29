//
//  SkyAmbient.swift
//  NeuraLink
//
//  The light the sky casts on whatever stands under it, as MToon's GI takes
//  it: a mean and how it changes along each world axis,
//  GI(n) = mean + x·n.x + y·n.y + z·n.z, per channel. That is L1 spherical
//  harmonics convolved with the cosine, the spec's SH probe at its lowest
//  order. The GPU sums the sky as shown into it whenever the sky view is lit
//  again (sky_ambient_sh); the ground under it, lit by that sky and the sun,
//  is added here.
//
//  Created by Dedicatus on 28/10/2026.
//

import simd

/// The night's glow the GPU sum adds over the sky view, as the sky shader
/// does. Matches `SkyAmbientParams` in SkyAtmosphereCommon.metal.
struct SkyAmbientParams {
    var glowLow: SIMD4<Float>
    var glowHigh: SIMD4<Float>
}

nonisolated struct SkyAmbient: Equatable {
    /// The light averaged over every direction: what a surface takes from
    /// all round, and what MToon's `giEqualizationFactor` evens toward.
    var mean: SIMD3<Float>
    /// How the light changes along +X, +Y and +Z, per channel.
    var x: SIMD3<Float>
    var y: SIMD3<Float>
    var z: SIMD3<Float>

    /// The hemisphere that stood in before there was a sky to read: one
    /// colour, `hemisphere` brighter from straight above and as much darker
    /// from below.
    static func hemisphere(_ color: SIMD3<Float>, hemisphere: Float = 0.35) -> SkyAmbient {
        SkyAmbient(mean: color, x: .zero, y: color * hemisphere, z: .zero)
    }

    /// The light a surface facing `normal` (unit length) gathers.
    func along(_ normal: SIMD3<Float>) -> SIMD3<Float> {
        simd_max(mean + x * normal.x + y * normal.y + z * normal.z, .zero)
    }

    /// The GPU's sum over the sky (the upper hemisphere; `mean`, then
    /// along x, y and z) with the ground under it: a flat plane of `albedo`
    /// lit by that sky and by `sunlight`, the sun's light on it in the same
    /// units (zero once it has set).
    init(sky: [SIMD4<Float>], albedo: SIMD3<Float>, sunlight: SIMD3<Float>) {
        func rgb(_ i: Int) -> SIMD3<Float> {
            i < sky.count ? SIMD3<Float>(sky[i].x, sky[i].y, sky[i].z) : .zero
        }
        let skyMean = rgb(0), skyY = rgb(2)
        // What the sky gives a level surface, over π: 2 × its gradient
        // along +Y (∫ L ω_y dω = 2π·y). The ground sends back `albedo` of it,
        // the same from every point below the horizon. A uniform lower
        // hemisphere adds half itself to the mean and takes half itself
        // off the gradient along +Y.
        let ground = albedo * (2 * simd_max(skyY, .zero) + sunlight)
        self.init(mean: skyMean + ground * 0.5, x: rgb(1), y: skyY - ground * 0.5, z: rgb(3))
    }

    init(mean: SIMD3<Float>, x: SIMD3<Float>, y: SIMD3<Float>, z: SIMD3<Float>) {
        self.mean = mean
        self.x = x
        self.y = y
        self.z = z
    }

    // MARK: - Shaping it for the avatar

    /// The same light, as bright overall as `luminance`: the sky gives its
    /// colour and where it comes from, the scene's ambient curve how much
    /// of it there is.
    func scaled(toLuminance luminance: Float) -> SkyAmbient {
        let current = simd_dot(mean, Self.luma)
        guard current > 1e-5 else { return .hemisphere(SIMD3<Float>(repeating: luminance)) }
        let k = luminance / current
        return SkyAmbient(mean: mean * k, x: x * k, y: y * k, z: z * k)
    }

    /// The colour kept to `saturation` of itself (0 = grey), brightness
    /// unchanged, per term.
    func saturated(_ saturation: Float) -> SkyAmbient {
        func keep(_ c: SIMD3<Float>) -> SIMD3<Float> {
            let grey = SIMD3<Float>(repeating: simd_dot(c, Self.luma))
            return grey + (c - grey) * saturation
        }
        return SkyAmbient(mean: keep(mean), x: keep(x), y: keep(y), z: keep(z))
    }

    /// No channel's light turning more than `ratio` of its mean from one
    /// side to the other, so no side goes black.
    func limited(to ratio: Float) -> SkyAmbient {
        var result = self
        for c in 0..<3 {
            let gradient = SIMD3<Float>(x[c], y[c], z[c])
            let length = simd_length(gradient)
            let most = ratio * max(mean[c], 0)
            guard length > most, length > 1e-6 else { continue }
            let k = most / length
            result.x[c] *= k
            result.y[c] *= k
            result.z[c] *= k
        }
        return result
    }

    /// Rain's overcast, as the sky shader's: colour drained, a little darker.
    func overcast(_ rain: Float) -> SkyAmbient {
        guard rain > 0 else { return self }
        let drained = saturated(1 - rain * 0.7)
        let k = 1 - rain * 0.28
        return SkyAmbient(mean: drained.mean * k, x: drained.x * k, y: drained.y * k, z: drained.z * k)
    }

    /// The sky's light as the avatar takes it: its colour (a little
    /// softened) and where it comes from, at `color`'s brightness (the
    /// scene's ambient curve, which keeps a toon-shaded face readable at
    /// night), never turning so far from one side to the other that a side
    /// goes dark.
    func shaped(toBrightness color: SIMD3<Float>) -> SkyAmbient {
        saturated(Self.avatarSaturation)
            .scaled(toLuminance: simd_dot(color, Self.luma))
            .limited(to: Self.avatarContrast)
    }

    static let avatarSaturation: Float = 0.8
    static let avatarContrast: Float = 0.6

    /// A colour's hue at luminance 1: what tints a surface without
    /// changing how bright the curve already makes it.
    static func tint(_ color: SIMD3<Float>) -> SIMD3<Float> {
        let luminance = simd_dot(color, luma)
        return luminance > 1e-5 ? color / luminance : SIMD3<Float>(repeating: 1)
    }

    static let luma = SIMD3<Float>(0.2126, 0.7152, 0.0722)
}
