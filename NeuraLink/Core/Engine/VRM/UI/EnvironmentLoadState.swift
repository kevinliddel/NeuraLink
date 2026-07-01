//
//  EnvironmentLoadState.swift
//  NeuraLink
//
//  Drives the game-engine-style launch loading screen. The base scene
//  (avatar + sky + ground) loads quickly, but on first launch the selected
//  3D environment mesh (`<name>.glb`) is downloaded from the Hugging Face
//  dataset and isn't ready yet. We hold the loading screen — showing the
//  environment's preview image — until the SELECTED environment's mesh has
//  finished loading, then reveal the scene with the environment already in
//  place (no pop-in).
//

import Observation
import SwiftUI

@Observable
@MainActor
final class EnvironmentLoadState {
    static let shared = EnvironmentLoadState()

    /// Base scene (avatar + sky + ground) has been displayed.
    private(set) var baseSceneReady = false
    /// The selected environment's 3D mesh finished loading (success or failure).
    private(set) var environmentMeshReady = false

    /// Latest loader/texture log line (tag stripped), shown on the loading
    /// screen for a game-console feel. Nil until the first loader log (and in
    /// Release, where the DEBUG-only logger never fires — the screen shows a
    /// neutral "Loading…" in that case).
    private(set) var currentLogLine: String?

    private init() {
        installLogTap()
    }

    // MARK: - Live loader log feed

    /// Surfaces loader/texture log lines (e.g. "[TextureLoader] …") as the
    /// loading-screen status. DEBUG-only — see `NLLogTap`.
    private func installLogTap() {
        NLLogTap.sink = { body, _ in
            guard EnvironmentLoadState.isLoaderMessage(body) else { return }
            Task { @MainActor in EnvironmentLoadState.shared.report(body) }
        }
    }

    /// Loader-related tags whose log lines drive the loading-screen text.
    nonisolated static func isLoaderMessage(_ body: String) -> Bool {
        body.contains("[TextureLoader]")
            || body.contains("[ParallelTextureLoader]")
            || body.contains("[EnvironmentRenderer]")
    }

    /// Records the latest loader line (ignored once the scene is ready). The
    /// "[Tag] " prefix is stripped so only the message body is shown.
    func report(_ line: String) {
        guard !isReady else { return }
        currentLogLine = Self.stripTag(line)
    }

    /// Drops a leading "[Tag] " (e.g. "[TextureLoader] Drawing image to
    /// context…" → "Drawing image to context…").
    private static func stripTag(_ body: String) -> String {
        guard let range = body.range(of: "] ") else { return body }
        return String(body[range.upperBound...])
    }

    /// Everything needed before revealing the live 3D scene. When the user has
    /// the 3D environment disabled, the mesh load is not awaited.
    var isReady: Bool {
        guard baseSceneReady else { return false }
        return UserSettings.shared.showEnvironment ? environmentMeshReady : true
    }

    func markBaseSceneReady() { baseSceneReady = true }

    /// Called when a scene's mesh finishes loading. Only the SELECTED
    /// environment releases the loading screen — the other environment also
    /// loads in the background but doesn't gate the reveal.
    func environmentDidLoad(_ scene: String) {
        if scene.lowercased() == UserSettings.shared.selectedEnvironment.lowercased() {
            environmentMeshReady = true
        }
    }

    /// Failsafe: force-reveal so the loading screen can never hang — used on a
    /// timeout, or when there's no model / Metal is unavailable / a hard scene
    /// error means there's nothing to wait for.
    func forceReady() {
        baseSceneReady = true
        environmentMeshReady = true
    }
}
