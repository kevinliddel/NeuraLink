//
//  VRMRenderer+Campus.swift
//  NeuraLink
//
//  Created by Dedicatus on 10/05/2026.
//

import Metal
import simd

extension VRMRenderer {

    // MARK: - Setup

    func setupCampus() {
        guard let url = findCampusGLB(named: "campus") else {
            vrmLog("[CampusRenderer] campus.glb not found in bundle")
            return
        }
        let renderer = CampusRenderer(
            device: device,
            instanceConfig: (x: 0, y: -0.02, z: 0, rotY: 0, scale: 1.0)
        )
        renderer.setup(config: config)
        campusRenderer = renderer

        Task.detached(priority: .userInitiated) { [weak renderer] in
            do {
                try await renderer?.load(url: url)
            } catch {
                vrmLog("[CampusRenderer] campus.glb load failed: \(error)")
            }
        }
    }

    // MARK: - Shadow pass

    func drawCampusShadow(commandBuffer: MTLCommandBuffer) {
        guard let wideShadowMap = terrainRenderer?.exposedWideShadowMap else { return }
        let rawSun      = skyRenderer?.currentEnvironment.sunDirection ?? SIMD3<Float>(0, 1, 0)
        let effectiveSun: SIMD3<Float> = rawSun.y >= 0 ? rawSun : rawSun * -1.0
        // Ray-cast coverage: ±300 units horizontal, up to 500 units tall (captures full canopy).
        let campusLightVP = TerrainRenderer.makeEnvLightMatrix(
            sunDir: effectiveSun, radius: 300, height: 500)
        campusRenderer?.drawShadow(
            commandBuffer: commandBuffer,
            shadowMap: wideShadowMap,
            lightViewProjection: campusLightVP,
            clearFirst: true
        )
    }

    // MARK: - Main draw

    func drawCampus(encoder: MTLRenderCommandEncoder) {
        guard let wideShadowMap = terrainRenderer?.exposedWideShadowMap,
              let sampler       = terrainRenderer?.exposedShadowSampler
        else { return }

        let vrmShadowMap  = terrainRenderer?.exposedShadowMap    ?? wideShadowMap
        let vrmLightVP    = terrainRenderer?.exposedLightViewProjection ?? matrix_identity_float4x4

        let vp          = projectionMatrix * viewMatrix
        let env         = skyRenderer?.currentEnvironment
        let rawSun      = env?.sunDirection ?? SIMD3<Float>(0, 1, 0)
        let sunHeight   = rawSun.y
        let effectiveSun: SIMD3<Float> = rawSun.y >= 0 ? rawSun : rawSun * -1.0
        let shadowSoft: Float = rawSun.y >= 0 ? 2.5 : 1.5
        // Must match the matrix used in drawCampusShadow.
        let campusLightVP = TerrainRenderer.makeEnvLightMatrix(
            sunDir: effectiveSun, radius: 300, height: 500)

        let invView   = viewMatrix.inverse
        let cameraPos = SIMD3<Float>(invView[3][0], invView[3][1], invView[3][2])

        campusRenderer?.draw(
            encoder: encoder,
            viewProjection: vp,
            lightViewProjection: campusLightVP,
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

    private func findCampusGLB(named name: String) -> URL? {
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
