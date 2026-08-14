//
//  ImportedCharacterStoreTests.swift
//  NeuraLinkTests
//
//  Unit tests for the `imported_characters` table (MemoryStore CRUD layer).
//  Each test uses its own slug/sha namespace and cleans up after itself —
//  the suite shares the app-host MemoryStore singleton like MemoryTests does.
//

import Testing
import Foundation
import UIKit
@testable import NeuraLink

@Suite("Imported Characters (SQL layer)")
struct ImportedCharacterStoreTests {

    /// Distinct draft per test; slug/sha collisions between tests would make
    /// parallel runs flaky, so every test derives both from its own tag.
    private func makeDraft(tag: String) -> ImportedCharacterDraft {
        ImportedCharacterDraft(
            slug: "test_ic_\(tag)",
            displayName: "Test \(tag.capitalized)",
            filePath: "characters/test_ic_\(tag).vrm",
            fileSize: 12_345,
            sha256: Self.fakeSha(tag: tag),
            thumbnailPath: "characters/test_ic_\(tag).png",
            sourceFilename: "\(tag) original.vrm",
            vrmSpec: "1.0",
            metaName: "Meta \(tag)",
            metaAuthors: "Author A, Author B",
            metaLicenseURL: "https://example.com/license",
            metaAvatarPermission: "everyone",
            metaCommercialUsage: "personalNonProfit"
        )
    }

    /// Deterministic 64-char lowercase hex derived from the tag.
    private static func fakeSha(tag: String) -> String {
        let seed = tag.unicodeScalars.reduce(into: "") { acc, scalar in
            acc += String(format: "%02x", scalar.value % 256)
        }
        return String(seed.padding(toLength: 64, withPad: "0", startingAt: 0))
    }

    private func cleanup(_ slugs: String...) {
        for slug in slugs {
            MemoryStore.shared.deleteImportedCharacter(slug: slug)
            MemoryStore.shared.deletePersonaRows(character: slug)
        }
    }

    @Test("Insert and fetch round-trips every column")
    func insertRoundTrip() {
        let draft = makeDraft(tag: "roundtrip")
        cleanup(draft.slug)
        defer { cleanup(draft.slug) }

        let inserted = MemoryStore.shared.insertImportedCharacter(draft)
        #expect(inserted != nil)
        #expect(inserted?.slug == draft.slug)
        #expect(inserted?.displayName == draft.displayName)
        #expect(inserted?.filePath == draft.filePath)
        #expect(inserted?.fileSize == draft.fileSize)
        #expect(inserted?.sha256 == draft.sha256)
        #expect(inserted?.thumbnailPath == draft.thumbnailPath)
        #expect(inserted?.sourceFilename == draft.sourceFilename)
        #expect(inserted?.vrmSpec == draft.vrmSpec)
        #expect(inserted?.metaName == draft.metaName)
        #expect(inserted?.metaAuthors == draft.metaAuthors)
        #expect(inserted?.metaLicenseURL == draft.metaLicenseURL)
        #expect(inserted?.metaAvatarPermission == draft.metaAvatarPermission)
        #expect(inserted?.metaCommercialUsage == draft.metaCommercialUsage)
        #expect(inserted?.quarantined == false)

        let fetched = MemoryStore.shared.importedCharacter(slug: draft.slug)
        #expect(fetched == inserted)
    }

    @Test("Nullable columns store and read back as nil")
    func nullableColumns() {
        var draft = makeDraft(tag: "nullable")
        draft.thumbnailPath = nil
        draft.sourceFilename = nil
        draft.vrmSpec = nil
        draft.metaName = nil
        draft.metaAuthors = nil
        draft.metaLicenseURL = nil
        draft.metaAvatarPermission = nil
        draft.metaCommercialUsage = nil
        cleanup(draft.slug)
        defer { cleanup(draft.slug) }

        let inserted = MemoryStore.shared.insertImportedCharacter(draft)
        #expect(inserted?.thumbnailPath == nil)
        #expect(inserted?.sourceFilename == nil)
        #expect(inserted?.vrmSpec == nil)
        #expect(inserted?.metaName == nil)
    }

    @Test("Slug is unique — second insert is rejected")
    func slugUnique() {
        let draft = makeDraft(tag: "slugdupe")
        cleanup(draft.slug)
        defer { cleanup(draft.slug) }

        #expect(MemoryStore.shared.insertImportedCharacter(draft) != nil)

        // Same slug, different content hash: still rejected.
        let secondDraft = ImportedCharacterDraft(
            slug: draft.slug, displayName: "Other", filePath: "characters/other.vrm",
            fileSize: 1, sha256: Self.fakeSha(tag: "slugdupe_other"))
        #expect(MemoryStore.shared.insertImportedCharacter(secondDraft) == nil)
    }

