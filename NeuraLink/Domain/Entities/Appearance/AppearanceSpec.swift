//
//  AppearanceSpec.swift
//  NeuraLink
//
//  Per-character saved look (Tier A of docs/CHARACTER_CUSTOMIZATION_PLAN.md).
//  Stored as JSON in the `character_appearance` table and re-applied by
//  AppearanceApplier after every model load. Everything here is a
//  non-destructive overlay on the VRM: nothing is written back to the model
//  file and no export path exists (VRoid guideline compliance).
//

import Foundation

/// HSV adjustment applied in the fragment shader after the base-colour
/// sample. Identity = (0°, ×1, ×1).
nonisolated public struct SlotRecolor: Codable, Equatable, Sendable {
    /// Degrees, -180…180.
    public var hueShift: Float
    /// Multiplier, 0…2.
    public var saturation: Float
    /// Multiplier, 0.5…1.5 in the UI (shader accepts any positive value).
    public var brightness: Float

    public static let identity = SlotRecolor(hueShift: 0, saturation: 1, brightness: 1)

    public init(hueShift: Float = 0, saturation: Float = 1, brightness: Float = 1) {
        self.hueShift = hueShift
        self.saturation = saturation
        self.brightness = brightness
    }

    public var isIdentity: Bool {
        abs(hueShift) < 0.01 && abs(saturation - 1) < 0.001 && abs(brightness - 1) < 0.001
    }
}

/// A base-colour texture borrowed from another character's VRM ("copy the
/// materials from premade model N" in the Unity reference). Resolved at
/// apply time through the model registry; a missing donor is skipped.
nonisolated public struct DonorTextureRef: Codable, Equatable, Sendable {
    /// Registry name, lowercased (== persona slug).
    public var donorSlug: String
    /// Which of the donor's slots supplies the texture. Usually equals the
    /// target slot; kept explicit so a future pack can map across slots.
    public var slot: VRoidMaterialSlot

    public init(donorSlug: String, slot: VRoidMaterialSlot) {
        self.donorSlug = donorSlug.lowercased()
        self.slot = slot
    }
}

/// A whole part (mesh + bones + physics) borrowed from another character —
/// the reference project's hair-set toggle and whole-body outfit swap.
nonisolated public enum AppearancePartKind: String, Codable, CaseIterable, Sendable {
    case hair
    /// The whole look: the donor's body skin and every garment. Grafting
    /// the skin too is what keeps VRoid's carved-away geometry consistent
    /// (it deletes the skin its own outfit hides).
    case outfit
    case tops
    case bottoms
    case shoes

    /// Bones a rigid part rides on, and so is resized around. Clothes list
    /// none: they are skinned across the humanoid and fit on their own.
    /// Whether grafting this part should cut the host's own skin out from
    /// under it. VRoid keeps a full foot in the body mesh, shaped for the
    /// shoe that character shipped with, so a borrowed shoe lets the heel
    /// and the sides of the foot through. Clothes don't need it: they are
    /// skinned across the body and follow it.
    /// Whether this part rests on the ground, so a borrowed one has to be
    /// lifted or dropped until its sole meets the host's floor rather than
    /// landing wherever the donor's ankle happened to sit above it.
    public var standsOnTheFloor: Bool {
        switch self {
        case .shoes: return true
        case .hair, .outfit, .tops, .bottoms: return false
        }
    }

    public var trimsHostSkinUnderneath: Bool {
        switch self {
        case .shoes: return ProcessInfo.processInfo.environment["NL_NO_SKIN_TRIM"] == nil
        case .hair, .outfit, .tops, .bottoms: return false
        }
    }

    public var fitAnchorBones: [VRMHumanoidBone] {
        switch self {
        case .hair: return [.head]
        case .shoes: return [.leftFoot, .rightFoot, .leftToes, .rightToes]
        case .outfit, .tops, .bottoms: return []
        }
    }

    /// Slots a part of this kind carries; the host's own primitives in
    /// these slots are hidden while the part is grafted. Single garments
    /// are declared after `outfit` so they win when both are chosen.
    public var slots: Set<VRoidMaterialSlot> {
        switch self {
        case .hair: return [.hair, .hairBack]
        case .outfit: return [.bodySkin, .tops, .bottoms, .shoes, .onepiece, .accessory]
        case .tops: return [.tops, .onepiece]
        case .bottoms: return [.bottoms]
        case .shoes: return [.shoes]
        }
    }
}

/// The saved customization for one character.
nonisolated public struct AppearanceSpec: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var recolors: [VRoidMaterialSlot: SlotRecolor]
    public var textures: [VRoidMaterialSlot: DonorTextureRef]
    /// Grafted parts, keyed by kind → donor slug (lowercased).
    public var parts: [AppearancePartKind: String]

    public init(
        recolors: [VRoidMaterialSlot: SlotRecolor] = [:],
        textures: [VRoidMaterialSlot: DonorTextureRef] = [:],
        parts: [AppearancePartKind: String] = [:]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.recolors = recolors
        self.textures = textures
        self.parts = parts
    }

    /// True when applying the spec would change nothing.
    public var isEmpty: Bool {
        textures.isEmpty && parts.isEmpty && recolors.values.allSatisfy(\.isIdentity)
    }

    /// Drops identity recolors so "reset a slider" and "never touched" store
    /// the same bytes.
    public mutating func normalize() {
        recolors = recolors.filter { !$0.value.isIdentity }
    }

    public func normalized() -> AppearanceSpec {
        var copy = self
        copy.normalize()
        return copy
    }

    // MARK: - Codable (tolerant of unknown slots from newer builds)

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, recolors, textures, parts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        let rawRecolors = try container.decodeIfPresent([String: SlotRecolor].self, forKey: .recolors) ?? [:]
        let rawTextures = try container.decodeIfPresent([String: DonorTextureRef].self, forKey: .textures) ?? [:]
        var recolors: [VRoidMaterialSlot: SlotRecolor] = [:]
        for (key, value) in rawRecolors {
            if let slot = VRoidMaterialSlot(rawValue: key) { recolors[slot] = value }
        }
        var textures: [VRoidMaterialSlot: DonorTextureRef] = [:]
        for (key, value) in rawTextures {
            if let slot = VRoidMaterialSlot(rawValue: key) { textures[slot] = value }
        }
        self.recolors = recolors
        self.textures = textures
        let rawParts = try container.decodeIfPresent([String: String].self, forKey: .parts) ?? [:]
        var parts: [AppearancePartKind: String] = [:]
        for (key, value) in rawParts {
            if let kind = AppearancePartKind(rawValue: key) { parts[kind] = value.lowercased() }
        }
        self.parts = parts
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        let rawRecolors = Dictionary(uniqueKeysWithValues: recolors.map { ($0.key.rawValue, $0.value) })
        let rawTextures = Dictionary(uniqueKeysWithValues: textures.map { ($0.key.rawValue, $0.value) })
        let rawParts = Dictionary(uniqueKeysWithValues: parts.map { ($0.key.rawValue, $0.value) })
        try container.encode(rawRecolors, forKey: .recolors)
        try container.encode(rawTextures, forKey: .textures)
        try container.encode(rawParts, forKey: .parts)
    }

    // MARK: - JSON helpers

    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard let json = String(bytes: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                self, EncodingError.Context(codingPath: [], debugDescription: "spec is not valid UTF-8"))
        }
        return json
    }

    public static func fromJSON(_ json: String) -> AppearanceSpec? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AppearanceSpec.self, from: data)
    }
}
