//
//  GGUFGemma2BJPModelAccess.swift
//  NeuraLink
//
//  Resolves the on-disk path of the Japanese local model GGUF file.
//  Model: grapevine-AI/gemma-2-2b-jpn-it-gguf (Q4_K_M, ~1.71 GB) — Google's
//  official Japanese-tuned Gemma 2 2B. Replaced the grapevine Llama-3.2-1B
//  build (IQ4_XS, ~743 MB) in 2026-06 for materially better Japanese. The
//  model enum case was renamed to `.japaneseGemma2b` at the same time, but
//  the persisted KV-cache key string stays "japaneseLlama1b" to avoid
//  orphaning existing cache blobs (see LocalLLMKVCache).
//
//  Created by Dedicatus on 06/05/2026.
//

import Foundation

enum GGUFGemma2BJPModelAccess {

    // MARK: - Constants

    // Google's JP-tuned Gemma 2 2B, Q4_K_M (~1.71 GB) — the JP product model,
    // paired with VoiceVox TTS. `modelURL()` validates the persisted path
    // against `filename`, so a quant change triggers a re-download.
    // (Note grapevine's upstream filename uses a capital "2B".)
    static let repoID   = "grapevine-AI/gemma-2-2b-jpn-it-gguf"
    static let filename = "gemma-2-2B-jpn-it-Q4_K_M.gguf"

    private static let pathKey = "LocalModel_GGUFGemma2BJPPath"
    private static let hubSlug = "models--grapevine-AI--gemma-2-2b-jpn-it-gguf"

    // MARK: - URL resolution

    static func modelURL() -> URL? {
        // Validate the persisted path against the current `filename` so a
        // quant change in code triggers a re-download instead of silently
        // loading the stale file. See GGUFModelAccess for full context.
        if let relative = UserDefaults.standard.string(forKey: pathKey) {
            let url = appSupport.appendingPathComponent(relative)
            if url.lastPathComponent == filename,
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
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
