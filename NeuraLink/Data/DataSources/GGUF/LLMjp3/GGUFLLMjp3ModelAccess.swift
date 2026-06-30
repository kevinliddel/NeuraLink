//
//  GGUFLLMjp3ModelAccess.swift
//  NeuraLink
//
//  Resolves the on-disk path of the Japanese local model GGUF file.
//  Model: mmnga/llm-jp-3-1.8b-instruct3-gguf (Q3_K_M, ~0.96 GB) — the LLM-jp
//  project's Japanese-native, instruction-tuned 1.8B (Apache-2.0). Chosen for
//  the 4 GB tier because NO gemma-2-2b quant is small enough to stay resident
//  here: even the 1.30 GB IQ3_M jetsam-crashed when loaded non-mmap (the only
//  way to stop iOS evicting the mmap'd weights → flash re-streaming →
//  ~0.15 tok/s). At ~0.96 GB this 1.8B fits resident (no-mmap) → fast decode,
//  and its JP-native tokenizer emits fewer tokens per Japanese reply. Slot
//  history: grapevine Llama-3.2-1B → Google Gemma 2 2B (streamed on 4 GB) →
//  llm-jp-3 1.8B. The model enum case is still named `.llmJp3` (a
//  rename would churn many files) — it's just the JP-slot identifier now. The
//  KV-cache configKey is bumped on this swap so stale gemma/llama blobs are
//  never restored into the new model (see LocalLLMKVCache).
//
//  Created by Dedicatus on 06/05/2026.
//

import Foundation

enum GGUFLLMjp3ModelAccess {

    // MARK: - Constants

    // LLM-jp-3 1.8B instruct at Q3_K_M (~0.96 GB) — paired with VoiceVox TTS.
    // Sized to stay RESIDENT on the 4 GB tier (loaded non-mmap; see
    // llama_bridge.cpp): 0.96 GB clears the ~2.1 GB jetsam budget alongside the
    // avatar + VoiceVox, where the 1.30 GB gemma IQ3_M crashed. `modelURL()`
    // validates the persisted path against `filename`, so this swap triggers a
    // re-download of the new file.
    //   Revert to the Gemma 2 2B JP product build (better JP quality, but
    //   streams on the 4 GB tier): repoID "grapevine-AI/gemma-2-2b-jpn-it-gguf",
    //   filename "gemma-2-2B-jpn-it-Q4_K_M.gguf",
    //   hubSlug "models--grapevine-AI--gemma-2-2b-jpn-it-gguf".
    //   For more quality at higher jetsam risk, the same repo's Q4_K_M
    //   (~1.16 GB) file is "llm-jp-3-1.8b-instruct3-Q4_K_M.gguf".
    static let repoID   = "mmnga/llm-jp-3-1.8b-instruct3-gguf"
    static let filename = "llm-jp-3-1.8b-instruct3-Q3_K_M.gguf"

    private static let pathKey = "LocalModel_GGUFLLMjp3Path"
    private static let hubSlug = "models--mmnga--llm-jp-3-1.8b-instruct3-gguf"

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
