//
//  LocalLLMKVCacheTests.swift
//  NeuraLinkTests
//
//  Validates the AES-256-GCM encryption layer on persisted KV cache
//  blobs: encrypt/decrypt round-trip, tamper detection via the GCM
//  authentication tag, legacy HMAC-sidecar verification (migration
//  salvage path), idempotent purge.
//
//  Created by Dedicatus on 26/05/2026.
//

import CryptoKit
import Foundation
import Testing

@testable import NeuraLink

/// File-level rather than a static method on `LocalLLMKVCacheTests` so
/// the `@Suite(.disabled(if:))` trait can evaluate it during macro
/// expansion — a self-reference would loop. Same pattern as
/// `SQLCipherTests`.
private func kvCacheTestsKeychainAvailable() -> Bool {
    do {
        _ = try SecureStore.getData(.kvCacheHMACKey)
        return true
    } catch {
        return false
    }
}

/// Suite is serialized because all tests share the Keychain-backed keys
/// (`kvCacheEncryptionKey` / `kvCacheHMACKey`); concurrent
/// `getOrCreateRandom` calls race on first-use generation.
/// Suite is skipped when Keychain is unavailable (CI runners without
/// entitlement) — production / local-simulator paths exercise the real
/// code.
@Suite(
    "Local LLM KV Cache Encryption Tests",
    .serialized,
    .disabled(
        if: !kvCacheTestsKeychainAvailable(),
        "Keychain unavailable in this environment (likely CI without entitlement)"))
struct LocalLLMKVCacheTests {

    /// Happy path: encrypting a fresh blob rewrites the file as a sealed
    /// box (≠ plaintext on disk) and decrypting returns the original
    /// bytes. Implicit assertion that the encryption key is reused across
    /// seal/open (would fail if `getOrCreateRandom` returned a different
    /// value on the second call).
    @Test("Encrypt + decrypt round-trip returns original plaintext")
    func testEncryptDecryptRoundTrip() throws {
        let url = makeTempKVPath()
        defer { LocalLLMKVCache.purge(at: url.path) }

        let blob = Data((0..<256).map { UInt8($0 % 256) })
        try blob.write(to: url, options: .atomic)

        LocalLLMKVCache.encryptBlob(at: url.path)

        let onDisk = try Data(contentsOf: url)
        #expect(onDisk != blob, "Sealed box must not equal the plaintext")

        #expect(LocalLLMKVCache.decryptBlob(at: url.path) == blob)
    }

    /// Tampering with the ciphertext after sealing must fail the GCM
    /// authentication tag. This is the load-time guarantee: an attacker
    /// who flips even one byte of the blob between save and load cannot
    /// pass decryption.
    @Test("Mutating the sealed .kv payload fails decryption")
    func testTamperedCiphertextFailsDecrypt() throws {
        let url = makeTempKVPath()
        defer { LocalLLMKVCache.purge(at: url.path) }

        let blob = Data(repeating: 0xAA, count: 128)
        try blob.write(to: url, options: .atomic)
        LocalLLMKVCache.encryptBlob(at: url.path)

        // Flip one ciphertext byte (past the 12-byte nonce). The GCM tag
        // over the modified ciphertext no longer matches.
        var mutated = try Data(contentsOf: url)
        mutated[20] ^= 0xFF
        try mutated.write(to: url, options: .atomic)

        #expect(LocalLLMKVCache.decryptBlob(at: url.path) == nil)
    }

    /// A plaintext blob that was never sealed (legacy pre-encryption
    /// build) is not a valid sealed box — decryption must fail closed so
    /// the caller can route through the HMAC salvage path or purge.
    @Test("Legacy plaintext blob fails decryption")
    func testPlaintextBlobFailsDecrypt() throws {
        let url = makeTempKVPath()
        defer { LocalLLMKVCache.purge(at: url.path) }

        try Data(repeating: 0xEF, count: 64).write(to: url, options: .atomic)

        #expect(LocalLLMKVCache.decryptBlob(at: url.path) == nil)
    }

