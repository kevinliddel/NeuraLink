//
//  VRMRenderer+Sky.swift
//  NeuraLink
//
//  Created by Dedicatus on 17/04/2026.
//

import Metal
import simd

// MARK: - Sky lifecycle hooks

extension VRMRenderer {

    /// Instantiates the SkyRenderer subsystem. Called once from `VRMRenderer.init`.
    func setupSkyRenderer() {
        skyRenderer = SkyRenderer(device: device, config: config)
    }

    /// Advances cloud time and re-derives the sky environment from the current local clock.
    func updateSky(deltaTime: Float) {
        skyRenderer?.update(deltaTime: deltaTime)
    }

    /// Encodes the sky background into the current render pass.
    /// Must be called before VRM mesh draw calls.
    func drawSky(encoder: MTLRenderCommandEncoder) {
        guard let sky = skyRenderer else { return }
        let invVP = (projectionMatrix * viewMatrix).inverse
        sky.prepareForEncoding(invViewProjection: invVP)
        sky.encode(encoder: encoder)
    }
}

// MARK: - Sky-driven VRM lighting

extension VRMRenderer {

    /// Updates the three VRM lights so they match the current sun position in the sky.
    ///
    /// - Key light  = sun (or moon at night), direction from sun toward scene.
    /// - Fill light = opposite sky scatter.
    /// - Rim light  = fixed above-behind, separates model from background.
    ///
    /// The MToon shader computes `dot(N, -lightDirection)`, so we pass
    /// **−directionTowardLight** as the `direction` argument of `setLight`.
    public func applySkyLighting() {
        guard let env = skyRenderer?.currentEnvironment else { return }

        // Key light: rays travel FROM the sun TOWARD the scene → pass -sunDirection.
        setLight(
            0,
            direction: -env.keyLightDirection,
            color: env.keyLightColor,
            intensity: env.keyLightIntensity
        )

        // Fill light: soft sky scatter from the opposite side.
        setLight(
            1,
            direction: -env.fillLightDirection,
            color: env.fillLightColor,
            intensity: env.fillLightIntensity
        )

        // Rim light: fixed above-behind, creates model-sky separation.
        setLight(
            2,
            direction: -env.rimLightDirection,
            color: env.rimLightColor,
            intensity: env.rimLightIntensity
        )

        setAmbientColor(env.ambientColor)
    }
}
