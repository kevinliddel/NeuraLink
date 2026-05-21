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
    /// nil if the directory could not be created. All `LlamaBridge`-backed
    /// engines (Llama-1B, Llama-1B-JP, Qwen-2B/3B/7B) participate. The
    /// Speculative engine uses a separate `LlamaBridgeSpec` context with no
    /// equivalent `_state_seq_*` plumbing yet — falls through to no-op via
    /// the protocol default in `LLMEngineProtocol`.
    static func path(
        config: LocalModelDownloadManager.ModelConfiguration,
        systemPrompt: String
    ) -> String? {
        guard let dir = supportDir() else { return nil }

        let configKey: String
        switch config {
        case .llama1b:         configKey = "llama1b"
        case .japaneseLlama1b: configKey = "japaneseLlama1b"
        case .qwen2b:          configKey = "qwen2b"
        case .qwen3b:          configKey = "qwen3b"
        case .qwen7b:          configKey = "qwen7b"
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
