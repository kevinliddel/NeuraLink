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
    static let filename = "Llama-3.2-1B-Instruct-Q4_K_M.gguf"

    private static let pathKey  = "LocalModel_GGUFPath"
    private static let hubSlug  = "models--bartowski--Llama-3.2-1B-Instruct-GGUF"

    // MARK: - URL resolution

    /// The full URL to the downloaded `.gguf` file, or `nil` if not present.
    static func modelURL() -> URL? {
        // 1. Persisted path from a previous download.
        if let relative = UserDefaults.standard.string(forKey: pathKey) {
            let url = appSupport.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: url.path) { return url }
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
        let hub = appSupport.appendingPathComponent("hub/\(hubSlug)")
        try? FileManager.default.removeItem(at: hub)
        UserDefaults.standard.removeObject(forKey: pathKey)
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
