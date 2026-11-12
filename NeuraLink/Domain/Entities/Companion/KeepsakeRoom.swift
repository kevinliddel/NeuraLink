//
//  KeepsakeRoom.swift
//  NeuraLink
//
//  A room that remembers — Living Companion (docs/Companion/LIVING_COMPANION.md).
//  The keepsakes the user and the character collect become objects on a
//  surface beside the character — a side table indoors, stacked suitcases
//  outdoors, a chest on open ground: which object each keepsake is, where it stands,
//  and how the persona is told about them. Pure rules; the geometry is
//  built by KeepsakePropFactory and placed by CompanionRoom.
//
//  Created by Dedicatus on 05/11/2026.
//

import Foundation
import simd

/// The shapes on the table — one per shape; the plant grows instead of
/// multiplying.
enum RoomObjectKind: String, CaseIterable, Sendable {
    /// A folded place card with the date of the first hello.
    case card
    /// A standing frame with the first diary picture (a closed notebook
    /// when that entry has no picture).
    case frame
    /// A polaroid of the first photo the user showed.
    case polaroid
    /// The sleeve of the first song identified together.
    case sleeve
    /// A die from the first game.
    case die
    /// A potted plant that grows with the days together.
    case plant
}

struct RoomObject: Equatable, Sendable {
    let kind: RoomObjectKind
    let milestone: MilestoneKind
    let achievedAt: Date
    /// What the object shows (`CompanionMilestone.note`): the song's
    /// "Title — Artist", a picture file name, or nothing.
    let note: String
    /// Plant growth: 1 a sprout, 2 in leaf, 3 in flower. 0 for the rest.
    let stage: Int

    init(kind: RoomObjectKind, milestone: MilestoneKind, achievedAt: Date, note: String = "", stage: Int = 0) {
        self.kind = kind
        self.milestone = milestone
        self.achievedAt = achievedAt
        self.note = note
        self.stage = stage
    }
}

/// Where something stands: metres (in the world, or on the table top) and
/// a turn about the vertical axis. The character faces +Z, toward the
/// viewer; a positive yaw turns a front toward the viewer's right.
struct RoomSpot: Equatable, Sendable {
    var position: SIMD3<Float>
    var yaw: Float
}

/// An object's place on the surface top: its spot plus a backward lean,
/// the way a propped frame tips its top away from the viewer.
struct RoomSlot: Equatable, Sendable {
    var spot: RoomSpot
    var leanBack: Float = 0
}

/// What the keepsakes stand on, one per kind of scene: a side table is
/// furniture for an interior, a street or a campus has two vintage
/// suitcases set down and stacked, and open ground (the terrain shown with
/// the 3D environment off) gets a wooden chest. Every surface's local
/// frame has its base at the origin, +Y up, +Z toward the viewer, and the
/// objects' slot origin on its top.
enum KeepsakeSurface: String, CaseIterable, Sendable {
    case table
    case suitcase
    case chest

    /// Height of the top the objects stand on.
    var topHeight: Float {
        switch self {
        case .table: return 0.68
        case .suitcase: return 0.36
        case .chest: return 0.46
        }
    }

    /// Half the usable top about the slot origin, x and z (the table top
    /// is round, with this radius).
    var topHalfExtent: SIMD2<Float> {
        switch self {
        case .table: return SIMD2(KeepsakeRoomRules.tableRadius, KeepsakeRoomRules.tableRadius)
        case .suitcase: return SIMD2(0.25, 0.17)
        case .chest: return SIMD2(0.25, 0.18)
        }
    }

    /// Where it stands unless the scene says otherwise: on the floor at
    /// the character's left, a little behind their line, inside the
    /// default portrait framing. The environment GLBs sit 2 cm below the
    /// origin; the terrain is at 0.
    var defaultSpot: RoomSpot {
        switch self {
        case .table, .suitcase: return RoomSpot(position: SIMD3<Float>(-0.5, -0.02, -0.4), yaw: 0)
        case .chest: return RoomSpot(position: SIMD3<Float>(-0.5, 0, -0.4), yaw: 0)
        }
    }

