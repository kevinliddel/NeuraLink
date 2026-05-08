//
//  VRMRenderer+Tree.swift
//  NeuraLink
//
//  Created by Dedicatus on 07/05/2026.
//

import Metal
import simd

// MARK: - Tree + Grass lifecycle hooks

extension VRMRenderer {

    func setupTree() {
        guard let url = findGLB(named: "tree") else {
            vrmLog("[TreeRenderer] tree.glb not found in bundle")
            return
        }
        let renderer = TreeRenderer(device: device)
        renderer.setup(config: config)
        treeRenderer = renderer

        Task.detached(priority: .userInitiated) { [weak renderer] in
            do {
                try await renderer?.load(url: url)
            } catch {
                vrmLog("[TreeRenderer] tree.glb load failed: \(error)")
            }
        }

        setupGrass()
    }

    private func setupGrass() {
        guard let url = findGLB(named: "grass") else {
            vrmLog("[GrassRenderer] grass.glb not found in bundle")
            return
        }
        let renderer = TreeRenderer(
            device: device,
            instanceConfigs: TreeRenderer.defaultGrassConfigs
        )
        renderer.setup(config: config)
        grassRenderer = renderer

        Task.detached(priority: .userInitiated) { [weak renderer] in
            do {
                try await renderer?.load(url: url)
            } catch {
                vrmLog("[GrassRenderer] grass.glb load failed: \(error)")
            }
        }
    }

    // MARK: - Shadow passes

    /// Encodes tree + grass depths into the WIDE shadow map.
    /// Trees always clear the wide map first; grass appends onto it.
    func drawTreeShadow(commandBuffer: MTLCommandBuffer, clearFirst: Bool = false) {
        guard let wideShadowMap = terrainRenderer?.exposedWideShadowMap else { return }
        let wideLightVP = terrainRenderer?.exposedWideLightViewProjection ?? matrix_identity_float4x4
        // Trees clear the wide map on every frame regardless of clearFirst
        treeRenderer?.drawShadow(
            commandBuffer: commandBuffer,
            shadowMap: wideShadowMap,
            lightViewProjection: wideLightVP,
            clearFirst: true
        )
        grassRenderer?.drawShadow(
            commandBuffer: commandBuffer,
            shadowMap: wideShadowMap,
            lightViewProjection: wideLightVP,
            clearFirst: false
        )
    }

    // MARK: - Main draw

    /// Encodes trees and grass into the active main render encoder.
    /// Call after `drawTerrain` so they depth-test against the ground.
    func drawTree(encoder: MTLRenderCommandEncoder) {
        // Trees and grass sample from the wide shadow map for self-shadowing
        guard let wideShadowMap = terrainRenderer?.exposedWideShadowMap,
            let sampler = terrainRenderer?.exposedShadowSampler
        else { return }

        let vp = projectionMatrix * viewMatrix
        let wideLightVP = terrainRenderer?.exposedWideLightViewProjection ?? matrix_identity_float4x4
        let env = skyRenderer?.currentEnvironment
        let rawSun = env?.sunDirection ?? SIMD3<Float>(0, 1, 0)
        let sunHeight = rawSun.y
        let effectiveSun = rawSun.y >= 0 ? rawSun : rawSun * -1.0
        let shadowSoft: Float = rawSun.y >= 0 ? 2.5 : 1.5

        treeRenderer?.draw(
            encoder: encoder,
            viewProjection: vp,
            lightViewProjection: wideLightVP,
            sunDirection: effectiveSun,
            sunHeight: sunHeight,
            shadowSoft: shadowSoft,
            shadowMap: wideShadowMap,
            shadowSampler: sampler
        )

        grassRenderer?.draw(
            encoder: encoder,
            viewProjection: vp,
            lightViewProjection: wideLightVP,
            sunDirection: effectiveSun,
            sunHeight: sunHeight,
            shadowSoft: shadowSoft,
            shadowMap: wideShadowMap,
            shadowSampler: sampler
        )
    }

    // MARK: - Bundle lookup

    private func findGLB(named name: String) -> URL? {
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
