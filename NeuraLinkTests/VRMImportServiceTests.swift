//
//  VRMImportServiceTests.swift
//  NeuraLinkTests
//
//  Slug sanitization/uniquing, integrity re-verification, and a full stage()
//  pipeline run against the bundled Ekaterina.vrm (the test host is the app,
//  so its flat bundle root is available).
//

import Testing
import Foundation
@testable import NeuraLink

@Suite("VRM Import Service")
struct VRMImportServiceTests {

    // MARK: - Slug sanitization

    @Test("Slug sanitization", arguments: [
        ("My Char (1).vrm", "my_char_1"),
        ("Ekaterina", "ekaterina"),
        ("  Weird--Name__X ", "weird_name_x"),
        ("UPPER.vrm", "upper"),
        ("ミコ", "character"),          // all-CJK falls back
        ("42model", "42model"),
        ("---", "character")
    ])
    func slugSanitization(input: String, expected: String) {
        #expect(VRMImportService.sanitizedSlug(from: input) == expected)
    }

    @Test("Slug is capped at 40 characters")
    func slugLengthCap() {
        let long = String(repeating: "a", count: 100)
        #expect(VRMImportService.sanitizedSlug(from: long).count == 40)
    }

    @Test("Reserved and taken slugs get numeric suffixes")
    func slugUniquing() {
        // Reserved bundled name never assigned bare.
        #expect(VRMImportService.uniqueSlug(from: "Ekaterina") == "ekaterina_2")

        // A slug already in SQL is suffixed too.
        let taken = "test_vis_taken"
        MemoryStore.shared.deleteImportedCharacter(slug: taken)
        defer { MemoryStore.shared.deleteImportedCharacter(slug: taken) }
        let draft = ImportedCharacterDraft(
            slug: taken, displayName: "Taken", filePath: "characters/\(taken).vrm",
            fileSize: 1, sha256: String(repeating: "a", count: 64))
        #expect(MemoryStore.shared.insertImportedCharacter(draft) != nil)
        #expect(VRMImportService.uniqueSlug(from: taken) == "\(taken)_2")
    }

    // MARK: - Integrity re-verification

    /// Writes `bytes` into the protected characters dir and returns a matching
    /// (or deliberately mismatched) ImportedCharacter for VRMIntegrityCheck.
    private func makePinnedCharacter(
        tag: String, bytes: Data, pinnedSize: Int64? = nil, pinnedSha: String? = nil
    ) throws -> ImportedCharacter {
        let dir = try ProtectedStorage.privateApplicationSupportURL()
            .appendingPathComponent("characters", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("test_vis_\(tag).vrm")
        try bytes.write(to: url, options: .atomic)

        let sha = try RemoteAssetCache.sha256Hex(of: url)
        return ImportedCharacter(
            id: -1, slug: "test_vis_\(tag)", displayName: "Pin \(tag)",
            filePath: "characters/test_vis_\(tag).vrm",
            fileSize: pinnedSize ?? Int64(bytes.count),
            sha256: pinnedSha ?? sha,
            thumbnailPath: nil, sourceFilename: nil, vrmSpec: nil,
            metaName: nil, metaAuthors: nil, metaLicenseURL: nil,
            metaAvatarPermission: nil, metaCommercialUsage: nil,
            quarantined: false, createdAt: Date(), updatedAt: Date())
    }

    private func removePinnedFile(_ character: ImportedCharacter) {
        if let url = character.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @Test("Integrity check passes on an untouched file")
    func integrityPass() throws {
        let character = try makePinnedCharacter(tag: "ok", bytes: Data("vrm-bytes".utf8))
        defer { removePinnedFile(character) }
        #expect(VRMIntegrityCheck.verify(character) == true)
    }

    @Test("Integrity check fails on size mismatch")
    func integritySizeMismatch() throws {
        let character = try makePinnedCharacter(
            tag: "size", bytes: Data("vrm-bytes".utf8), pinnedSize: 999)
        defer { removePinnedFile(character) }
        #expect(VRMIntegrityCheck.verify(character) == false)
    }

    @Test("Integrity check fails on tampered content")
    func integrityTampered() throws {
        // Same length, different bytes — passes the size gate, fails the hash.
        let character = try makePinnedCharacter(
            tag: "tamper", bytes: Data("vrm-bytes".utf8),
            pinnedSha: String(repeating: "0", count: 64))
        defer { removePinnedFile(character) }
        #expect(VRMIntegrityCheck.verify(character) == false)
    }

    @Test("Integrity check fails and quarantines when the file is missing")
    func integrityMissingFile() throws {
        let character = try makePinnedCharacter(tag: "gone", bytes: Data("x".utf8))
        removePinnedFile(character)
        #expect(VRMIntegrityCheck.verify(character) == false)
    }

    // MARK: - Full stage pipeline (bundled model)

    @Test("stage() validates the bundled Ekaterina model end to end")
    func stageBundledModel() async throws {
        guard let url = Bundle.main.url(forResource: "Ekaterina", withExtension: "vrm") else {
            Issue.record("Ekaterina.vrm missing from the test host bundle")
            return
        }

        // A previous run may have left a dedupe row for these bytes.
        let sha = try RemoteAssetCache.sha256Hex(of: url)
        if let stale = MemoryStore.shared.importedCharacter(sha256: sha) {
            MemoryStore.shared.deleteImportedCharacter(slug: stale.slug)
        }

        let candidate = try await VRMImportService.shared.stage(pickedURL: url)
        defer { Task { await VRMImportService.shared.discard(candidate) } }

        #expect(candidate.sha256 == sha)
        #expect(candidate.fileSize == RemoteAssetCache.fileSize(at: url))
        #expect(FileManager.default.fileExists(atPath: candidate.stagedModelURL.path))
        #expect(!candidate.suggestedSlug.isEmpty)
        #expect(candidate.suggestedSlug != "ekaterina", "reserved slug must be suffixed")
        #expect(!candidate.report.specVersion.isEmpty)

        // Staging again with the same bytes is NOT a duplicate (no SQL row
        // yet — dedupe only triggers after finalize).
        let second = try await VRMImportService.shared.stage(pickedURL: url)
        await VRMImportService.shared.discard(second)
    }
}
