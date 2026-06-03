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
    // Switched from IQ4_XS to Q8_0 in 2026-06: max-available quant at
    // ~1.32 GB, "extremely high quality" per the repo card — trades a
    // larger footprint for near-lossless output vs the F16 weights
    // (2.48 GB), which the repo notes are generally unneeded. The
    // previous IQ4_XS filename was
    //   "Llama-3.2-1B-Instruct-IQ4_XS.gguf"
    // — kept here as a comment because `modelURL()` validates the
    // persisted UserDefaults path against `filename` and will trigger a
    // re-download if a user still has the old file cached.
    static let filename = "Llama-3.2-1B-Instruct-Q8_0.gguf"

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