    /// How the persona hears of it.
    var phrase: String {
        switch self {
        case .table: return "the small table beside you"
        case .suitcase: return "the stacked suitcases beside you"
        case .chest: return "the old wooden chest beside you"
        }
    }
}

/// What a scene gives the keepsakes: the surface and where it stands.
struct RoomScene: Equatable, Sendable {
    var surface: KeepsakeSurface
    var spot: RoomSpot

    init(surface: KeepsakeSurface, spot: RoomSpot? = nil) {
        self.surface = surface
        self.spot = spot ?? surface.defaultSpot
    }
}

enum KeepsakeRoomRules {

    static let tableRadius: Float = 0.19

    /// Every object has its own place, so nothing shuffles when a new
    /// keepsake arrives. Top frame: origin at the slot origin on the
    /// surface top, +Z toward the viewer, +X to their right. The slots fit
    /// every surface (`isOnTop`).
    static func slot(for kind: RoomObjectKind) -> RoomSlot {
        switch kind {
        case .frame: return RoomSlot(spot: RoomSpot(position: [-0.03, 0, -0.07], yaw: 0), leanBack: radians(10))
        case .sleeve: return RoomSlot(spot: RoomSpot(position: [0.08, 0, -0.05], yaw: radians(-25)), leanBack: radians(14))
        case .plant: return RoomSlot(spot: RoomSpot(position: [-0.12, 0, -0.03], yaw: 0))
        case .card: return RoomSlot(spot: RoomSpot(position: [-0.08, 0, 0.08], yaw: radians(15)))
        case .polaroid: return RoomSlot(spot: RoomSpot(position: [0.11, 0, 0.05], yaw: radians(-20)), leanBack: radians(22))
        case .die: return RoomSlot(spot: RoomSpot(position: [0.02, 0, 0.10], yaw: radians(35)))
        }
    }

    /// Which object each keepsake is. The three "days together" keepsakes
    /// are one plant at the stage of the furthest reached; objects come
    /// back in the order they were earned.
    static func objects(from milestones: [CompanionMilestone]) -> [RoomObject] {
        var plant: RoomObject?
        var objects: [RoomObject] = []
        for milestone in milestones.sorted(by: { $0.achievedAt < $1.achievedAt }) {
            switch milestone.kind {
            case .firstConversation:
                objects.append(RoomObject(kind: .card, milestone: .firstConversation, achievedAt: milestone.achievedAt))
            case .firstDiary:
                objects.append(RoomObject(kind: .frame, milestone: .firstDiary, achievedAt: milestone.achievedAt, note: milestone.note))
            case .firstPhoto:
                objects.append(RoomObject(kind: .polaroid, milestone: .firstPhoto, achievedAt: milestone.achievedAt, note: milestone.note))
            case .firstSharedSong:
                objects.append(RoomObject(kind: .sleeve, milestone: .firstSharedSong, achievedAt: milestone.achievedAt, note: milestone.note))
            case .firstGame:
                objects.append(RoomObject(kind: .die, milestone: .firstGame, achievedAt: milestone.achievedAt))
            case .sevenDays, .thirtyDays, .hundredDays:
                let stage = plantStage(for: milestone.kind)
                if stage > (plant?.stage ?? 0) {
                    plant = RoomObject(kind: .plant, milestone: milestone.kind, achievedAt: milestone.achievedAt, stage: stage)
                }
            }
        }
        if let plant { objects.append(plant) }
        return objects.sorted { $0.achievedAt < $1.achievedAt }
    }

    static func plantStage(for kind: MilestoneKind) -> Int {
        switch kind {
        case .sevenDays: return 1
        case .thirtyDays: return 2
        case .hundredDays: return 3
        default: return 0
        }
    }

