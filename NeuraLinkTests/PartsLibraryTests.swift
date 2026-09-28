//
//  PartsLibraryTests.swift
//  NeuraLinkTests
//
//  The bundled parts library (App/Resources/Custom/Parts, cut from whole
//  models by scripts/extract_parts.py) and what the picker derives from it:
//  part kinds from the file name, per-part fingerprints that collapse the
//  same uniform worn by different models, pre-rendered thumbnails matching
//  those fingerprints, grafts onto BOTH VRM versions, and the offscreen
//  thumbnail renderer.
//

import Testing
import Foundation
import Metal
import UIKit
@testable import NeuraLink

@Suite("Parts library", .serialized)
struct PartsLibraryTests {

    @Test("Library lists the bundled part files with their kinds and never the playable characters")
    @MainActor
    func libraryContents() {
        let items = PartsLibrary.shared.items
        guard !items.isEmpty else {
            Issue.record("No Custom parts in the test host bundle")
            return
        }
        #expect(items.count >= 40)
        #expect(!items.contains { $0.stem == "ekaterina" || $0.stem == "sonya" })
        #expect(items.allSatisfy { $0.donorSlug.hasPrefix("lib:") && $0.kind != nil })
        for kind in PartsLibrary.Kind.allCases {
            #expect(items.contains { $0.kind == kind }, "library has \(kind.rawValue) parts")
        }
        #expect(PartsLibrary.Kind.tops.serves(.tops) && !PartsLibrary.Kind.tops.serves(.outfit))
        #expect(PartsLibrary.Kind.eyes.serves(.eyes) && !PartsLibrary.Kind.eyes.serves(.hair))
        #expect(PartsLibrary.humanize("school_uniform_2__outfit") == "School Uniform 2")
        #expect(PartsLibrary.shared.item(slug: "lib:casual__hair")?.kind == .hair)
        #expect(PartsLibrary.shared.item(slug: "casual__hair") == nil, "un-prefixed slugs are characters, not library items")
    }

    @Test("Same uniform on different models → one fingerprint; a different uniform → another")
    @MainActor
    func outfitFingerprints() async throws {
        guard let a = PartsLibrary.shared.item(slug: "lib:school_uniform__outfit"),
            let b = PartsLibrary.shared.item(slug: "lib:school_uniform_2__outfit"),
            let c = PartsLibrary.shared.item(slug: "lib:school_uniform_3__outfit"),
            let hairA = PartsLibrary.shared.item(slug: "lib:school_uniform__hair"),
            let hairB = PartsLibrary.shared.item(slug: "lib:school_uniform_2__hair")
        else {
            Issue.record("school_uniform parts missing from the bundle")
            return
        }
        let scanA = try await VRMDonorTextureCache.shared.scan(url: a.resolvedURL(), slug: a.donorSlug)
        let scanB = try await VRMDonorTextureCache.shared.scan(url: b.resolvedURL(), slug: b.donorSlug)
        let scanC = try await VRMDonorTextureCache.shared.scan(url: c.resolvedURL(), slug: c.donorSlug)
        let fpA = try #require(scanA.partFingerprint(.outfit))
        let fpB = try #require(scanB.partFingerprint(.outfit))
        let fpC = try #require(scanC.partFingerprint(.outfit))
        #expect(fpA == fpB, "identical uniform textures collapse")
        #expect(fpA != fpC, "a different uniform stays separate")
        let hairScanA = try await VRMDonorTextureCache.shared.scan(url: hairA.resolvedURL(), slug: hairA.donorSlug)
        let hairScanB = try await VRMDonorTextureCache.shared.scan(url: hairB.resolvedURL(), slug: hairB.donorSlug)
        #expect(hairScanA.partFingerprint(.hair) != hairScanB.partFingerprint(.hair), "different models keep their own hair")
        #expect(!scanA.hasPart(.hair), "an outfit file offers no hair")
    }

