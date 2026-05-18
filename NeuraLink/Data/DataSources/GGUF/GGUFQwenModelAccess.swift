//
//  GGUFQwenModelAccess.swift
//  NeuraLink
//
//  Resolves the on-disk path of the downloaded Qwen GGUF model file.
//
//  Created by Dedicatus on 29/04/2026.
//

import Foundation

enum GGUFQwenModelAccess {

    // MARK: - Constants

    static let repoID   = "Qwen/Qwen2.5-1.5B-Instruct-GGUF"
    static let filename = "qwen2.5-1.5b-instruct-q4_k_m.gguf"

    private static let pathKey  = "LocalModel_QwenGGUFPath"
    private static let hubSlug  = "models--Qwen--Qwen2.5-1.5B-Instruct-GGUF"

    // MARK: - URL resolution

    /// The full URL to the downloaded `.gguf` file, or `nil` if not present.
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
