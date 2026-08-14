//
//  VRMRenderer+Environment.swift
//  NeuraLink
//
//  Drives the single active environment GLB (city / campus / apartment).
// Only the selected environment is loaded; changing the
//  selection lazily loads the new GLB — terrain shows briefly until it's in.
//
//  Created by Dedicatus on 08/05/2026.
//

import Metal
import simd

/// One-shot per app session: the remaining-scene prefetch kicks once, no
/// matter how many times the environment loader re-runs (retries, manual
/// Retry, selection changes).
@MainActor private var didStartScenePrefetch = false

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
    /// networks hiccup, so a failed fetch is retried up to 3 times — the
    /// loading screen must hold, game-style, until the environment is genuinely
    /// in. Offline-class failures (on a fresh install the first requests race
    /// iOS's network-access grant → NSURLError -1009) wait for connectivity via
    /// `NetworkWaiter` instead of a blind backoff, with a friendly status line
    /// on the loading screen — the raw error is logged under a tag the screen's
    /// log tap does NOT mirror. Only after the final attempt does
    /// `environmentDidLoad` release the reveal regardless, so the screen still
    /// can never hang forever. A cancelled download (superseded by a manual
    /// Retry, which owns a fresh kick) exits without touching the gate.
    /// Once the selected scene is in, the remaining catalog scenes prefetch in
    /// the background.
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
                    // NOTE: tag must stay out of EnvironmentLoadState
                    // .isLoaderMessage — a matching tag would splash this
                    // error onto the loading screen.
                    nlLog(
                        "[EnvironmentDownload] \(sceneID).glb attempt \(attempt)/\(maxAttempts) failed: \(Self.compactError(error))",
                        level: .warning)
                    guard attempt < maxAttempts else { break }
                    if Self.isConnectivityError(error) {
                        await EnvironmentLoadState.shared.report(
                            "[EnvironmentDownload] Waiting for connection…")
                        await NetworkWaiter.waitForConnectivity(timeout: 60)
                    } else {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                    }
                    // The waits above don't throw on cancellation (`try?`
                    // swallows it; the connectivity wait suspends through it)
                    // — bail here instead of reporting/starting another fetch.
                    if Task.isCancelled { return }
                    await EnvironmentLoadState.shared.report(
                        "[EnvironmentDownload] Retrying download…")
                }
            }
            await EnvironmentLoadState.shared.environmentDidLoad(name)
            Self.prefetchRemainingScenes(excluding: sceneID)
        }
    }

    /// Best-effort background download of every catalog scene that isn't the
    /// selected one, sequentially so it never competes with a foreground
    /// download for bandwidth. Runs once per app session, after the selected
    /// scene concludes — a failure just means that scene downloads on first
    /// selection instead (the pre-existing lazy path).
    nonisolated static func prefetchRemainingScenes(excluding selectedID: String) {
        Task { @MainActor in
            guard !didStartScenePrefetch else { return }
            didStartScenePrefetch = true
            Task.detached(priority: .utility) {
                for option in EnvironmentCatalog.all where option.id != selectedID {
                    do {
                        _ = try await RemoteAssetCache.shared.url(for: .scene(option.id))
                        nlLog("[EnvironmentDownload] Prefetched scene '\(option.id)'", level: .info)
                    } catch {
                        nlLog(
                            "[EnvironmentDownload] Prefetch failed for '\(option.id)': \(Self.compactError(error))",
                            level: .warning)
                    }
                }
            }
        }
    }

    /// One-line description for download-failure logs — `domain(code):
    /// description` instead of the full NSError userInfo dump (which is pages
    /// of CFNetwork internals for a simple "offline" failure).
    nonisolated static func compactError(_ error: Error) -> String {
        if case RemoteAssetCache.CacheError.downloadFailed(let inner) = error {
            let ns = inner as NSError
            return "\(ns.domain)(\(ns.code)): \(ns.localizedDescription)"
        }
        return String(describing: error)
    }

    /// True when `error` is an offline-class transport failure worth waiting
    /// out (vs. an HTTP/parse error a wait won't fix).
    nonisolated static func isConnectivityError(_ error: Error) -> Bool {
        let urlError: URLError?
        if case RemoteAssetCache.CacheError.downloadFailed(let inner) = error {
            urlError = inner as? URLError
        } else {
            urlError = error as? URLError
        }
        switch urlError?.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
            .cannotFindHost, .dnsLookupFailed, .timedOut, .dataNotAllowed,
            .internationalRoamingOff:
            return true
        default:
            return false
        }
    }

    /// True when `error` is a cancellation — either of the awaiting Task or of
    /// the underlying `URLSessionDownloadTask` (surfaced wrapped in
    /// `CacheError.downloadFailed`). `nonisolated`: pure logic, called from
    /// the detached download-retry task.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
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