    @Test("Every library part ships a picture named after it")
    @MainActor
    func thumbnailsAreNamedAfterTheirParts() async throws {
        let items = PartsLibrary.shared.items
        guard !items.isEmpty else { return }
        var checked = 0
        for item in items {
            guard let url = try? await item.resolvedURL() else { continue }
            let scan = try await VRMDonorTextureCache.shared.scan(url: url, slug: item.donorSlug)
            var categories: [CustomizationCategory] = []
            switch item.kind {
            case .hair: categories = scan.hasPart(.hair) ? [.hair] : []
            case .outfit: categories = scan.hasPart(.outfit) ? [.outfit] : []
            case .tops: categories = scan.hasPart(.tops) ? [.tops] : []
            case .bottoms: categories = scan.hasPart(.bottoms) ? [.bottoms] : []
            case .shoes: categories = scan.hasPart(.shoes) ? [.shoes] : []
            case .eyes:
                categories = scan.fingerprint(forSlots: Set(CustomizationCategory.eyes.textureSlots)) != nil ? [.eyes] : []
            case nil: continue
            }
            #expect(!categories.isEmpty, "\(item.stem) offers something")
            for category in categories {
                let name = PartThumbnailStore.thumbnailName(base: item.modelStem, category: category)
                #expect(name == "\(item.modelStem)__\(category.rawValue)")
                #expect(Bundle.main.url(forResource: name, withExtension: "png") != nil, "\(name).png is bundled")
                checked += 1
            }
        }
        #expect(checked >= 30)
    }

    @Test("An export with no part names at all still yields hair and an outfit, but no half-blind face")
    @MainActor
    func genericMaterialNames() async throws {
        guard let hair = PartsLibrary.shared.item(slug: "lib:boy_uniform__hair"),
            let outfit = PartsLibrary.shared.item(slug: "lib:boy_uniform__outfit")
        else {
            Issue.record("boy_uniform parts missing from the bundle")
            return
        }
        // boy_uniform: every glTF material AND every VRM 0.x materialProperty
        // is literally "VRM/MToon". The extractor recovers the parts from the
        // image names it samples (F00_000_Body_00_nml…) plus "anything else on
        // a body mesh whose skin we identified is clothing", and writes
        // canonical names into the part files. Its eye materials stay
        // unidentifiable, so no eyes donor is produced.
        #expect(PartsLibrary.shared.item(slug: "lib:boy_uniform__eyes") == nil)
        let hairScan = try await VRMDonorTextureCache.shared.scan(url: hair.resolvedURL(), slug: hair.donorSlug)
        let outfitScan = try await VRMDonorTextureCache.shared.scan(url: outfit.resolvedURL(), slug: outfit.donorSlug)
        #expect(hairScan.hasPart(.hair))
        #expect(outfitScan.hasPart(.outfit))

        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let model = try await VRMModel.load(from: outfit.resolvedURL(), device: device)
        let slots = AppearanceApplier.presentSlots(in: model)
        #expect(slots.contains(.tops) && slots.contains(.bodySkin), "recovered clothes + skin: \(slots)")
    }

    @Test("A model whose clothes are painted into its skin still offers an outfit")
    @MainActor
    func skinPaintedOutfit() async throws {
        guard let outfit = PartsLibrary.shared.item(slug: "lib:brownie__outfit") else {
            Issue.record("brownie__outfit.vrm missing from the bundle")
            return
        }
        // brownie's body mesh is just Body_00_SKIN + Shoes — the clothes live
        // in the skin texture, so the outfit is that skin plus the shoes.
        let scan = try await VRMDonorTextureCache.shared.scan(url: outfit.resolvedURL(), slug: outfit.donorSlug)
        #expect(scan.hasPart(.outfit))
        #expect(scan.slots[.shoes] != nil && scan.slots[.bodySkin] != nil)
        #expect(scan.slots[.tops] == nil, "nothing invented that the model doesn't have")
    }

    @Test("A library hair part grafts onto a VRM 1.0 host and a VRM 0.x host", arguments: ["Sonya", "Ekaterina"])
    @MainActor
    func graftOntoBothVersions(hostName: String) async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
            let hostURL = Bundle.main.url(forResource: hostName, withExtension: "vrm"),
            let hair = PartsLibrary.shared.item(slug: "lib:casual__hair"),
            let outfit = PartsLibrary.shared.item(slug: "lib:casual__outfit")
        else {
            Issue.record("host or casual parts unavailable")
            return
        }
        let host = try await VRMModel.load(from: hostURL, device: device)
        let scan = try await VRMDonorTextureCache.shared.scan(url: hair.resolvedURL(), slug: hair.donorSlug)
        let donorHair = try await VRMModel.load(
            from: hair.resolvedURL(), device: device, options: VRMLoadingOptions(textureIndexFilter: scan.partTextureIndices[.hair]))
        let donorOutfit = try await VRMModel.load(from: outfit.resolvedURL(), device: device)
        let baseNodes = host.nodes.count
        let baseSprings = host.springBone?.springs.count ?? 0