    /// Whether a slot at `position` (top frame), with `margin` around it,
    /// is on `surface`'s top.
    static func isOnTop(_ position: SIMD3<Float>, of surface: KeepsakeSurface, margin: Float = 0.04) -> Bool {
        let half = surface.topHalfExtent
        switch surface {
        case .table:
            return simd_length(SIMD2(position.x, position.z)) + margin <= half.x
        case .suitcase, .chest:
            return abs(position.x) + margin <= half.x && abs(position.z) + margin <= half.y
        }
    }

    /// World placement of an object in `slot` on `scene`'s surface: the
    /// surface's turn first, then the object's own turn and lean. The
    /// slot's position is measured on the top, so the surface's height is
    /// added here.
    static func placement(of slot: RoomSlot, in scene: RoomScene) -> (position: SIMD3<Float>, rotation: simd_quatf) {
        let surfaceTurn = simd_quatf(angle: scene.spot.yaw, axis: SIMD3<Float>(0, 1, 0))
        let ownTurn = simd_quatf(angle: slot.spot.yaw, axis: SIMD3<Float>(0, 1, 0))
        // A positive turn about +X tips the top toward the viewer; leaning
        // back is the opposite.
        let lean = simd_quatf(angle: -slot.leanBack, axis: SIMD3<Float>(1, 0, 0))
        let onTop = slot.spot.position + SIMD3<Float>(0, scene.surface.topHeight, 0)
        return (scene.spot.position + surfaceTurn.act(onTop), simd_normalize(surfaceTurn * ownTurn * lean))
    }

    // MARK: - What the persona is told

    /// One object in words, for the `[Companion State]` line.
    static func describe(_ object: RoomObject) -> String {
        let day = object.achievedAt.formatted(.dateTime.day().month())
        switch object.kind {
        case .card:
            return "a folded card from your first hello (\(day))"
        case .frame:
            return object.note.isEmpty
                ? "a small closed notebook from your first diary entry (\(day))"
                : "a framed picture from your first diary entry (\(day))"
        case .polaroid:
            return "a polaroid of the first photo they showed you (\(day))"
        case .sleeve:
            guard let song = songParts(object.note) else {
                return "the sleeve of the first song you identified together (\(day))"
            }
            let credit = song.artist.isEmpty ? "" : " by \(song.artist)"
            return "the sleeve of \u{201C}\(song.title)\u{201D}\(credit), the first song you identified together (\(day))"
        case .die:
            return "a die from your first game together (\(day))"
        case .plant:
            switch object.stage {
            case 1: return "a sprout in a small pot, from your first week together"
            case 2: return "a leafy plant in a pot, a month together"
            default: return "a plant in flower, a hundred days together"
            }
        }
    }

    /// Nil when nothing stands there. The objects are real in the scene,
    /// so the persona may refer to them, but never as a list.
    static func promptLine(for objects: [RoomObject], on surface: KeepsakeSurface) -> String? {
        guard !objects.isEmpty else { return nil }
        return "Keepsakes on \(surface.phrase), real objects in the scene with you "
            + "(mention one only when it fits, never list them): "
            + objects.map(describe).joined(separator: "; ") + "."
    }

    /// The song keepsake's note: the title and the artist on their own
    /// lines — a separator neither can contain, unlike a dash.
    static func songNote(title: String, artist: String) -> String {
        let cleanTitle = singleLine(title)
        let cleanArtist = singleLine(artist)
        guard !cleanTitle.isEmpty else { return "" }
        return cleanArtist.isEmpty ? cleanTitle : "\(cleanTitle)\n\(cleanArtist)"
    }

    static func songParts(_ note: String) -> (title: String, artist: String)? {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let range = trimmed.range(of: "\n") else { return (trimmed, "") }
        return (singleLine(String(trimmed[..<range.lowerBound])), singleLine(String(trimmed[range.upperBound...])))
    }

    private static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func radians(_ degrees: Float) -> Float { degrees * .pi / 180 }
}
