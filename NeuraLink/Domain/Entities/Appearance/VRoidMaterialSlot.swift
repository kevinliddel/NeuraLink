//
//  VRoidMaterialSlot.swift
//  NeuraLink
//
//  The stable "slot vocabulary" every VRoid Studio export carries in its
//  material names (docs/CHARACTER_CUSTOMIZATION.md). The numeric prefix
//  varies between VRoid generations (`N00_000_00_` in 2.x, `F00_`/`M00_` in
//  1.x) and every name ends in a Unity " (Instance)" suffix, but the part
//  tokens (`Face`, `Body`, `EyeIris`, `Tops`, …) do not change. Classifying by
//  token is what lets textures and tints address "the skin" or "the iris" on
//  any VRoid model — the same trick the reference Unity project plays with
//  `name.Substring(11)`.
//

import Foundation

/// A customizable material role on a VRoid-style avatar.
nonisolated public enum VRoidMaterialSlot: String, Codable, CaseIterable, Sendable {
    case faceSkin
    case bodySkin
    case eyeIris
    case eyeWhite
    case eyeHighlight
    case eyeExtra
    case brow
    case eyeline
    case eyelash
    case mouth
    case hairBack
    case hair
    case tops
    case bottoms
    case shoes
    case onepiece
    case accessory
    case other

    /// Human-readable label for pickers.
    public var displayName: String {
        switch self {
        case .faceSkin: return "Face"
        case .bodySkin: return "Body"
        case .eyeIris: return "Iris"
        case .eyeWhite: return "Eye White"
        case .eyeHighlight: return "Highlight"
        case .eyeExtra: return "Eye Extra"
        case .brow: return "Brows"
        case .eyeline: return "Eyeline"
        case .eyelash: return "Lashes"
        case .mouth: return "Mouth"
        case .hairBack: return "Back Hair"
        case .hair: return "Hair"
        case .tops: return "Top"
        case .bottoms: return "Bottom"
        case .shoes: return "Shoes"
        case .onepiece: return "One-piece"
        case .accessory: return "Accessory"
        case .other: return "Other"
        }
    }

    // MARK: - Classification

    /// Maps a glTF material name to its slot. Token-based (split on `_`) so
    /// the VRoid numeric prefix and Unity suffix are irrelevant; a substring
    /// fallback catches hand-named materials on non-VRoid models.
    public static func classify(materialName: String?) -> VRoidMaterialSlot {
        guard let raw = materialName, !raw.isEmpty else { return .other }
        let cleaned = raw.replacingOccurrences(of: " (Instance)", with: "")
        let tokens = Set(
            cleaned.split(whereSeparator: { $0 == "_" || $0 == " " || $0 == "-" })
                .map { $0.lowercased() })

        if let slot = classifyByTokens(tokens, firstToken: cleaned.lowercased()) {
            return slot
        }
        return classifyBySubstring(cleaned.lowercased())
    }

    private static func classifyByTokens(_ tokens: Set<String>, firstToken: String) -> VRoidMaterialSlot? {
        if tokens.contains("facemouth") { return .mouth }
        if tokens.contains("eyeiris") { return .eyeIris }
        if tokens.contains("eyewhite") { return .eyeWhite }
        if tokens.contains("eyehighlight") { return .eyeHighlight }
        if tokens.contains("eyeextra") { return .eyeExtra }
        if tokens.contains("facebrow") { return .brow }
        if tokens.contains("faceeyeline") { return .eyeline }
        if tokens.contains("faceeyelash") { return .eyelash }
        if tokens.contains("hairback") { return .hairBack }
        if tokens.contains("hair") { return .hair }
        if tokens.contains("face") { return .faceSkin }
        if tokens.contains("body") { return .bodySkin }
        if tokens.contains("tops") { return .tops }
        if tokens.contains("bottoms") { return .bottoms }
        if tokens.contains("shoes") { return .shoes }
        if tokens.contains("onepiece") || tokens.contains("onepice") { return .onepiece }
        if firstToken.hasPrefix("accessory") || tokens.contains("accessory") { return .accessory }
        return nil
    }

    /// Loose fallback for models that don't follow VRoid naming.
    private static func classifyBySubstring(_ lower: String) -> VRoidMaterialSlot {
        if lower.contains("iris") { return .eyeIris }
        if lower.contains("highlight") { return .eyeHighlight }
        if lower.contains("brow") { return .brow }
        if lower.contains("lash") { return .eyelash }
        if lower.contains("eyeline") { return .eyeline }
        if lower.contains("mouth") || lower.contains("lip") { return .mouth }
        if lower.contains("eye") { return .eyeWhite }
        if lower.contains("hair") { return .hair }
        if lower.contains("face") { return .faceSkin }
        if lower.contains("body") || lower.contains("skin") { return .bodySkin }
        if lower.contains("shoe") || lower.contains("boot") { return .shoes }
        if lower.contains("skirt") || lower.contains("pants") || lower.contains("shorts") { return .bottoms }
        if lower.contains("cloth") || lower.contains("shirt") || lower.contains("dress") { return .tops }
        return .other
    }
}