        // "casual" is a rigid hairstyle: weighted to the head only, no hair
        // spring chains (its springs are bust/skirt) — so the graft must add
        // the meshes and nothing physics-related.
        let receipt = try VRMPartGrafter.graft(.hair, from: donorHair, donorSlug: hair.donorSlug, onto: host)
        #expect(receipt.meshCount >= 1 && receipt.nodeCount >= receipt.meshCount, "\(hostName): hair meshes appended")
        #expect(receipt.hiddenPrimitiveCount >= 1, "\(hostName): host hair hidden")
        #expect((host.springBone?.springs.count ?? 0) == baseSprings, "\(hostName): no foreign springs for a rigid hairstyle")
        try VRMPartGrafter.graft(.outfit, from: donorOutfit, donorSlug: outfit.donorSlug, onto: host)
        for node in host.nodes[baseNodes...] where node.mesh == nil {
            #expect(node.parent != nil, "\(hostName): appended bone '\(node.name ?? "?")' is parented")
        }
        for skin in host.skins {
            #expect(skin.joints.count == skin.inverseBindMatrices.count && skin.joints.count <= 255)
        }
        host.restoreBaseComposition()
        #expect(host.nodes.count == baseNodes)
    }

    @Test("A single-garment graft overrides the top a whole-outfit graft put on")
    @MainActor
    func garmentOverridesOutfit() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
            let hostURL = Bundle.main.url(forResource: "Sonya", withExtension: "vrm"),
            let outfit = PartsLibrary.shared.item(slug: "lib:school_uniform__outfit"),
            let tops = PartsLibrary.shared.item(slug: "lib:goth__tops")
        else {
            Issue.record("host or parts unavailable")
            return
        }
        let host = try await VRMModel.load(from: hostURL, device: device)
        let outfitDonor = try await VRMModel.load(from: outfit.resolvedURL(), device: device)
        let topsDonor = try await VRMModel.load(from: tops.resolvedURL(), device: device)

        try VRMPartGrafter.graft(.outfit, from: outfitDonor, donorSlug: outfit.donorSlug, onto: host)
        try VRMPartGrafter.graft(.tops, from: topsDonor, donorSlug: tops.donorSlug, onto: host)

        // Exactly one visible top survives: the uniform's was hidden by the
        // goth top that replaced it.
        var visibleTops = 0
        for mesh in host.meshes {
            for primitive in mesh.primitives {
                guard let m = primitive.materialIndex,
                    AppearancePartKind.tops.slots.contains(host.slot(ofMaterial: m)),
                    !host.hiddenPrimitives.contains(ObjectIdentifier(primitive))
                else { continue }
                visibleTops += 1
            }
        }
        #expect(visibleTops > 0, "the replacement top is visible")
        #expect(host.composition?.activeParts[.tops] == tops.donorSlug)
        #expect(host.composition?.activeParts[.outfit] == outfit.donorSlug, "the rest of the outfit stays")
    }

    @Test("A part load decodes only the part's textures")
    @MainActor
    func filteredDonorLoad() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
            let url = Bundle.main.url(forResource: "Sonya", withExtension: "vrm")
        else { return }
        let scan = try await VRMDonorTextureCache.shared.scan(url: url, slug: "sonya")
        let hairTextures = try #require(scan.partTextureIndices[.hair])
        #expect(!hairTextures.isEmpty)
        let model = try await VRMModel.load(
            from: url, device: device, options: VRMLoadingOptions(textureIndexFilter: hairTextures))
        let loaded = model.textures.indices.filter { model.textures[$0].mtlTexture != nil }
        #expect(Set(loaded) == hairTextures, "exactly the hair's textures were uploaded")
        #expect(loaded.count < model.textures.count / 2, "most of the model's textures were skipped")
    }

    @Test("Part thumbnail renders offscreen")
    @MainActor
    func thumbnailRender() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
            let url = Bundle.main.url(forResource: "Sonya", withExtension: "vrm"),
            let renderer = VRMPartThumbnailRenderer(size: 128)
        else {
            Issue.record("Metal or Sonya.vrm unavailable")
            return
        }
        let model = try await VRMModel.load(from: url, device: device)
        let hiddenBefore = model.hiddenPrimitives
        let image = try #require(renderer.render(model: model, subject: .hair))
        // Cropped to the part and re-squared, so the size follows the content.
        #expect(image.size.width == image.size.height, "square tile")
        #expect(image.size.width > 16, "not an empty crop")
        #expect(model.hiddenPrimitives == hiddenBefore, "render leaves the model as it found it")
        let outfit = try #require(renderer.render(model: model, subject: .outfit))
        #expect(outfit.cgImage != nil)
    }
}
