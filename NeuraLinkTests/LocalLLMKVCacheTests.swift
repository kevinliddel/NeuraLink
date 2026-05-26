//
//  LocalLLMKVCacheTests.swift
//  NeuraLinkTests
//
//  Validates the HMAC-SHA256 integrity layer on persisted KV cache
//  blobs: sign/verify round-trip, tamper detection on both the blob
//  and the sidecar, idempotent purge.
//
//  Created by Dedicatus on 26/05/2026.
//

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

/// Suite is serialized because all tests share `SecureKey.kvCacheHMACKey`;
/// concurrent `getOrCreateRandom` calls race on first-use generation.
/// Suite is skipped when Keychain is unavailable (CI runners without
/// entitlement) — production / local-simulator paths exercise the real
/// code.
@Suite(
    "Local LLM KV Cache Integrity Tests",
    .serialized,
    .disabled(
        if: !kvCacheTestsKeychainAvailable(),
        "Keychain unavailable in this environment (likely CI without entitlement)"))
struct LocalLLMKVCacheTests {

    /// Happy path: signing a fresh blob and then verifying returns true.
    /// Implicit assertion that the HMAC key is reused across sign/verify
    /// (would fail if `getOrCreateRandom` returned a different value on
    /// the second call).
    @Test("Sign + verify round-trip returns true")
    func testSignVerifyRoundTrip() throws {
        let url = makeTempKVPath()
        defer { LocalLLMKVCache.purge(at: url.path) }

        let blob = Data((0..<256).map { UInt8($0 % 256) })
        try blob.write(to: url, options: .atomic)

        LocalLLMKVCache.signIntegrity(at: url.path)
        #expect(LocalLLMKVCache.verifyIntegrity(at: url.path))
    }

    /// Tampering with the `.kv` payload after signing must invalidate.
    /// This is the load-time guarantee: an attacker who flips even one
    /// byte of the blob between save and load cannot pass verification.
    @Test("Mutating the .kv payload fails verification")
    func testTamperedBlobFailsVerify() throws {
        let url = makeTempKVPath()
        defer { LocalLLMKVCache.purge(at: url.path) }

        let blob = Data(repeating: 0xAA, count: 128)
        try blob.write(to: url, options: .atomic)
        LocalLLMKVCache.signIntegrity(at: url.path)

        // Flip the first byte. HMAC over the modified blob no longer
        // matches the sidecar.
        var mutated = blob
        mutated[0] = 0xBB
        try mutated.write(to: url, options: .atomic)

        #expect(!LocalLLMKVCache.verifyIntegrity(at: url.path))
    }

    /// Tampering with the sidecar tag alone (without modifying the blob)
    /// must also invalidate — covers an attacker who keeps the blob the
    /// same but overwrites the sidecar with random bytes.
    @Test("Mutating the sidecar tag fails verification")
    func testTamperedSidecarFailsVerify() throws {
        let url = makeTempKVPath()
        defer { LocalLLMKVCache.purge(at: url.path) }

        let blob = Data(repeating: 0xCD, count: 64)
        try blob.write(to: url, options: .atomic)
        LocalLLMKVCache.signIntegrity(at: url.path)

        let sidecarURL = url.appendingPathExtension("hmac")
        try Data(repeating: 0x00, count: 32).write(to: sidecarURL, options: .atomic)

        #expect(!LocalLLMKVCache.verifyIntegrity(at: url.path))
    }

    /// A previous blob has no sidecar at all. Verification must fail
    /// closed so the caller purges and cold-prefills instead of trusting
    /// an unsigned blob.
    @Test("Missing sidecar fails verification (pre-Phase-5 upgrade case)")
    func testMissingSidecarFailsVerify() throws {
        let url = makeTempKVPath()
        defer { LocalLLMKVCache.purge(at: url.path) }

        let blob = Data(repeating: 0xEF, count: 64)
        try blob.write(to: url, options: .atomic)
        // No signIntegrity call — sidecar deliberately absent.

        #expect(!LocalLLMKVCache.verifyIntegrity(at: url.path))
    }

    /// `purge` removes both the `.kv` and the `.kv.hmac` sidecar, and is
    /// safe to call on missing files (e.g. if a prior purge already ran).
    @Test("Purge removes both files and is idempotent")
    func testPurgeIsIdempotent() throws {
        let url = makeTempKVPath()
        let sidecarURL = url.appendingPathExtension("hmac")
        let fileManager = FileManager.default

        try Data([0x01]).write(to: url, options: .atomic)
        LocalLLMKVCache.signIntegrity(at: url.path)

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
}
