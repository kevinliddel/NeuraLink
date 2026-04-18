//
//  VRMRenderer+Terrain.swift
//  NeuraLink
//
//  Created by Dedicatus on 17/04/2026.
//

import Metal
import simd

// MARK: - Terrain lifecycle hooks

extension VRMRenderer {

    /// Instantiates the TerrainRenderer subsystem. Called once from `VRMRenderer.init`.
    func setupTerrain() {
        terrainRenderer = TerrainRenderer(device: device, config: config)
    }

    /// Updates terrain time and sun state from the current sky environment.
    /// Call this once per frame from the animation ticker (same time as `updateSky`).
    func updateTerrain(deltaTime: Float) {
        guard let env = skyRenderer?.currentEnvironment else { return }
        terrainRenderer?.update(environment: env, deltaTime: deltaTime)
    }

    /// Encodes the shadow-map depth pass for the VRM model.
    /// Must be called on the command buffer **before** the main render encoder opens.
    func drawShadowPass(commandBuffer: MTLCommandBuffer) {
        guard let model = model else { return }
        terrainRenderer?.drawShadowPass(
            commandBuffer: commandBuffer,
            model: model,
            modelRotation: vrmVersionRotation,
            skinningSystem: skinningSystem
        )
    }

    /// Encodes the terrain quad into the active render encoder.
    /// Call this **after** `drawSky` and **before** VRM mesh draw calls.
    func drawTerrain(encoder: MTLRenderCommandEncoder) {
        let vp = projectionMatrix * viewMatrix
        terrainRenderer?.drawTerrain(encoder: encoder, viewProjection: vp)
    }
}
