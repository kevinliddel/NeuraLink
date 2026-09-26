//
//  CustomizationCategory.swift
//  NeuraLink
//
//  The five tabs of the customization panel, mirroring the reference
//  project's sliders (Hair · Clothes · Face · Eyes · Skin). Part categories
//  graft geometry from the donor; texture categories borrow the donor's
//  textures for the listed slots; every category can also be recoloured.
//

import Foundation

enum CustomizationCategory: String, CaseIterable, Identifiable {
    case hair
    case outfit
    case face
    case eyes
    case skin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hair: return "Hair"
        case .outfit: return "Outfit"
        case .face: return "Face"
        case .eyes: return "Eyes"
        case .skin: return "Skin"
        }
    }

    var systemImage: String {
        switch self {
        case .hair: return "scissors"
        case .outfit: return "tshirt"
        case .face: return "face.smiling"
        case .eyes: return "eye"
        case .skin: return "hand.raised"
        }
    }

    /// Geometry graft, when this category swaps a whole part.
    var part: AppearancePartKind? {
        switch self {
        case .hair: return .hair
        case .outfit: return .outfit
        default: return nil
        }
    }

    /// Slots whose textures a donor pick copies (texture categories only).
    var textureSlots: [VRoidMaterialSlot] {
        switch self {
        case .face: return [.mouth, .brow, .eyeline, .eyelash]
        case .eyes: return [.eyeIris, .eyeWhite, .eyeHighlight, .eyeExtra]
        case .skin: return [.faceSkin, .bodySkin]
        case .hair, .outfit: return []
        }
    }

    /// Slots the colour sliders act on.
    var recolorSlots: [VRoidMaterialSlot] {
        switch self {
        case .hair: return [.hair, .hairBack]
        case .outfit: return [.tops, .bottoms, .shoes, .onepiece, .accessory]
        case .face: return [.brow, .eyeline, .eyelash, .mouth]
        case .eyes: return [.eyeIris, .eyeHighlight]
        case .skin: return [.faceSkin, .bodySkin]
        }
    }

    var colourHint: String {
        switch self {
        case .hair: return "Hair colour"
        case .outfit: return "Outfit colour"
        case .face: return "Brow & lip colour"
        case .eyes: return "Eye colour"
        case .skin: return "Skin tone"
        }
    }

    /// Whether the base model has anything this tab can edit.
    func isAvailable(presentSlots: Set<VRoidMaterialSlot>) -> Bool {
        if let part { return !part.slots.isDisjoint(with: presentSlots) }
        return !Set(textureSlots).isDisjoint(with: presentSlots)
    }
}
