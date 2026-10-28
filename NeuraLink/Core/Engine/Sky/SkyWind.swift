//
//  SkyWind.swift
//  NeuraLink
//
//  A light breeze for the avatar's hair and clothes (SpringBoneSolver.wind):
//  blowing the way the clouds drift, its direction wandering slowly, its
//  strength in slow, uneven gusts that never quite die away, stronger on a
//  windy afternoon and in the rain. Procedural, not a forecast.
//
//  Created by Dedicatus on 28/10/2026.
//

import Foundation
import simd

nonisolated enum SkyWind {

    /// The mean breeze, metres a second of air against the spring bones'
    /// drag: enough to sway light hair, not to lift it.
    static let strength: Float = 0.25

    /// The clouds' downwind bearing in the scene (x, z): the sky's low layer
    /// moves its noise by (2.82, 0.85) a second (SkyShader.metal), so the
    /// clouds over the ground travel the other way.
    static let downwind = atan2(Float(-0.85), Float(-2.82))

    /// The air's velocity at `time` (seconds, the sky's cloud clock), for
    /// the day's `cloudSpeed` (`SkyEnvironment.cloudSpeed`) and `rain` [0, 1].
    static func velocity(time: Float, cloudSpeed: Float, rain: Float) -> SIMD3<Float> {
        // Waves at unrelated periods (minutes for the direction, seconds for
        // the gusts), so the pattern doesn't repeat.
        let bearing = downwind + 0.44 * sin(time * 0.031) + 0.2 * sin(time * 0.083 + 1.3)
        let gust = 0.65 + 0.2 * sin(time * 0.53 + 0.4) + 0.1 * sin(time * 1.37 + 2.1) + 0.05 * sin(time * 2.9)
        // The clouds run faster by day (0.008 → 0.026), and so does the wind.
        let day = 0.7 + 0.3 * min(max((cloudSpeed - 0.008) / 0.018, 0), 1)
        let speed = strength * gust * day * (1 + 0.8 * min(max(rain, 0), 1))
        return SIMD3<Float>(cos(bearing), 0, sin(bearing)) * speed
    }
}