    @Test("sha256 is unique — same bytes under a new slug are rejected")
    func shaUnique() {
        let draft = makeDraft(tag: "shadupe")
        cleanup(draft.slug, "test_ic_shadupe_b")
        defer { cleanup(draft.slug, "test_ic_shadupe_b") }

        #expect(MemoryStore.shared.insertImportedCharacter(draft) != nil)

        let sameBytes = ImportedCharacterDraft(
            slug: "test_ic_shadupe_b", displayName: "Copy",
            filePath: "characters/test_ic_shadupe_b.vrm",
            fileSize: draft.fileSize, sha256: draft.sha256)
        #expect(MemoryStore.shared.insertImportedCharacter(sameBytes) == nil)

        // And the duplicate is findable by hash for the "already imported" UX.
        let byHash = MemoryStore.shared.importedCharacter(sha256: draft.sha256)
        #expect(byHash?.slug == draft.slug)
    }

    @Test("Slug and sha are normalized to lowercase on insert and lookup")
    func lowercaseNormalization() {
        let tag = "casefold"
        let slug = "test_ic_\(tag)"
        cleanup(slug)
        defer { cleanup(slug) }

        let draft = ImportedCharacterDraft(
            slug: "TEST_IC_CASEFOLD", displayName: "Case",
            filePath: "characters/\(slug).vrm", fileSize: 1,
            sha256: Self.fakeSha(tag: tag).uppercased())
        let inserted = MemoryStore.shared.insertImportedCharacter(draft)
        #expect(inserted?.slug == slug)
        #expect(inserted?.sha256 == Self.fakeSha(tag: tag))
        #expect(MemoryStore.shared.importedCharacter(slug: "TEST_IC_CASEFOLD") != nil)
    }

    @Test("Quarantine hides a row from the default fetch")
    func quarantineFiltering() {
        let draft = makeDraft(tag: "quarantine")
        cleanup(draft.slug)
        defer { cleanup(draft.slug) }

        #expect(MemoryStore.shared.insertImportedCharacter(draft) != nil)
        MemoryStore.shared.setImportedCharacterQuarantined(slug: draft.slug, true)

        let visible = MemoryStore.shared.fetchImportedCharacters()
        #expect(!visible.contains { $0.slug == draft.slug })

        let all = MemoryStore.shared.fetchImportedCharacters(includeQuarantined: true)
        let row = all.first { $0.slug == draft.slug }
        #expect(row?.quarantined == true)

        MemoryStore.shared.setImportedCharacterQuarantined(slug: draft.slug, false)
        #expect(MemoryStore.shared.importedCharacter(slug: draft.slug)?.quarantined == false)
    }

    @Test("Display-name update persists")
    func renamePersists() {
        let draft = makeDraft(tag: "rename")
        cleanup(draft.slug)
        defer { cleanup(draft.slug) }

        #expect(MemoryStore.shared.insertImportedCharacter(draft) != nil)
        MemoryStore.shared.updateImportedCharacterDisplayName(slug: draft.slug, displayName: "Renamed")
        #expect(MemoryStore.shared.importedCharacter(slug: draft.slug)?.displayName == "Renamed")
    }

    @Test("Card image set/remove round-trips the file and SQL path")
    @MainActor
    func thumbnailRoundTrip() throws {
        var draft = makeDraft(tag: "thumb")
        draft.thumbnailPath = nil  // exercise the path-backfill branch
        cleanup(draft.slug)
        defer { cleanup(draft.slug) }

        #expect(MemoryStore.shared.insertImportedCharacter(draft) != nil)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10))
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        let pngData = try #require(image.pngData())

        ImportedCharacterStore.shared.setThumbnail(slug: draft.slug, imageData: pngData)
        let updated = MemoryStore.shared.importedCharacter(slug: draft.slug)
        #expect(updated?.thumbnailPath == "characters/\(draft.slug).png")
        let fileURL = try #require(updated?.thumbnailURL)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        ImportedCharacterStore.shared.setThumbnail(slug: draft.slug, imageData: nil)
        let cleared = MemoryStore.shared.importedCharacter(slug: draft.slug)
        #expect(cleared?.thumbnailPath == nil)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("Delete removes the row; persona rows are cleaned separately")
    func deleteRemovesRow() {
        let draft = makeDraft(tag: "delete")
        cleanup(draft.slug)

        #expect(MemoryStore.shared.insertImportedCharacter(draft) != nil)

        // Simulate the persona rows the setup flow would write.
        MemoryStore.shared.setPersonaPrompt(
            character: draft.slug, engine: MemoryStore.PersonaEngine.local, prompt: "test prompt")
        MemoryStore.shared.setPersonaVoice(
            character: draft.slug, engine: MemoryStore.PersonaEngine.local, voice: "riko")

        MemoryStore.shared.deleteImportedCharacter(slug: draft.slug)
        MemoryStore.shared.deletePersonaRows(character: draft.slug)

        #expect(MemoryStore.shared.importedCharacter(slug: draft.slug) == nil)
        #expect(MemoryStore.shared.personaPrompt(
            character: draft.slug, engine: MemoryStore.PersonaEngine.local) == nil)
        #expect(MemoryStore.shared.personaVoice(
            character: draft.slug, engine: MemoryStore.PersonaEngine.local) == nil)
    }
}
