//
//  GGUFModelAccess.swift
//  NeuraLink
//
//  Resolves the on-disk path of the downloaded GGUF model file.
//  Mirrors the LlamaModelAccess pattern — one responsibility: path resolution.
//
//  Created by Dedicatus on 29/04/2026.
//

import Foundation

enum GGUFModelAccess {

    // MARK: - Constants

    static let repoID   = "bartowski/Llama-3.2-1B-Instruct-GGUF"
    // PERF (2026-06-19): Q8_0 (~1.32 GB) was TOO BIG for the 4 GB iPhone 11 —
    // device log showed peak memory 2.02 GB → jetsam kill, and the weights
    // still streamed from flash (Disk ~387 MB/s). The LLM runs CPU-only on
    // <5 GB devices (LLMRuntimeProfile forces gpuLayers=0), so a smaller model
    // both fits resident (no streaming) AND does less CPU compute. Dropped to
    // Q4_K_M (~0.81 GB). `modelURL()` validates the persisted path against
    // `filename`, so this triggers a re-download. (Q8_0 file name was
    // "Llama-3.2-1B-Instruct-Q8_0.gguf" if reverting.)
    static let filename = "Llama-3.2-1B-Instruct-Q4_K_M.gguf"

    private static let pathKey  = "LocalModel_GGUFPath"
    private static let hubSlug  = "models--bartowski--Llama-3.2-1B-Instruct-GGUF"

    // MARK: - URL resolution

    /// The full URL to the downloaded `.gguf` file, or `nil` if not present.
    static func modelURL() -> URL? {
        // 1. Persisted path from a previous download — but only honour it
        //    if the stored filename matches the current `filename` constant.
        //    Otherwise a quant change in code (e.g. Q4_K_M → IQ4_XS) would
        //    silently keep loading the old file forever.
        if let relative = UserDefaults.standard.string(forKey: pathKey) {
            let url = appSupport.appendingPathComponent(relative)
            if url.lastPathComponent == filename,
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        // 2. Scan the Hub cache directory (downloaded via HubApi).
        return scanHubCache()
    }

    // MARK: - State

    static var isDownloaded: Bool { modelURL() != nil }

    /// Persists the relative path after a successful download.
    static func setModelPath(_ url: URL) {
        let relative = url.path.replacingOccurrences(of: appSupport.path, with: "")
        UserDefaults.standard.set(relative, forKey: pathKey)
    }

    /// Removes the cached file and clears the stored path.
    static func clearCache() {
        HubCacheUtils.clear(hubSlug: hubSlug, pathKey: pathKey)
    }

    // MARK: - Internals

    private static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private static func scanHubCache() -> URL? {
        let snaps = appSupport.appendingPathComponent("hub/\(hubSlug)/snapshots")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: snaps, includingPropertiesForKeys: nil)
        else { return nil }

        for snap in entries.sorted(by: { $0.path > $1.path }) {
            let candidate = snap.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: candidate.path) {
                setModelPath(candidate)
                return candidate
            }
        }
        return nil
    }
}
