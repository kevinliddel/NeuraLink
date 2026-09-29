//
//  AppearanceStoreTests.swift
//  NeuraLinkTests
//
//  SQL persistence of the per-character look (`character_appearance`).
//  Shares the app-host MemoryStore singleton like the other store suites;
//  every test uses its own slug and cleans up.
//

import Testing
import Foundation
@testable import NeuraLink

@Suite("Appearance store (SQL layer)", .serialized)
struct AppearanceStoreTests {

    @Test("Upsert, read back, delete")
    func crud() throws {
        let slug = "test_appearance_crud"
        defer { MemoryStore.shared.deleteAppearanceSpec(character: slug) }

        #expect(MemoryStore.shared.appearanceSpecJSON(character: slug) == nil)

        var spec = AppearanceSpec()
        spec.recolors[.hair] = SlotRecolor(hueShift: 120)
        MemoryStore.shared.setAppearanceSpecJSON(try spec.jsonString(), character: slug.uppercased())
        let read = try #require(AppearanceStore.specFromSQL(slug: slug))
        #expect(read == spec, "keys are lowercased on write and read")

        spec.recolors[.hair] = SlotRecolor(hueShift: -30)
        MemoryStore.shared.setAppearanceSpecJSON(try spec.jsonString(), character: slug)
        #expect(AppearanceStore.specFromSQL(slug: slug)?.recolors[.hair]?.hueShift == -30, "second write replaces")

        MemoryStore.shared.deleteAppearanceSpec(character: slug)
        #expect(MemoryStore.shared.appearanceSpecJSON(character: slug) == nil)
    }

    @Test("Facade: saving an empty spec deletes the row")
    @MainActor
    func facadeSaveEmptyDeletes() {
        let slug = "test_appearance_facade"
        defer { MemoryStore.shared.deleteAppearanceSpec(character: slug) }

        var spec = AppearanceSpec()
        spec.textures[.faceSkin] = DonorTextureRef(donorSlug: "sonya", slot: .faceSkin)
        AppearanceStore.shared.save(spec, for: slug)
        #expect(AppearanceStore.shared.hasCustomization(for: slug))

        var cleared = AppearanceSpec()
        cleared.recolors[.hair] = .identity
        AppearanceStore.shared.save(cleared, for: slug)
        #expect(AppearanceStore.shared.spec(for: slug) == nil)
        #expect(!AppearanceStore.shared.hasCustomization(for: slug))
    }

    @Test("Deleting an imported character cascades to its appearance row")
    @MainActor
    func cascadeOnImportedDelete() throws {
        let slug = "test_ic_appearance_cascade"
        let sha = String(repeating: "c", count: 64)
        defer {
            MemoryStore.shared.deleteImportedCharacter(slug: slug)
            MemoryStore.shared.deletePersonaRows(character: slug)
            MemoryStore.shared.deleteAppearanceSpec(character: slug)
        }
        let draft = ImportedCharacterDraft(
            slug: slug, displayName: "Cascade", filePath: "characters/\(slug).vrm",
            fileSize: 1, sha256: sha, thumbnailPath: nil, sourceFilename: nil, vrmSpec: "1.0",
            metaName: nil, metaAuthors: nil, metaLicenseURL: nil,
            metaAvatarPermission: nil, metaCommercialUsage: nil)
        _ = try #require(ImportedCharacterStore.shared.add(draft))

        var spec = AppearanceSpec()
        spec.recolors[.eyeIris] = SlotRecolor(hueShift: 60)
        AppearanceStore.shared.save(spec, for: slug)
        #expect(AppearanceStore.shared.hasCustomization(for: slug))

        ImportedCharacterStore.shared.delete(slug: slug)
        #expect(AppearanceStore.shared.spec(for: slug) == nil)
    }
}
