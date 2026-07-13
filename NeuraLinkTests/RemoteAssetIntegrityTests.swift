//
//  RemoteAssetIntegrityTests.swift
//  NeuraLinkTests
//
//  Locks in the download-integrity hardening: the SHA-256 helper, the
//  verify gate that keeps corrupt/tampered downloads out of the cache,
//  and completeness of the pinned-hash table over every registry asset.
//
//  Created by Dedicatus on 09/07/2026.
//

import Foundation
import Testing

@testable import NeuraLink

@Suite("Remote Asset Integrity")
struct RemoteAssetIntegrityTests {

    /// Writes `data` to a unique temp file and returns its URL.
    private func tempFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("integrity-\(UUID().uuidString).bin")
        try data.write(to: url)
        return url
    }

    @Test("SHA-256 helper matches a known vector")
    func testSHA256KnownVector() throws {
        // NIST test vector: SHA-256("abc").
        let url = try tempFile(Data("abc".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let hash = try RemoteAssetCache.sha256Hex(of: url)
        #expect(hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("Verify accepts a file matching its pin")
    func testVerifyAcceptsMatch() throws {
        let data = Data("hello integrity".utf8)
        let url = try tempFile(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let pin = RemoteAssetRegistry.AssetIntegrity(
            size: Int64(data.count),
            sha256: try RemoteAssetCache.sha256Hex(of: url))
        try RemoteAssetCache.verify(fileAt: url, against: pin)  // must not throw
    }

    @Test("Verify rejects a wrong size before hashing")
    func testVerifyRejectsWrongSize() throws {
        let url = try tempFile(Data("truncated".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let pin = RemoteAssetRegistry.AssetIntegrity(
            size: 999_999, sha256: String(repeating: "0", count: 64))
        do {
            try RemoteAssetCache.verify(fileAt: url, against: pin)
            Issue.record("expected sizeMismatch, but verify succeeded")
        } catch RemoteAssetCache.CacheError.sizeMismatch {
            // Expected.
        } catch {
            Issue.record("expected sizeMismatch, got \(error)")
        }
    }

    @Test("Verify rejects a wrong hash")
    func testVerifyRejectsWrongHash() throws {
        let data = Data("tampered contents".utf8)
        let url = try tempFile(data)
        defer { try? FileManager.default.removeItem(at: url) }
        let pin = RemoteAssetRegistry.AssetIntegrity(
            size: Int64(data.count), sha256: String(repeating: "0", count: 64))
        do {
            try RemoteAssetCache.verify(fileAt: url, against: pin)
            Issue.record("expected checksumMismatch, but verify succeeded")
        } catch RemoteAssetCache.CacheError.checksumMismatch {
            // Expected.
        } catch {
            Issue.record("expected checksumMismatch, got \(error)")
        }
    }

    @Test("Verify is a no-op without a pin")
    func testVerifySkipsWithoutPin() throws {
        let url = try tempFile(Data("anything".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        try RemoteAssetCache.verify(fileAt: url, against: nil)  // must not throw
    }

    @Test("Every shipped registry asset has a pinned integrity")
    func testIntegrityTableCompleteness() {
        var assets: [RemoteAssetRegistry] = [
            .openVoiceMelo, .openVoiceConverter, .openVoiceBert, .whisperModel
        ]
        assets += RemoteAssetRegistry.voicevoxSpeakerIDs.map { .voicevoxSpeaker($0) }
        assets += RemoteAssetRegistry.jtalkDictFilenames.map { .jtalkDictFile($0) }
        assets += ["apartment", "art_gallery", "campus", "city", "ruined_city"]
            .map { .scene($0) }

        for asset in assets {
            #expect(asset.integrity != nil, "missing pin for \(asset.pathInRepo)")
        }
        // Sanity: pins carry plausible values (64-hex hash, positive size).
        for asset in assets {
            guard let pin = asset.integrity else { continue }
            #expect(pin.size > 0)
            #expect(pin.sha256.count == 64)
            #expect(pin.sha256 == pin.sha256.lowercased())
        }
    }

    @Test("Unknown scenes have no pin (download unverified, not rejected)")
    func testUnknownSceneHasNoPin() {
        #expect(RemoteAssetRegistry.scene("future_scene_added_upstream").integrity == nil)
    }

    // The environment loader must retry transient failures (holding the launch
    // loading screen) but exit silently when superseded by a manual Retry —
    // misclassifying a cancel as a failure would double-fire the reveal gate.
    @Test("Cancellation classification for the environment retry loop")
    func testIsCancellation() {
        #expect(VRMRenderer.isCancellation(CancellationError()))
        #expect(VRMRenderer.isCancellation(URLError(.cancelled)))
        #expect(
            VRMRenderer.isCancellation(
                RemoteAssetCache.CacheError.downloadFailed(URLError(.cancelled))))
        #expect(
            VRMRenderer.isCancellation(
                RemoteAssetCache.CacheError.downloadFailed(CancellationError())))

        #expect(!VRMRenderer.isCancellation(URLError(.timedOut)))
        #expect(
            !VRMRenderer.isCancellation(
                RemoteAssetCache.CacheError.downloadFailed(URLError(.networkConnectionLost))))
        #expect(!VRMRenderer.isCancellation(RemoteAssetCache.CacheError.httpStatus(500)))
    }
}
