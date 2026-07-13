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

    // MARK: - Download progress + stall detection

    /// Bytes of the selected environment mesh downloaded so far. `0` until the
    /// first progress callback (or when the asset is already cached locally).
    private(set) var downloadedBytes: Int64 = 0
    /// Expected total bytes (`0` when the server omits `Content-Length`).
    private(set) var totalBytes: Int64 = 0
    /// `true` once no progress has arrived for `stallThresholdSeconds`, so the
    /// loading screen can offer an escape hatch instead of a silent spinner.
    private(set) var isStalled = false

    /// Seconds of no progress before we consider the load stalled.
    private let stallThresholdSeconds = 35
    @ObservationIgnored private var secondsSinceProgress = 0
    @ObservationIgnored private var stallMonitor: Task<Void, Never>?

    /// Invoked by `requestRetry()`. Set by the environment loader to invalidate
    /// the cached download and re-kick a fresh fetch.
    @ObservationIgnored private var retryHandler: (() -> Void)?

    private init() {
        installLogTap()
        startStallMonitor()
    }

    /// Human-readable progress line, e.g. "12.3 MB / 45.0 MB (27%)". `nil`
    /// before any bytes arrive; shows just the downloaded size when the total
    /// is unknown.
    var progressText: String? {
        guard downloadedBytes > 0 else { return nil }
        let done = ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
        guard totalBytes > 0 else { return done }
        let all = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        let pct = Int((Double(downloadedBytes) / Double(totalBytes)) * 100)
        return "\(done) / \(all) (\(pct)%)"
    }

    /// Fractional download progress in `0...1`, or `nil` when the total size is
    /// unknown (so the UI shows an indeterminate spinner instead of a bar).
    var progressFraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
    }

    /// 1 s heartbeat that trips `isStalled` after `stallThresholdSeconds`
    /// without progress. Self-cancels once the scene is ready.
    private func startStallMonitor() {
        stallMonitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if self.isReady {
                    self.stallMonitor?.cancel()
                    self.stallMonitor = nil
                    return
                }
                self.secondsSinceProgress += 1
                if self.secondsSinceProgress >= self.stallThresholdSeconds, !self.isStalled {
                    self.isStalled = true
                }
            }
        }
    }

    /// Resets the stall clock — called on any sign of forward progress.
    private func noteProgress() {
        secondsSinceProgress = 0
        if isStalled { isStalled = false }
    }

    /// Records selected-environment download progress. Ignored once ready.
    func reportDownloadProgress(downloaded: Int64, total: Int64) {
        guard !isReady else { return }
        downloadedBytes = downloaded
        if total > 0 { totalBytes = total }
        noteProgress()
    }

    /// Registers the "Retry" action for the loading screen (invalidate cache +
    /// re-kick the environment download). Set by the environment loader.
    func setRetryHandler(_ handler: @escaping () -> Void) {
        retryHandler = handler
    }

    /// Loading-screen "Retry": cancel the stalled fetch and re-attempt the
    /// environment download from scratch, keeping the loading screen up —
    /// game-style, the scene only reveals once the environment is genuinely in.
    /// "Continue to app" (`forceReady`) remains the explicit escape hatch.
    func requestRetry() {
        downloadedBytes = 0
        totalBytes = 0
        secondsSinceProgress = 0
        isStalled = false
        retryHandler?()
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
        noteProgress()
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

    func markBaseSceneReady() {
        baseSceneReady = true
        noteProgress()
    }

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
