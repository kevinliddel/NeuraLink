//
//  AppearanceSpecTests.swift
//  NeuraLinkTests
//
//  AppearanceSpec is the persisted shape of a character's look. Pins the
//  JSON round-trip, normalization (identity recolours vanish so "reset the
//  slider" == "never touched"), and tolerance of unknown slot keys from a
//  newer build.
//

import Testing
import Foundation
@testable import NeuraLink

@Suite("Appearance spec")
struct AppearanceSpecTests {

    @Test("Round-trips through JSON")
    func roundTrip() throws {
        var spec = AppearanceSpec()
        spec.recolors[.hair] = SlotRecolor(hueShift: 42, saturation: 1.2, brightness: 0.9)
        spec.recolors[.faceSkin] = SlotRecolor(hueShift: -5, saturation: 1, brightness: 1.1)
        spec.textures[.eyeIris] = DonorTextureRef(donorSlug: "Sonya", slot: .eyeIris)
        spec.parts[.hair] = "Sonya"

        let json = try spec.jsonString()
        let decoded = try #require(AppearanceSpec.fromJSON(json))
        #expect(decoded.recolors == spec.recolors && decoded.textures == spec.textures)
        #expect(decoded.parts == [.hair: "sonya"], "part donors are lowercased on decode")
        #expect(decoded.textures[.eyeIris]?.donorSlug == "sonya", "donor slugs are lowercased")
        #expect(decoded.schemaVersion == AppearanceSpec.currentSchemaVersion)
    }

    @Test("Identity recolours are dropped by normalize; empty spec detected")
    func normalize() {
        var spec = AppearanceSpec()
        spec.recolors[.hair] = .identity
        spec.recolors[.bodySkin] = SlotRecolor(hueShift: 0.001, saturation: 1.0002, brightness: 1)
        #expect(spec.isEmpty, "identity-only recolours count as empty")
        spec.normalize()
        #expect(spec.recolors.isEmpty)

        spec.recolors[.hair] = SlotRecolor(hueShift: 90)
        #expect(!spec.isEmpty)
        #expect(spec.normalized().recolors.count == 1)

        var partsOnly = AppearanceSpec()
        partsOnly.parts[.outfit] = "sonya"
        #expect(!partsOnly.isEmpty, "a grafted part alone is a customization")
    }

    @Test("Unknown slot keys are ignored instead of failing the decode")
    func unknownSlots() throws {
        let json = """
            {"schemaVersion":7,
             "recolors":{"unicornHorn":{"hueShift":10,"saturation":1,"brightness":1},
                         "hair":{"hueShift":10,"saturation":1,"brightness":1}},
             "textures":{"tail":{"donorSlug":"x","slot":"hair"}}}
            """
        let spec = try #require(AppearanceSpec.fromJSON(json))
        #expect(spec.recolors.count == 1)
        #expect(spec.recolors[.hair]?.hueShift == 10)
        #expect(spec.textures.isEmpty)
        #expect(spec.schemaVersion == 7)
    }

    @Test("SlotRecolor identity tolerance")
    func identity() {
        #expect(SlotRecolor.identity.isIdentity)
        #expect(!SlotRecolor(hueShift: 1).isIdentity)
        #expect(!SlotRecolor(saturation: 0.5).isIdentity)
        #expect(!SlotRecolor(brightness: 1.2).isIdentity)
    }
}
