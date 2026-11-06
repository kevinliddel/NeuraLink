//
//  CompanionRoom.swift
//  NeuraLink
//
//  A room that remembers — Living Companion (docs/Companion/LIVING_COMPANION.md):
//  the keepsakes of the character on screen stand as objects on a small
//  table in the 3D scene. Reads the keepsake rows (and the pictures they
//  point to), builds each object once (KeepsakePropFactory), places it on
//  the displayed model (VRMModel+SceneProps) and keeps the scene in step
//  with new keepsakes, the environment and the switch. Also tells the
//  persona what is on the table.
//
//  Created by Dedicatus on 05/11/2026.
//

import Foundation
import Metal
import simd

final class CompanionRoom {
    static let shared = CompanionRoom()

    private let store: MemoryStore

    // Built once per character and kept: GPU buffers are shared between
    // placements, and a character switch only re-places.
    private var tableProp: VRMProp?
    private var objectProps: [String: (object: RoomObject, prop: VRMProp)] = [:]

    // What stands in the scene now.
    private var placedModel: ObjectIdentifier?
    private var placedEnvironment = ""
    private var tablePlacement: VRMScenePlacement?
    private var placements: [RoomObjectKind: (object: RoomObject, placement: VRMScenePlacement)] = [:]
    private var visible = true
    private var buildTask: Task<Void, Never>?
    private var generation = 0

    init(store: MemoryStore = .shared) {
        self.store = store
    }

    // MARK: - What is on the table

    /// Where the table stands in `environment`.
    static func tableSpot(environment: String) -> RoomSpot {
        EnvironmentCatalog.option(for: environment).keepsakeTable ?? KeepsakeRoomRules.defaultTable
    }

    /// The objects a character's keepsakes make. A diary keepsake noted
    /// before pictures were kept with it borrows the oldest diary picture.
    func objects(character: String) -> [RoomObject] {
        KeepsakeRoomRules.objects(from: store.milestones(character: character)).map { object in
            guard object.kind == .frame, object.note.isEmpty,
                  let file = store.firstJournalPicture(character: character)
            else { return object }
            return RoomObject(kind: .frame, milestone: object.milestone, achievedAt: object.achievedAt, note: file)
        }
    }

    /// The `[Companion State]` line; nil when the table is empty or hidden.
    func promptLine(character: String) -> String? {
        guard UserSettings.shared.showKeepsakes else { return nil }
        return KeepsakeRoomRules.promptLine(for: objects(character: character))
    }

    /// The photograph a frame or polaroid shows, when its file is still there.
    func pictureData(for object: RoomObject) -> Data? {
        guard !object.note.isEmpty else { return nil }
        switch object.kind {
        case .frame:
            return CompanionSceneCapture.journalURL(named: object.note).flatMap { try? Data(contentsOf: $0) }
        case .polaroid:
            guard let url = PhotoMemoryService.directoryURL()?.appendingPathComponent(object.note),
                  FileManager.default.fileExists(atPath: url.path)
            else { return nil }
            return try? Data(contentsOf: url)
        default:
            return nil
        }
    }

    // MARK: - The scene

    /// Puts `character`'s keepsakes on `model` — or brings the ones there
    /// up to date. Objects are built off the main thread as needed and
    /// placed when ready; `onChange` runs after every change to the draw
    /// list (`VRMRenderer.invalidateRenderItems`).
    func place(
        character: String, on model: VRMModel, device: MTLDevice, environment: String,
        onChange: @escaping @MainActor () -> Void
    ) {
        if placedModel != ObjectIdentifier(model) {
            // The model that held them is gone; its nodes went with it.
            placedModel = ObjectIdentifier(model)
            tablePlacement = nil
            placements.removeAll()
        }
        placedEnvironment = environment
        let wanted = objects(character: character)
        let wantedByKind = Dictionary(uniqueKeysWithValues: wanted.map { ($0.kind, $0) })
        // Objects gone or changed (a plant that grew, a frame that got its picture) come off first.
        for (kind, entry) in placements where wantedByKind[kind] != entry.object {
            model.removeSceneProp(entry.placement)
            placements[kind] = nil
        }
        let missing = wanted.filter { placements[$0.kind] == nil }
        let table = Self.tableSpot(environment: environment)
        generation += 1
        let thisBuild = generation
        buildTask?.cancel()
        buildTask = Task { [weak self] in
            guard let self else { return }
            if tableProp == nil { tableProp = KeepsakePropFactory.table(device: device) }
            var built: [(RoomObject, VRMProp)] = []
            for object in missing {
                if let prop = await prop(for: object, character: character, device: device) { built.append((object, prop)) }
                if Task.isCancelled || generation != thisBuild { return }
            }
            guard placedModel == ObjectIdentifier(model) else { return }
            for (object, prop) in built {
                let placement = model.placeProp(prop, at: transform(for: object.kind, table: table), visible: visible)
                placements[object.kind] = (object, placement)
            }
            if let tableProp, tablePlacement == nil {
                tablePlacement = model.placeProp(tableProp, at: transform(forTable: table), visible: visible && !wanted.isEmpty)
            } else if let tablePlacement {
                model.setSceneProp(tablePlacement, visible: visible && !placements.isEmpty)
            }
            onChange()
            if !built.isEmpty {
                nlLog("[Room] \(character): \(placements.count) keepsake object(s) on the table", level: .info)
            }
        }
    }

    /// Per frame: the table follows the environment and the switch. Returns
    /// true when the draw list changed.
    func follow(environment: String, visible: Bool, on model: VRMModel) -> Bool {
        guard placedModel == ObjectIdentifier(model) else { return false }
        var changed = false
        if environment != placedEnvironment {
            placedEnvironment = environment
            let table = Self.tableSpot(environment: environment)
            if let tablePlacement { model.moveSceneProp(tablePlacement, to: transform(forTable: table)) }
            for (kind, entry) in placements { model.moveSceneProp(entry.placement, to: transform(for: kind, table: table)) }
        }
        if visible != self.visible {
            self.visible = visible
            for entry in placements.values { model.setSceneProp(entry.placement, visible: visible) }
            if let tablePlacement { model.setSceneProp(tablePlacement, visible: visible && !placements.isEmpty) }
            changed = true
        }
        return changed
    }

    /// A keepsake was just recorded: its object joins the table.
    func keepsakeRecorded() {
        VRMMetalState.active?.refreshRoom()
    }

    // MARK: - Helpers

    private func prop(for object: RoomObject, character: String, device: MTLDevice) async -> VRMProp? {
        let key = "\(character)|\(object.kind.rawValue)"
        if let cached = objectProps[key], cached.object == object { return cached.prop }
        let name = VRMModelRegistry.shared.entry(named: character)?.displayName ?? character
        guard let prop = await KeepsakePropFactory.prop(
            for: object, picture: pictureData(for: object), characterName: name, device: device)
        else { return nil }
        objectProps[key] = (object, prop)
        return prop
    }

    private func transform(for kind: RoomObjectKind, table: RoomSpot) -> RestTransform {
        let placed = KeepsakeRoomRules.placement(of: KeepsakeRoomRules.slot(for: kind), on: table)
        return RestTransform(rotation: placed.rotation, translation: placed.position, scale: SIMD3<Float>(repeating: 1))
    }

    private func transform(forTable table: RoomSpot) -> RestTransform {
        RestTransform(
            rotation: simd_quatf(angle: table.yaw, axis: SIMD3<Float>(0, 1, 0)),
            translation: table.position, scale: SIMD3<Float>(repeating: 1))
    }
}