    /// Migration salvage path: a legacy plaintext blob with a valid
    /// HMAC-SHA256 sidecar passes `verifyLegacyHMAC`, and re-encrypting
    /// it in place removes the sidecar and yields a sealed box that
    /// decrypts back to the original bytes — exactly what
    /// `tryRestoreKVCache` does on first launch after the upgrade.
    @Test("Legacy HMAC blob is verifiable and re-encryptable in place")
    func testLegacyHMACSalvage() throws {
        let url = makeTempKVPath()
        defer { LocalLLMKVCache.purge(at: url.path) }

        let blob = Data(repeating: 0xCD, count: 64)
        try blob.write(to: url, options: .atomic)
        try writeLegacyHMACSidecar(for: url, blob: blob)

        #expect(LocalLLMKVCache.verifyLegacyHMAC(at: url.path))

        LocalLLMKVCache.encryptBlob(at: url.path)

        let sidecarURL = url.appendingPathExtension("hmac")
        #expect(!FileManager.default.fileExists(atPath: sidecarURL.path),
                "encryptBlob must sweep the legacy sidecar")
        #expect(LocalLLMKVCache.decryptBlob(at: url.path) == blob)
    }

    /// A tampered or missing sidecar must fail legacy verification so an
    /// unverifiable plaintext blob is purged rather than salvaged.
    @Test("Tampered or missing sidecar fails legacy verification")
    func testBadSidecarFailsLegacyVerify() throws {
        let url = makeTempKVPath()
        defer { LocalLLMKVCache.purge(at: url.path) }

        let blob = Data(repeating: 0xEF, count: 64)
        try blob.write(to: url, options: .atomic)

        // Missing sidecar.
        #expect(!LocalLLMKVCache.verifyLegacyHMAC(at: url.path))

        // Garbage sidecar.
        let sidecarURL = url.appendingPathExtension("hmac")
        try Data(repeating: 0x00, count: 32).write(to: sidecarURL, options: .atomic)
        #expect(!LocalLLMKVCache.verifyLegacyHMAC(at: url.path))
    }

    /// `purge` removes both the `.kv` blob and any legacy `.kv.hmac`
    /// sidecar, and is safe to call on missing files (e.g. if a prior
    /// purge already ran).
    @Test("Purge removes both files and is idempotent")
    func testPurgeIsIdempotent() throws {
        let url = makeTempKVPath()
        let sidecarURL = url.appendingPathExtension("hmac")
        let fileManager = FileManager.default

        try Data([0x01]).write(to: url, options: .atomic)
        try Data(repeating: 0x02, count: 32).write(to: sidecarURL, options: .atomic)

        #expect(fileManager.fileExists(atPath: url.path))
        #expect(fileManager.fileExists(atPath: sidecarURL.path))

        LocalLLMKVCache.purge(at: url.path)
        #expect(!fileManager.fileExists(atPath: url.path))
        #expect(!fileManager.fileExists(atPath: sidecarURL.path))

        // Second purge is a no-op, must not throw.
        LocalLLMKVCache.purge(at: url.path)
    }

    // MARK: - Helpers

    private func makeTempKVPath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("llm_kv_test_\(UUID().uuidString).kv")
    }

    /// Reproduces the legacy `signIntegrity` sidecar format exactly:
    /// HMAC-SHA256 over blob bytes + filename, keyed by `kvCacheHMACKey`.
    private func writeLegacyHMACSidecar(for url: URL, blob: Data) throws {
        let key = try SecureStore.getOrCreateRandom(.kvCacheHMACKey, bytes: 32)
        var hmac = HMAC<SHA256>(key: SymmetricKey(data: key))
        hmac.update(data: blob)
        hmac.update(data: Data(url.lastPathComponent.utf8))
        try Data(hmac.finalize()).write(
            to: url.appendingPathExtension("hmac"), options: .atomic)
    }
}
