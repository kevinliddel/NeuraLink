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

    /// Instantiates the SkyRenderer and RainRenderer subsystems. Called once from `VRMRenderer.init`.
    func setupSkyRenderer() {
        skyRenderer       = SkyRenderer(device: device, config: config)
        rainRenderer      = RainRenderer(device: device, config: config)
        rainWorldRenderer = RainWorldRenderer(device: device, config: config)
    }

    /// Advances cloud time and re-derives the sky environment from the current local clock.
    func updateSky(deltaTime: Float) {
        skyRenderer?.update(deltaTime: deltaTime)
    }

    /// Advances rain simulation. Both 2D screen overlay and 3D world rain share the same RainController.
    func updateRain(deltaTime: Float) {
        rainRenderer?.update(deltaTime: deltaTime)
        let intensity = rainRenderer?.intensity ?? 0
        skyRenderer?.rainIntensity = intensity

        // 3D world rain is driven by the same intensity — synced with the 2D overlay
        let viewInv = viewMatrix.inverse
        let cameraPos = SIMD3<Float>(viewInv[3][0], viewInv[3][1], viewInv[3][2])
        rainWorldRenderer?.update(
            deltaTime: deltaTime,
            intensity: intensity,
            cameraPos: cameraPos,
            viewProjection: projectionMatrix * viewMatrix
        )
    }

    /// Runs the rain-on-lens compute + overlay passes after the main scene encoder has ended.
    /// Works alongside the 3D world rain — both effects are active when intensity > 0.
    func drawRainOverlay(commandBuffer: MTLCommandBuffer,
                         renderPassDescriptor: MTLRenderPassDescriptor) {
        guard let rain = rainRenderer, !rain.isIdle else { return }
        let target = renderPassDescriptor.colorAttachments[0].resolveTexture
                  ?? renderPassDescriptor.colorAttachments[0].texture
        guard let target else { return }
        rain.encodeWaterMap(commandBuffer: commandBuffer)
        rain.encodeOverlay(commandBuffer: commandBuffer, targetTexture: target)
    }

    /// Renders 3D world rain droplets. Only draws when rain is active (intensity > 0).
    func drawWorldRain(encoder: MTLRenderCommandEncoder) {
        guard let intensity = rainRenderer?.intensity, intensity > 0.001 else { return }
        rainWorldRenderer?.draw(encoder: encoder)
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
