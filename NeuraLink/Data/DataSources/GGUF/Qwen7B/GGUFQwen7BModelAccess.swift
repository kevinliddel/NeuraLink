//
//  GGUFQwen7BModelAccess.swift
//  NeuraLink
//
//  Resolves the on-disk path of the Qwen-2.5-7B-Instruct GGUF model.
//  Targets the 8 GB tier (iPhone 15 Pro / 15 Pro Max / 16 family).
//  Model: bartowski/Qwen2.5-7B-Instruct-GGUF (Q4_K_M, ~4.68 GB)
//
//  Created by Dedicatus on 18/05/2026.
//

import Foundation

enum GGUFQwen7BModelAccess {

    // MARK: - Constants

    static let repoID   = "bartowski/Qwen2.5-7B-Instruct-GGUF"
    static let filename = "Qwen2.5-7B-Instruct-Q4_K_M.gguf"

    private static let pathKey = "LocalModel_GGUFQwen7BPath"
    private static let hubSlug = "models--bartowski--Qwen2.5-7B-Instruct-GGUF"

    // MARK: - URL resolution

    static func modelURL() -> URL? {
        if let relative = UserDefaults.standard.string(forKey: pathKey) {
            let url = appSupport.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return scanHubCache()
    }

    // MARK: - State

    static var isDownloaded: Bool { modelURL() != nil }

    static func setModelPath(_ url: URL) {
        let relative = url.path.replacingOccurrences(of: appSupport.path, with: "")
        UserDefaults.standard.set(relative, forKey: pathKey)
    }

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
