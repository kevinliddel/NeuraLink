//
//  VRoidMaterialSlotTests.swift
//  NeuraLinkTests
//
//  The slot classifier is what lets customization address "the skin" or
//  "the iris" on any VRoid model. Pinned against synthetic names from every
//  VRoid generation we've seen (1.x `F00_`, 2.x `N00_`) and against the real
//  material lists of the bundled characters.
//

import Testing
import Foundation
@testable import NeuraLink

@Suite("VRoid material slots")
struct VRoidMaterialSlotTests {

    @Test("VRoid 2.x (N00) names classify by token")
    func vroid2Names() {
        #expect(VRoidMaterialSlot.classify(materialName: "N00_000_00_Face_00_SKIN (Instance)") == .faceSkin)
        #expect(VRoidMaterialSlot.classify(materialName: "N00_000_00_Body_00_SKIN (Instance)") == .bodySkin)
        #expect(VRoidMaterialSlot.classify(materialName: "N00_000_00_EyeIris_00_EYE (Instance)") == .eyeIris)
        #expect(VRoidMaterialSlot.classify(materialName: "N00_000_00_EyeWhite_00_EYE (Instance)") == .eyeWhite)
        #expect(VRoidMaterialSlot.classify(materialName: "N00_000_00_EyeHighlight_00_EYE (Instance)") == .eyeHighlight)
        #expect(VRoidMaterialSlot.classify(materialName: "N00_000_00_FaceBrow_00_FACE (Instance)") == .brow)
        #expect(VRoidMaterialSlot.classify(materialName: "N00_000_00_FaceEyeline_00_FACE (Instance)") == .eyeline)
        #expect(VRoidMaterialSlot.classify(materialName: "N00_000_00_FaceMouth_00_FACE (Instance)") == .mouth)
        #expect(VRoidMaterialSlot.classify(materialName: "N00_000_00_HairBack_00_HAIR (Instance)") == .hairBack)
        #expect(VRoidMaterialSlot.classify(materialName: "N00_000_Hair_00_HAIR_01 (Instance)") == .hair)
        #expect(VRoidMaterialSlot.classify(materialName: "N00_007_01_Tops_01_CLOTH_04 (Instance)") == .tops)
        #expect(VRoidMaterialSlot.classify(materialName: "N00_001_02_Bottoms_01_CLOTH (Instance)") == .bottoms)
        #expect(VRoidMaterialSlot.classify(materialName: "N00_006_01_Shoes_01_CLOTH (Instance)") == .shoes)
        #expect(VRoidMaterialSlot.classify(materialName: "N00_010_01_Onepiece_00_CLOTH (Instance)") == .onepiece)
        #expect(VRoidMaterialSlot.classify(materialName: "Accessory_GlassesLowFrame_01_MATCAP (Instance)") == .accessory)
    }

    @Test("VRoid 1.x (F00/M00) names classify identically")
    func vroid1Names() {
        #expect(VRoidMaterialSlot.classify(materialName: "F00_000_00_Face_00_SKIN") == .faceSkin)
        #expect(VRoidMaterialSlot.classify(materialName: "F00_000_00_FaceEyelash_00_FACE") == .eyelash)
        #expect(VRoidMaterialSlot.classify(materialName: "F00_000_00_EyeExtra_01_EYE") == .eyeExtra)
        #expect(VRoidMaterialSlot.classify(materialName: "M00_000_Hair_00_HAIR_1") == .hair)
        #expect(VRoidMaterialSlot.classify(materialName: "F00_002_02_Tops_01_CLOTH") == .tops)
    }

    @Test("Non-VRoid names fall back to substrings, unknown → other")
    func fallbacks() {
        #expect(VRoidMaterialSlot.classify(materialName: "Hair Material") == .hair)
        #expect(VRoidMaterialSlot.classify(materialName: "Skirt") == .bottoms)
        #expect(VRoidMaterialSlot.classify(materialName: "Sword") == .other)
        #expect(VRoidMaterialSlot.classify(materialName: nil) == .other)
        #expect(VRoidMaterialSlot.classify(materialName: "") == .other)
    }

    @Test("Every slot except other belongs to exactly one group")
    func groups() {
        for slot in VRoidMaterialSlot.allCases where slot != .other {
            #expect(VRoidSlotGroup.allCases.filter { $0.slots.contains(slot) }.count == 1, "\(slot)")
        }
        #expect(VRoidSlotGroup.skin.editsSlotsJointly)
        #expect(!VRoidSlotGroup.eyes.editsSlotsJointly)
    }

    @Test("Bundled characters expose the expected slots", arguments: ["Ekaterina", "Sonya"])
    func bundledModels(name: String) async throws {
        guard let url = Bundle.main.url(forResource: name, withExtension: "vrm") else {
            Issue.record("\(name).vrm missing from the test host bundle")
            return
        }
        let model = try await VRMModel.load(from: url)
        let bySlot = AppearanceApplier.materialIndicesBySlot(in: model)
        #expect(bySlot[.faceSkin]?.count == 1, "\(name): one face skin material")
        #expect(bySlot[.bodySkin]?.count == 1, "\(name): one body skin material")
        #expect(bySlot[.eyeIris]?.count == 1)
        #expect(bySlot[.eyeWhite]?.count == 1)
        #expect(bySlot[.mouth]?.count == 1)
        #expect((bySlot[.hair]?.count ?? 0) >= 1)
        #expect((bySlot[.tops]?.count ?? 0) >= 1)
        #expect(bySlot[.other] == nil, "\(name): every VRoid material should classify")
        let present = AppearanceApplier.presentSlots(in: model)
        #expect(present.isSuperset(of: [.faceSkin, .bodySkin, .eyeIris, .hair]))
    }
}
