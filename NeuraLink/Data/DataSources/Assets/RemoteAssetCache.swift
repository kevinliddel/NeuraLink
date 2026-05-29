//
// RemoteAssetCache.swift
// NeuraLink
//
// Async resolver for on-demand assets. Returns a usable file URL for a
// SceneAsset by checking (in order):
//   1. In-actor resolved cache — short-circuits repeated calls in the
//      same app session without any FS work.
//   2. App bundle — keeps local dev + current Release build green while
//      the GLBs are still in "Copy Bundle Resources".
//   3. On-disk download cache at `<App Support>/hf-assets/<pathInRepo>`.
//   4. Direct HTTPS download from the public HuggingFace dataset.
//
// Single-flight: concurrent callers for the same asset share one Task.
// Reentrancy is fine — the actor serializes access to the `inFlight`
// table, and Task.value is safe to await from multiple suspended
// continuations.
//
// Why plain `URLSession` instead of `HubApi`: the dataset is public, but
// HubApi's default `TokenProvider.environment` auto-discovers HF tokens
// from `HF_TOKEN` env vars and `~/.cache/huggingface/token` files. iOS
// simulators inherit env vars from the launching shell, so a host-side
// CLI token leaks in and HF rejects it with 401 for cross-account or
// scoped-wrong reasons. The public init doesn't expose `tokenProvider`
// directly, so we can't opt out of token discovery. Going direct via
// the `huggingface.co/datasets/<repo>/resolve/main/<path>` URL bypasses
// auth entirely — that endpoint is anonymous-readable for public datasets.
//
// Created by Dedicatus on 29/05/2026.
//

import Foundation

actor RemoteAssetCache {
    static let shared = RemoteAssetCache()

    enum CacheError: Error {
        case assetNotFound
        case downloadFailed(Error)
        case httpStatus(Int)
    }

    private var resolved: [RemoteAssetRegistry: URL] = [:]
    private var inFlight: [RemoteAssetRegistry: Task<URL, Error>] = [:]

    private init() {}

    /// Resolves the on-disk URL for `asset`. Cheap when the bundle or the
    /// in-actor resolved cache satisfies the lookup; only the cold path
    /// touches the network.
    func url(for asset: RemoteAssetRegistry) async throws -> URL {
        if let cached = resolved[asset] {
            return cached
        }
        if let bundled = bundledURL(for: asset) {
            resolved[asset] = bundled
            return bundled
        }
        if let onDisk = Self.cachedURL(for: asset),
            FileManager.default.fileExists(atPath: onDisk.path) {
            resolved[asset] = onDisk
            return onDisk
        }
        if let existing = inFlight[asset] {
            return try await existing.value
        }
        let task = Task<URL, Error> {
            try await Self.download(asset: asset)
        }
        inFlight[asset] = task
        defer { inFlight[asset] = nil }
        let url = try await task.value
        resolved[asset] = url
        return url
    }

    // MARK: - Path resolution

    private func bundledURL(for asset: RemoteAssetRegistry) -> URL? {
        let resource = (asset.filename as NSString).deletingPathExtension
        let rawExt = (asset.filename as NSString).pathExtension
        let ext: String? = rawExt.isEmpty ? nil : rawExt
        if let url = Bundle.main.url(forResource: resource, withExtension: ext) {
            return url
        }
        guard let subdir = asset.bundleSubdirectory else { return nil }
        return Bundle.main.url(
            forResource: resource, withExtension: ext,
            subdirectory: subdir)
    }

    private static func cachedURL(for asset: RemoteAssetRegistry) -> URL? {
        guard let base = hfDownloadBase() else { return nil }
        return base.appendingPathComponent(asset.pathInRepo)
    }

    private static func hfDownloadBase() -> URL? {
        guard
            let support = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        else { return nil }
        let dir = support.appendingPathComponent("hf-assets", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: - Download

    /// Downloads `asset` from the public HuggingFace dataset over plain
    /// HTTPS — no auth, no token discovery, no HubApi caching layer.
    /// Resolves redirects automatically (URLSession default) so the CDN
    /// hop to xet-bridge is transparent.
    private static func download(asset: RemoteAssetRegistry) async throws -> URL {
        guard let target = cachedURL(for: asset) else {
            throw CacheError.assetNotFound
        }
        let parent = target.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try? FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: true)
        }

        let urlString =
            "https://huggingface.co/datasets/\(RemoteAssetRegistry.repoID)/resolve/main/\(asset.pathInRepo)"
        guard let remoteURL = URL(string: urlString) else {
            throw CacheError.assetNotFound
        }

        do {
            let (downloadedTempURL, response) = try await URLSession.shared.download(
                from: remoteURL)
            if let http = response as? HTTPURLResponse,
                !(200..<300).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: downloadedTempURL)
                throw CacheError.httpStatus(http.statusCode)
            }
            if FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: downloadedTempURL, to: target)
            return target
        } catch let err as CacheError {
            throw err
        } catch {
            throw CacheError.downloadFailed(error)
        }
    }
}
