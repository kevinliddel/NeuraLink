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
        case .llama1b: configKey = "llama1b"
        case .japaneseLlama1b: configKey = "japaneseLlama1b"
        case .qwen2b: configKey = "qwen2b"
        case .qwen3b: configKey = "qwen3b"
        case .qwen7b: configKey = "qwen7b"
        }
        let personaKey = sha256Prefix(systemPrompt, length: 16)

        return dir.appendingPathComponent("\(configKey)_\(personaKey).kv").path
    }

    // MARK: - Integrity

    /// Sidecar suffix that holds the 32-byte HMAC-SHA256 tag for a `.kv`
    /// blob. Lives next to the .kv so a cleanup/move that loses one but
    /// keeps the other is detectable.
    private static let hmacSidecarSuffix = ".hmac"

    /// Computes HMAC-SHA256 over the blob bytes + filename and writes the
    /// 32-byte tag to a `.kv.hmac` sidecar. Called immediately after a
    /// successful `saveKVCache`. Binding the MAC to the filename means an
    /// attacker who renames `.kv` files across personas can't pass
    /// verification by also moving the sidecar — the verifier recomputes
    /// using the file's current name, which the attacker controlled but
    /// the sidecar's MAC didn't include.
    ///
    /// Best-effort: Keychain or filesystem failures are logged but don't
    /// surface to the caller — losing integrity coverage degrades to
    /// "no faster than cold prefill" on the next launch, never to
    /// "blocks the user".
    static func signIntegrity(at path: String) {
        let url = URL(fileURLWithPath: path)
        guard let blob = try? Data(contentsOf: url) else {
            nlLog(
                "[LocalLLMKVCache] signIntegrity: cannot read \(url.lastPathComponent)",
                level: .warning)
            return
        }

        let key: Data
        do {
            key = try SecureStore.getOrCreateRandom(.kvCacheHMACKey, bytes: 32)
        } catch {
            nlLog(
                "[LocalLLMKVCache] signIntegrity: HMAC key unavailable, skipping: \(error)",
                level: .warning)
            return
        }

        let mac = computeHMAC(blob: blob, filename: url.lastPathComponent, key: key)
        let sidecarURL = url.appendingPathExtension(String(hmacSidecarSuffix.dropFirst()))
        do {
            try mac.write(to: sidecarURL, options: .atomic)
            try? ProtectedStorage.protect(url)
            try? ProtectedStorage.protect(sidecarURL)
        } catch {
            nlLog(
                "[LocalLLMKVCache] signIntegrity: failed to write sidecar: \(error)",
                level: .warning)
        }
    }

    /// Verifies the `.kv.hmac` sidecar matches the current `.kv` content.
    /// Returns true only on a clean match. Missing sidecar (previously
    /// written before), missing key, read error, or tag mismatch all return
    /// false — callers should `purge()` and fall back to cold prefill on
    /// any false result, never load an unverified blob into the engine.
    static func verifyIntegrity(at path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let sidecarURL = url.appendingPathExtension(String(hmacSidecarSuffix.dropFirst()))

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
            nlLog(
                "[LocalLLMKVCache] verifyIntegrity: HMAC key unavailable: \(error)", level: .warning
            )
            return false
        }

        // `HMAC.isValidAuthenticationCode` is constant-time; raw `==` on
        // `Data` would leak timing on the first mismatching byte. The
        // local threat model doesn't include a timing attacker, but the
        // constant-time API costs nothing extra.
        let symmetric = SymmetricKey(data: key)
        var message = blob
        message.append(Data(url.lastPathComponent.utf8))
        return HMAC<SHA256>.isValidAuthenticationCode(
            storedTag, authenticating: message, using: symmetric)
    }

    /// Idempotently removes the `.kv` blob and its `.kv.hmac` sidecar.
    /// Used when integrity verification fails or when an upgrade needs
    /// to invalidate the previously written cache.
    static func purge(at path: String) {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        let sidecarURL = url.appendingPathExtension(String(hmacSidecarSuffix.dropFirst()))
        try? fm.removeItem(at: url)
        try? fm.removeItem(at: sidecarURL)
    }

    // MARK: - Internals

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

    private static func computeHMAC(blob: Data, filename: String, key: Data) -> Data {
        let symmetric = SymmetricKey(data: key)
        var hmac = HMAC<SHA256>(key: symmetric)
        hmac.update(data: blob)
        hmac.update(data: Data(filename.utf8))
        return Data(hmac.finalize())
    }
}
