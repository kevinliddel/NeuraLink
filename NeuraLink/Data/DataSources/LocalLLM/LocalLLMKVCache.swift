//
//  LocalLLMKVCache.swift
//  NeuraLink
//
//  Derives on-disk paths for persisted llama.cpp KV cache state and provides
//  AES-256-GCM encryption + integrity protection for the blobs.
//
//  Cache key components:
//    - model configuration ("llama1b" / "japaneseLlama1b" / etc.)
//    - llama.cpp sequence-state format version (LLAMA_STATE_SEQ_VERSION) so an
//      upgrade that changes the on-disk format orphans old blobs deterministically
//      (and reuses them when the format is unchanged)
//    - SHA-256 prefix of the system prompt (so persona edits invalidate
//      the cache automatically rather than restoring a stale prefix)
//
//  Security model:
//    Every `.kv` blob is encrypted with AES-256-GCM before writing to disk.
//    The sealed box format (12-byte nonce + ciphertext + 16-byte GCM tag) is
//    written as a single `.kv` file — no separate sidecar required; the GCM
//    authentication tag already provides integrity coverage identical to (and
//    stronger than) the previous HMAC-SHA256 sidecar approach.
//
//    Migration: existing plaintext `.kv` + `.kv.hmac` files written by prior
//    builds are detected by a failed `AES.GCM.open`. If `verifyLegacyHMAC`
//    still vouches for the blob it is salvaged and re-encrypted in place
//    (see `tryRestoreKVCache`), preserving the warm start across the
//    upgrade; otherwise the blob is purged and a cold prefill runs. The
//    `.kv.hmac` sidecar is swept on either path.
//
//  Created by Dedicatus on 20/05/2026.
//

import CryptoKit
import Foundation

enum LocalLLMKVCache {

    /// Returns the on-disk path for the given config + system prompt, or
    /// nil if the directory could not be created. All shipped local engines
    /// (Llama-1B, LLM-jp-3, Qwen-2B) are `LlamaBridge`-backed and participate.
    static func path(
        config: LocalModelDownloadManager.ModelConfiguration,
        systemPrompt: String
    ) -> String? {
        guard let dir = supportDir() else { return nil }

        let configKey: String
        switch config {
        case .llama1b: configKey = "llama1b"
        // The JP slot's model has changed (Llama-1B → Gemma 2 2B → LLM-jp-3
        // 1.8B). The configKey is bumped to "llmjp3_18b" so a KV blob written
        // by a previous model is never restored into this one — different
        // vocab/dims would corrupt or fail the state-seq load. Orphaned old
        // blobs are harmless (cleaned by the version-token sweep / cache purge).
        case .llmJp3: configKey = "llmjp3_18b"
        }
        let personaKey = sha256Prefix(systemPrompt, length: 16)
        let versionKey = "v\(LlamaBridge.stateSeqVersion)"

        // One-time migration: the pre-versioning blob for this exact
        // config+persona (filename without the version token) can never be
        // safely loaded by a newer state format. Remove it and its sidecar so
        // it doesn't linger as dead disk after the upgrade. Deterministic —
        // targets only this persona's legacy file, no directory globbing.
        let legacy = dir.appendingPathComponent("\(configKey)_\(personaKey).kv").path
        if FileManager.default.fileExists(atPath: legacy) {
            purge(at: legacy)
        }

        return dir.appendingPathComponent("\(configKey)_\(versionKey)_\(personaKey).kv").path
    }

    // MARK: - AES-GCM Encryption / Decryption

    /// Encrypts the blob at `path` with AES-256-GCM and overwrites the file
    /// with the sealed box (nonce + ciphertext + tag). Cleans up any legacy
    /// `.kv.hmac` sidecar left by previous HMAC-only builds.
    ///
    /// Best-effort: Keychain or encryption failures are logged but never
    /// surface to the caller — losing encryption coverage degrades to
    /// "no faster than cold prefill" on the next launch, never to
    /// "blocks the user".
    static func encryptBlob(at path: String) {
        let url = URL(fileURLWithPath: path)
        guard let plaintext = try? Data(contentsOf: url) else {
            nlLog(
                "[LocalLLMKVCache] encryptBlob: cannot read \(url.lastPathComponent)",
                level: .warning)
            return
        }

        let key: Data
        do {
            key = try SecureStore.getOrCreateRandom(.kvCacheEncryptionKey, bytes: 32)
        } catch {
            nlLog(
                "[LocalLLMKVCache] encryptBlob: encryption key unavailable, skipping: \(error)",
                level: .warning)
            return
        }

        do {
            let symmetric = SymmetricKey(data: key)
            let sealed = try AES.GCM.seal(plaintext, using: symmetric)
            guard let combined = sealed.combined else {
                nlLog(
                    "[LocalLLMKVCache] encryptBlob: combined sealed box is nil (nonce not contiguous)",
                    level: .warning)
                return
            }
            try combined.write(to: url, options: .atomic)
            try? ProtectedStorage.protect(url)
            // Clean up legacy HMAC sidecar if present.
            removeLegacyHMACSidecar(for: url)
            nlLog(
                "[LocalLLMKVCache] encryptBlob: \(url.lastPathComponent) sealed (\(combined.count) bytes)",
                level: .debug)
        } catch {
            nlLog(
                "[LocalLLMKVCache] encryptBlob: AES-GCM seal failed: \(error)",
                level: .warning)
        }
    }

