//
//  VRMRenderer+Birds.swift
//  NeuraLink
//
//  Created by Dedicatus on 21/04/2026.
//

import Metal
import simd

// MARK: - Bird lifecycle hooks

extension VRMRenderer {

    /// Instantiates the BirdRenderer subsystem. Called once from `VRMRenderer.init`.
    func setupBirdRenderer() {
        birdRenderer = BirdRenderer(device: device, config: config)
    }

    /// Advances bird positions and wing animation from the current sky environment.
    /// Call this once per frame alongside `updateSky` and `updateTerrain`.
    func updateBirds(deltaTime: Float) {
        guard let env = skyRenderer?.currentEnvironment else { return }
        birdRenderer?.update(environment: env, deltaTime: deltaTime)
    }

    /// Encodes the instanced bird draw into the active render encoder.
    /// Call this **after** `drawTerrain` and **before** VRM mesh draw calls.
    func drawBirds(encoder: MTLRenderCommandEncoder) {
        let vp = projectionMatrix * viewMatrix
        birdRenderer?.encode(encoder: encoder, viewProjection: vp)
    }
}
