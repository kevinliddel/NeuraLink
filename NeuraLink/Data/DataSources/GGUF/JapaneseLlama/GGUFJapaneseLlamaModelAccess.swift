//
//  GGUFJapaneseLlamaModelAccess.swift
//  NeuraLink
//
//  Resolves the on-disk path of the Japanese-oriented Llama-3.2-1B GGUF model.
//  Model: grapevine-AI/Llama-3.2-1B-Instruct-GGUF (Q4_K_M, ~808 MB)
//
//  Created by Dedicatus on 06/05/2026.
//

import Foundation

enum GGUFJapaneseLlamaModelAccess {

    // MARK: - Constants

    static let repoID   = "grapevine-AI/Llama-3.2-1B-Instruct-GGUF"
    static let filename = "Llama-3.2-1B-Instruct-Q4_K_M.gguf"

    private static let pathKey = "LocalModel_GGUFJapaneseLlamaPath"
    private static let hubSlug = "models--grapevine-AI--Llama-3.2-1B-Instruct-GGUF"

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
