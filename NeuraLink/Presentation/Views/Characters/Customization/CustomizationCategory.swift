//
//  CustomizationCategory.swift
//  NeuraLink
//
//  The tabs of the customization sheet. Part categories graft geometry
//  from the donor; Eyes borrows the donor's eye textures; every category
//  can also be recoloured.
//
//  Outfit swaps the whole look — the donor's body skin and all its
//  garments — which is the faithful option, because VRoid deletes the skin
//  its own outfit hides. Top / Bottom / Shoes swap one garment and leave
//  the host's skin alone, which is freer but can expose a gap where the
//  host's original garment covered more than the new one does.
//

import Foundation

enum CustomizationCategory: String, CaseIterable, Identifiable {
    case hair
    case outfit
    case tops
    case bottoms
    case shoes
    case eyes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hair: return "Hair"
        case .outfit: return "Outfit"
        case .tops: return "Top"
        case .bottoms: return "Bottom"
        case .shoes: return "Shoes"
        case .eyes: return "Eyes"
        }
    }

    var systemImage: String {
        switch self {
        case .hair: return "scissors"
        case .outfit: return "figure.stand"
        case .tops: return "tshirt"
        case .bottoms: return "rectangle.portrait"
        case .shoes: return "shoeprints.fill"
        case .eyes: return "eye"
        }
    }

    /// Geometry graft, when this category swaps a whole part.
    var part: AppearancePartKind? {
        switch self {
        case .hair: return .hair
        case .outfit: return .outfit
        case .tops: return .tops
        case .bottoms: return .bottoms
        case .shoes: return .shoes
        case .eyes: return nil
        }
    }

    /// Slots whose textures a donor pick copies (texture categories only).
    var textureSlots: [VRoidMaterialSlot] {
        switch self {
        case .eyes: return [.eyeIris, .eyeWhite, .eyeHighlight, .eyeExtra]
        case .hair, .outfit, .tops, .bottoms, .shoes: return []
        }
    }

    /// Slots the colour sliders act on.
    var recolorSlots: [VRoidMaterialSlot] {
        switch self {
        case .hair: return [.hair, .hairBack]
        case .outfit: return [.tops, .bottoms, .shoes, .onepiece, .accessory]
        case .tops: return [.tops, .onepiece]
        case .bottoms: return [.bottoms]
        case .shoes: return [.shoes]
        case .eyes: return [.eyeIris, .eyeHighlight]
        }
    }

    var colourHint: String {
        switch self {
        case .hair: return "Hair colour"
        case .outfit: return "Outfit colour"
        case .tops: return "Top colour"
        case .bottoms: return "Bottom colour"
        case .shoes: return "Shoe colour"
        case .eyes: return "Eye colour"
        }
    }

    /// Whether this tab can do anything on the current model. A graft can
    /// always add a part the host lacks, so part tabs stay open; borrowing a
    /// texture needs a material to put it on.
    func isAvailable(presentSlots: Set<VRoidMaterialSlot>) -> Bool {
        if part != nil { return true }
        return !Set(textureSlots).isDisjoint(with: presentSlots)
    }
}
