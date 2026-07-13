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

        // Resolve the GLB by the catalog id (always a known, safe basename) rather
        // than the raw persisted selection, so a tampered value can't traverse
        // paths. The loading-screen gate still keys off the requested `name`.
        let sceneID = option.id
        kickEnvironmentDownload(sceneID: sceneID, name: name, renderer: renderer)

        // Wire the loading-screen "Retry" affordance to a fresh fetch: drop the
        // stalled cache entry, then re-kick against the current renderer.
        Task { @MainActor in
            EnvironmentLoadState.shared.setRetryHandler { [weak self] in
                guard let self else { return }
                Task { [weak self] in
                    await RemoteAssetCache.shared.invalidate(.scene(sceneID))
                    self?.kickEnvironmentDownload(
                        sceneID: sceneID, name: name, renderer: self?.environmentRenderer)
                }
            }
        }
    }

    /// Downloads the environment GLB in the background and loads it into
    /// `renderer`, then releases the launch loading screen. Progress is
    /// forwarded to `EnvironmentLoadState` so the loading screen shows bytes/%.
    ///
    /// A first-install download is long (67–100 MB per scene) and real-world
    /// networks hiccup, so a failed fetch is retried up to 3 times with a
    /// short backoff — the loading screen must hold, game-style, until the
    /// environment is genuinely in (the pre-retry behavior revealed an empty
    /// scene on the first transient error). Only after the final attempt does
    /// `environmentDidLoad` release the reveal regardless, so the screen still
    /// can never hang forever. A cancelled download (superseded by a manual
    /// Retry, which owns a fresh kick) exits without touching the gate.
    func kickEnvironmentDownload(
        sceneID: String, name: String, renderer: EnvironmentRenderer?
    ) {
        Task.detached(priority: .userInitiated) { [weak renderer] in
            let onProgress: @Sendable (Int64, Int64) -> Void = { downloaded, total in
                Task { @MainActor in
                    EnvironmentLoadState.shared.reportDownloadProgress(
                        downloaded: downloaded, total: total)
                }
            }
            let maxAttempts = 3
            for attempt in 1...maxAttempts {
                do {
                    let url = try await RemoteAssetCache.shared.url(
                        for: .scene(sceneID), onProgress: onProgress)
                    try await renderer?.load(url: url)
                    break
                } catch {
                    if Self.isCancellation(error) { return }
                    nlLog(
                        "[EnvironmentRenderer] \(sceneID).glb attempt \(attempt)/\(maxAttempts) failed: \(error)",
                        level: .warning)
                    guard attempt < maxAttempts else { break }
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
            await EnvironmentLoadState.shared.environmentDidLoad(name)
        }
    }

    /// True when `error` is a cancellation — either of the awaiting Task or of
    /// the underlying `URLSessionDownloadTask` (surfaced wrapped in
    /// `CacheError.downloadFailed`).
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case RemoteAssetCache.CacheError.downloadFailed(let inner) = error {
            return inner is CancellationError || (inner as? URLError)?.code == .cancelled
        }
        return (error as? URLError)?.code == .cancelled
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
