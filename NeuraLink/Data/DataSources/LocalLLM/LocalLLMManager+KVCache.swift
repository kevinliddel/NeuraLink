//
//  LocalLLMManager+KVCache.swift
//  NeuraLink
//
//  KV-cache persistence helpers for LocalLLMManager.
//  Extracted to keep LocalLLMManager.swift within the 495-line SwiftLint cap.
//
//  Save path:
//    bridge plaintext → saveKVCache(to:) → encryptBlob(at:) overwrites in-place
//  Restore path:
//    decryptBlob(at:) → temp file → loadKVCache(from:) → defer-delete temp
//
//  Created by Dedicatus on 11/06/2026.
//

import Foundation

extension LocalLLMManager {

    // MARK: - KV-cache restore

    /// Try to load a previously-persisted KV cache state. Idempotent and
    /// safe to call multiple times — `loadKVCache` no-ops if the file is
    /// missing. Must run after `loadModel` and before any prefill/generate.
    ///
    /// Blobs written by the current build are AES-256-GCM sealed. Legacy
    /// blobs (HMAC-only) are detected by a failed `decryptBlob` → purged →
    /// cold prefill on this launch → next `persistKVCacheIfNeeded` call
    /// writes a properly encrypted blob.
    func tryRestoreKVCache() async {
        guard llmEngine.isLoaded else { return }
        let mgr = LocalModelDownloadManager.shared
        guard mgr.isAvailable else { return }
        let characterName = await MainActor.run { self.state.selectedCharacterName }
        let basePrompt = localLLMSystemPrompt(for: characterName)
        guard let path = LocalLLMKVCache.path(
            config: mgr.selectedConfig, systemPrompt: basePrompt)
        else { return }

        let filename = URL(fileURLWithPath: path).lastPathComponent

        guard FileManager.default.fileExists(atPath: path) else {
            nlLog("[KVCache] No prior cache at \(filename) — cold prefill on first turn", level: .info)
            return
        }

        // Attempt AES-GCM decryption. Returns nil on any failure (missing key,
        // tag mismatch, or legacy plaintext blob that isn't a valid sealed box).
        guard let plaintext = LocalLLMKVCache.decryptBlob(at: path) else {
            nlLog(
                "[KVCache] Decryption failed at \(filename); purging and falling back to cold prefill",
                level: .warning)
            LocalLLMKVCache.purge(at: path)
            return
        }

        // Write decrypted bytes to a temp file for the bridge to load, then
        // delete immediately — keeps plaintext off disk as briefly as possible.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("kvcache_load_\(UUID().uuidString).kv")
        do {
            try plaintext.write(to: tmp, options: .atomic)
        } catch {
            nlLog("[KVCache] Failed to write temp load file: \(error)", level: .warning)
            return
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        let restored = await llmEngine.loadKVCache(from: tmp.path)
        if restored > 0 {
            kvCachePersistedThisSession = true
            nlLog("[KVCache] Restored \(restored) tokens from \(filename) (AES-GCM)", level: .info)
        } else {
            nlLog("[KVCache] Load returned 0 tokens from \(filename); next save will overwrite",
                  level: .warning)
        }
    }

    // MARK: - KV-cache persist

    /// Persist the current KV state to disk once per session, encrypted with
    /// AES-256-GCM. The cache key includes a hash of the system prompt so
    /// persona edits invalidate it automatically (new key → restore attempt
    /// fails → fresh prefill). The bridge saves a plaintext blob; this method
    /// immediately encrypts it in-place before returning.
    func persistKVCacheIfNeeded(
        config: LocalModelDownloadManager.ModelConfiguration,
        systemPrompt: String
    ) async {
        if kvCachePersistedThisSession { return }
        guard let path = LocalLLMKVCache.path(config: config, systemPrompt: systemPrompt)
        else { return }
        let filename = URL(fileURLWithPath: path).lastPathComponent
        let saved = await llmEngine.saveKVCache(to: path)
        if saved {
            // Encrypt the blob immediately after the bridge writes the plaintext
            // blob to disk. `encryptBlob` overwrites in-place with the AES-GCM
            // sealed box and also removes any legacy `.kv.hmac` sidecar.
            LocalLLMKVCache.encryptBlob(at: path)
            kvCachePersistedThisSession = true
            nlLog("[KVCache] Saved and encrypted \(filename)", level: .info)
        } else {
            nlLog("[KVCache] Save returned 0 bytes for \(filename) — bridge may be empty",
                  level: .warning)
        }
    }
}
