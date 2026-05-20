//
//  LocalLLMKVCache.swift
//  NeuraLink
//
//  Derives on-disk paths for persisted llama.cpp KV cache state.
//
//  Cache key components:
//    - model configuration ("llama1b" / "japaneseLlama1b")
//    - SHA-256 prefix of the system prompt (so persona edits invalidate
//      the cache automatically rather than restoring a stale prefix)
//
//  The cache file is opaque to Swift — llama.cpp owns the serialisation
//  format via `llama_state_seq_save_file`. Format changes between
//  llama.cpp versions will cause `load_state` to fail gracefully (returns
//  0), at which point the warmup falls through to a fresh prefill.
//
//  Created by Dedicatus on 20/05/2026.
//

import CryptoKit
import Foundation

enum LocalLLMKVCache {

    /// Returns the on-disk path for the given config + system prompt, or
    /// nil if the directory could not be created or the config is not
    /// supported by the persistence layer (currently only `.llama1b` and
    /// `.japaneseLlama1b`).
    static func path(
        config: LocalModelDownloadManager.ModelConfiguration,
        systemPrompt: String
    ) -> String? {
        guard config == .llama1b || config == .japaneseLlama1b else {
            return nil
        }
        guard let dir = supportDir() else { return nil }

        let configKey: String
        switch config {
        case .llama1b:         configKey = "llama1b"
        case .japaneseLlama1b: configKey = "japaneseLlama1b"
        default:               return nil
        }
        let personaKey = sha256Prefix(systemPrompt, length: 16)

        return dir.appendingPathComponent("\(configKey)_\(personaKey).kv").path
    }

    // MARK: - Internals

    private static func supportDir() -> URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = base.appendingPathComponent("llm_kv", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func sha256Prefix(_ input: String, length: Int) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(length))
    }
}
