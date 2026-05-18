//
//  VRMRenderer+City.swift
//  NeuraLink
//
//  Created by Dedicatus on 08/05/2026.
//

import Metal
import simd

extension VRMRenderer {

    // MARK: - Setup

    func setupCity() {
        guard let url = findCityGLB(named: "city") else {
            vrmLog("[CityRenderer] city.glb not found in bundle")
            return
        }
        let renderer = CityRenderer(
            device: device,
            instanceConfig: (x: 0, y: -0.02, z: 0, rotY: 0, scale: 1.0)
        )
        renderer.setup(config: config)
        cityRenderer = renderer

        Task.detached(priority: .userInitiated) { [weak renderer] in
            do {
                try await renderer?.load(url: url)
            } catch {
                vrmLog("[CityRenderer] city.glb load failed: \(error)")
            }
        }
    }

    // MARK: - Shadow pass

    func drawCityShadow(commandBuffer: MTLCommandBuffer) {
        guard let wideShadowMap = terrainRenderer?.exposedWideShadowMap else { return }
        let rawSun      = skyRenderer?.currentEnvironment.sunDirection ?? SIMD3<Float>(0, 1, 0)
        let effectiveSun: SIMD3<Float> = rawSun.y >= 0 ? rawSun : rawSun * -1.0
        // Ray-cast coverage: ±150 m horizontal, up to 120 m tall (captures all city buildings).
        let cityLightVP = TerrainRenderer.makeEnvLightMatrix(
            sunDir: effectiveSun, radius: 150, height: 120)
        cityRenderer?.drawShadow(
            commandBuffer: commandBuffer,
            shadowMap: wideShadowMap,
            lightViewProjection: cityLightVP,
            clearFirst: true
        )
    }

    // MARK: - Main draw

    func drawCity(encoder: MTLRenderCommandEncoder) {
        guard let wideShadowMap = terrainRenderer?.exposedWideShadowMap,
              let sampler       = terrainRenderer?.exposedShadowSampler
        else { return }

        // Tight shadow map contains the VRM — character casts shadow on city ground.
        let vrmShadowMap  = terrainRenderer?.exposedShadowMap    ?? wideShadowMap
        let vrmLightVP    = terrainRenderer?.exposedLightViewProjection ?? matrix_identity_float4x4

        let vp          = projectionMatrix * viewMatrix
        let env         = skyRenderer?.currentEnvironment
        let rawSun      = env?.sunDirection ?? SIMD3<Float>(0, 1, 0)
        let sunHeight   = rawSun.y
        let effectiveSun: SIMD3<Float> = rawSun.y >= 0 ? rawSun : rawSun * -1.0
        let shadowSoft: Float = rawSun.y >= 0 ? 2.5 : 1.5
        // Must match the matrix used in drawCityShadow.
        let cityLightVP = TerrainRenderer.makeEnvLightMatrix(
            sunDir: effectiveSun, radius: 150, height: 120)

        let invView   = viewMatrix.inverse
        let cameraPos = SIMD3<Float>(invView[3][0], invView[3][1], invView[3][2])

        cityRenderer?.draw(
            encoder: encoder,
            viewProjection: vp,
            lightViewProjection: cityLightVP,
            vrmLightViewProjection: vrmLightVP,
            cameraPosition: cameraPos,
            sunDirection: effectiveSun,
            sunHeight: sunHeight,
            shadowSoft: shadowSoft,
            shadowMap: wideShadowMap,
            vrmShadowMap: vrmShadowMap,
            shadowSampler: sampler
        )
    }

    // MARK: - Bundle lookup

    private func findCityGLB(named name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "glb") {
            return url
        }
        if let url = Bundle.main.url(
            forResource: name, withExtension: "glb",
            subdirectory: "Models/Environments") {
            return url
        }
        return nil
    }
}
