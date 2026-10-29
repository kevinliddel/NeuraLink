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

    /// Advances cloud time and re-derives the sky environment from the clock and place.
    func updateSky(deltaTime: Float) {
        skyRenderer?.update(deltaTime: deltaTime)
    }

    /// Advances rain simulation. Both 2D screen overlay and 3D world rain share the same RainController.
    func updateRain(deltaTime: Float) {
        rainRenderer?.update(deltaTime: deltaTime)
        let intensity = (rainRenderer?.intensity ?? 0) * rainBudgetScale
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

    /// The atmosphere's lookup tables, when they need it. Before the render
    /// pass that draws the sky.
    func encodeSkyAtmosphere(commandBuffer: MTLCommandBuffer) {
        skyRenderer?.encodeAtmosphere(commandBuffer: commandBuffer)
    }

    /// Encodes the sky background into the current render pass.
    /// Must be called before VRM mesh draw calls.
    func drawSky(encoder: MTLRenderCommandEncoder) {
        guard let sky = skyRenderer else { return }
        sky.prepareForEncoding(viewProjection: projectionMatrix * viewMatrix)
        sky.encode(encoder: encoder)
    }
}

// MARK: - Sky-driven VRM lighting

extension VRMRenderer {

    /// Updates the three VRM lights so they match the current sun position in the sky.
    ///
    /// - Key light  = `SkyEnvironment.keyLight`: the sun by day, the night light
    ///   by night, crossing over the sky at twilight, turned to the camera's
    ///   side when it stands behind the avatar (`avatarDirection`).
    /// - Fill light = opposite sky scatter.
    /// - Rim light  = above-behind, separates model from background, in the
    ///   sky's colour there; the real key light while that stands behind her.
    /// - Ambient    = the sky's own light at L1 (`SkyAmbient`): MToon's GI.
    ///
    /// The MToon shader computes `dot(N, -lightDirection)`, so we pass
    /// **−directionTowardLight** as the `direction` argument of `setLight`.
    public func applySkyLighting() {
        guard let env = skyRenderer?.currentEnvironment else { return }

        // Key light: rays travel FROM the light TOWARD the scene → pass -direction.
        setLight(
            0,
            direction: -env.keyLight.avatarDirection,
            color: env.keyLight.color,
            intensity: env.keyLight.intensity
        )

        // Fill light: soft sky scatter from the opposite side.
        setLight(
            1,
            direction: -env.fillLightDirection,
            color: env.fillLightColor,
            intensity: env.fillLightIntensity
        )

        // Rim light: above-behind, creates model-sky separation.
        setLight(
            2,
            direction: -env.rimLightDirection,
            color: env.rimLightColor,
            intensity: env.rimLightIntensity
        )

        // The sky's own light (SkyEnvironment.ambient), under rain's overcast.
        setAmbient(env.ambient.overcast(skyRenderer?.rainIntensity ?? 0))
    }

    /// The breeze in the hair and clothes (SkyWind), in the model's own
    /// space, where its nodes and the spring solver live: the scene draws a
    /// VRM 0.x model turned 180° (`vrmVersionRotation`), so its wind is
    /// turned back, or its hair would blow against the clouds. Still air
    /// when the user has turned it off, for an imported character unless
    /// the user let it in, and with no sky to keep its time.
    func springBoneWind() -> SIMD3<Float> {
        let settings = UserSettings.shared
        guard settings.wind, !modelIsImported || settings.windForImported, let sky = skyRenderer else { return .zero }
        let scene = SkyWind.velocity(
            time: sky.cloudTime, cloudSpeed: sky.currentEnvironment.cloudSpeed, rain: sky.rainIntensity)
        let model = vrmVersionRotation.inverse * SIMD4<Float>(scene, 0)
        return SIMD3<Float>(model.x, model.y, model.z)
    }
}