    /// Decrypts and verifies the blob at `path`. Returns the plaintext data on
    /// success, or `nil` if the file is missing, unreadable, the Keychain key
    /// is unavailable, or the GCM authentication tag does not match.
    ///
    /// Callers must `purge(at:)` and fall back to cold prefill on `nil`.
    static func decryptBlob(at path: String) -> Data? {
        let url = URL(fileURLWithPath: path)
        guard let ciphertext = try? Data(contentsOf: url) else {
            return nil
        }

        let key: Data
        do {
            key = try SecureStore.getOrCreateRandom(.kvCacheEncryptionKey, bytes: 32)
        } catch {
            nlLog(
                "[LocalLLMKVCache] decryptBlob: encryption key unavailable: \(error)",
                level: .warning)
            return nil
        }

        do {
            let symmetric = SymmetricKey(data: key)
            let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
            // `AES.GCM.open` verifies the authentication tag (constant-time) and
            // only returns plaintext if the tag matches — integrity is guaranteed.
            let plaintext = try AES.GCM.open(sealedBox, using: symmetric)
            return plaintext
        } catch {
            // Not a valid sealed box (e.g. legacy plaintext blob) or tag mismatch.
            nlLog(
                "[LocalLLMKVCache] decryptBlob: AES-GCM open failed for \(url.lastPathComponent): \(error)",
                level: .warning)
            return nil
        }
    }

    // MARK: - Legacy HMAC compatibility (kept for migration sweep only)

    /// Verifies the `.kv.hmac` sidecar written by pre-AES-GCM builds.
    /// Returns `true` only on a clean HMAC-SHA256 match; missing sidecar or
    /// any error returns `false`. Used exclusively in the migration path to
    /// salvage unencrypted blobs from older installs.
    static func verifyLegacyHMAC(at path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let sidecarURL = url.appendingPathExtension("hmac")

        guard
            let blob = try? Data(contentsOf: url),
            let storedTag = try? Data(contentsOf: sidecarURL)
        else {
            return false
        }

        let key: Data
        do {
            key = try SecureStore.getOrCreateRandom(.kvCacheHMACKey, bytes: 32)
        } catch {
            return false
        }

        let symmetric = SymmetricKey(data: key)
        var message = blob
        message.append(Data(url.lastPathComponent.utf8))
        return HMAC<SHA256>.isValidAuthenticationCode(storedTag, authenticating: message, using: symmetric)
    }

    // MARK: - Purge

    /// Idempotently removes the `.kv` blob, any `.kv.hmac` HMAC sidecar, and
    /// any other related artifacts. Used when decryption fails or when an
    /// upgrade needs to invalidate the previously written cache.
    static func purge(at path: String) {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        try? fm.removeItem(at: url)
        removeLegacyHMACSidecar(for: url)
    }

    // MARK: - Internals

    private static func removeLegacyHMACSidecar(for url: URL) {
        let sidecarURL = url.appendingPathExtension("hmac")
        if FileManager.default.fileExists(atPath: sidecarURL.path) {
            try? FileManager.default.removeItem(at: sidecarURL)
        }
    }

    private static func supportDir() -> URL? {
        let fm = FileManager.default
        guard
            let base = try? fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        else { return nil }
        let dir = base.appendingPathComponent("llm_kv", isDirectory: true)

        // Create the directory with the Data Protection class baked in;
        // files written under it inherit the class. For dirs that already
        // exist from previous builds, fall through to `setAttributes`
        // below to upgrade them in place.
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
                ])
        } else {
            try? fm.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: dir.path)
        }
        return dir
    }

    private static func sha256Prefix(_ input: String, length: Int) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(length))
    }
}
