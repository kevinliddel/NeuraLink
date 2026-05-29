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
        let renderer = CampusRenderer(
            device: device,
            instanceConfig: (x: 0, y: -0.02, z: 0, rotY: 0, scale: 1.0)
        )
        renderer.setup(config: config)
        campusRenderer = renderer

        Task.detached(priority: .userInitiated) { [weak renderer] in
            do {
                let url = try await RemoteAssetCache.shared.url(for: .campus)
                try await renderer?.load(url: url)
            } catch {
                nlLog("[CampusRenderer] campus.glb resolve/load failed: \(error)")
            }
        }
    }

    // MARK: - Shadow pass

    func drawCampusShadow(commandBuffer: MTLCommandBuffer) {
        guard let wideShadowMap = terrainRenderer?.exposedWideShadowMap else { return }
        let wideLightVP = terrainRenderer?.exposedWideLightViewProjection ?? matrix_identity_float4x4
        campusRenderer?.drawShadow(
            commandBuffer: commandBuffer,
            shadowMap: wideShadowMap,
            lightViewProjection: wideLightVP,
            clearFirst: true
        )
    }

    // MARK: - Main draw

    func drawCampus(encoder: MTLRenderCommandEncoder) {
        guard let wideShadowMap = terrainRenderer?.exposedWideShadowMap,
              let sampler       = terrainRenderer?.exposedShadowSampler
        else { return }

        // Tight shadow map contains the VRM
        let vrmShadowMap  = terrainRenderer?.exposedShadowMap    ?? wideShadowMap
        let vrmLightVP    = terrainRenderer?.exposedLightViewProjection ?? matrix_identity_float4x4

        let vp          = projectionMatrix * viewMatrix
        let wideLightVP = terrainRenderer?.exposedWideLightViewProjection ?? matrix_identity_float4x4
        let env         = skyRenderer?.currentEnvironment
        let rawSun      = env?.sunDirection ?? SIMD3<Float>(0, 1, 0)
        let sunHeight   = rawSun.y
        let effectiveSun: SIMD3<Float> = rawSun.y >= 0 ? rawSun : rawSun * -1.0
        let shadowSoft: Float = rawSun.y >= 0 ? 2.5 : 1.5

        let invView   = viewMatrix.inverse
        let cameraPos = SIMD3<Float>(invView[3][0], invView[3][1], invView[3][2])

        campusRenderer?.draw(
            encoder: encoder,
            viewProjection: vp,
            lightViewProjection: wideLightVP,
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

}
