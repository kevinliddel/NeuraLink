//
//  VRMRenderer+Environment.swift
//  NeuraLink
//
//  Created by Dedicatus on 08/05/2026.
//
//  Drives the single active environment GLB (city / campus / apartment).
// Only the selected environment is loaded; changing the
//  selection lazily loads the new GLB — terrain shows briefly until it's in.
//

import Metal
import simd

extension VRMRenderer {

    // MARK: - Setup

    /// Loads the currently selected environment. Called once at init; the draw
    /// path re-invokes the loader (cheaply) whenever the selection changes.
    func setupEnvironment() {
        loadEnvironment(named: UserSettings.shared.selectedEnvironment)
    }

    /// Swaps in a renderer for `name` and kicks off its GLB load in the
    /// background. No-ops once `loadedEnvironmentName` already matches, so it's
    /// safe to call every frame from the draw path.
    func loadEnvironment(named name: String) {
        guard loadedEnvironmentName != name else { return }

        let option = EnvironmentCatalog.option(for: name)
        let renderer = EnvironmentRenderer(
            device: device,
            instanceConfig: option.instanceConfig,
            autoFitFootprint: option.autoFitFootprint,
            bakedLighting: option.bakedLighting
        )
        renderer.setup(config: config)
        environmentRenderer = renderer
        loadedEnvironmentName = name

        Task.detached(priority: .userInitiated) { [weak renderer] in
            do {
                let url = try await RemoteAssetCache.shared.url(for: .scene(name))
                try await renderer?.load(url: url)
            } catch {
                nlLog("[EnvironmentRenderer] \(name).glb resolve/load failed: \(error)")
            }
            // Release the launch loading screen once the selected environment's
            // mesh is in (or its load failed — never hang the reveal).
            await EnvironmentLoadState.shared.environmentDidLoad(name)
        }
    }

    // MARK: - Shadow pass

    func drawEnvironmentShadow(commandBuffer: MTLCommandBuffer) {
        loadEnvironment(named: UserSettings.shared.selectedEnvironment)
        guard let wideShadowMap = terrainRenderer?.exposedWideShadowMap else { return }
        let wideLightVP =
            terrainRenderer?.exposedWideLightViewProjection ?? matrix_identity_float4x4
        environmentRenderer?.drawShadow(
            commandBuffer: commandBuffer,
            shadowMap: wideShadowMap,
            lightViewProjection: wideLightVP,
            clearFirst: true
        )
    }

    // MARK: - Main draw

    func drawEnvironment(encoder: MTLRenderCommandEncoder) {
        loadEnvironment(named: UserSettings.shared.selectedEnvironment)
        guard let wideShadowMap = terrainRenderer?.exposedWideShadowMap,
            let sampler = terrainRenderer?.exposedShadowSampler
        else { return }

        // Tight shadow map contains the VRM — used so the character casts a shadow
        // on the environment ground. Falls back to the wide map when unavailable.
        let vrmShadowMap = terrainRenderer?.exposedShadowMap ?? wideShadowMap
        let vrmLightVP = terrainRenderer?.exposedLightViewProjection ?? matrix_identity_float4x4

        let vp = projectionMatrix * viewMatrix
        let wideLightVP =
            terrainRenderer?.exposedWideLightViewProjection ?? matrix_identity_float4x4
        let env = skyRenderer?.currentEnvironment
        let rawSun = env?.sunDirection ?? SIMD3<Float>(0, 1, 0)
        let sunHeight = rawSun.y
        let effectiveSun: SIMD3<Float> = rawSun.y >= 0 ? rawSun : rawSun * -1.0
        let shadowSoft: Float = rawSun.y >= 0 ? 2.5 : 1.5

        let invView = viewMatrix.inverse
        let cameraPos = SIMD3<Float>(invView[3][0], invView[3][1], invView[3][2])

        environmentRenderer?.draw(
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
