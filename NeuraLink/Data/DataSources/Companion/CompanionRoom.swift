//
//  CompanionRoom.swift
//  NeuraLink
//
//  A room that remembers — Living Companion (docs/Companion/LIVING_COMPANION.md):
//  the keepsakes of the character on screen stand as objects on a surface
//  beside them in the 3D scene — a side table indoors, stacked suitcases
//  outdoors, a chest on the open ground shown without an environment. Reads the
//  keepsake rows (and the pictures they point to), builds each object once
//  (KeepsakePropFactory), places it on the displayed model
//  (VRMModel+SceneProps) and keeps the scene in step with new keepsakes,
//  the environment and the switch. Also tells the persona what stands there.
//
//  Created by Dedicatus on 05/11/2026.
//

import Foundation
import Metal
import simd

final class CompanionRoom {
    static let shared = CompanionRoom()

    private let store: MemoryStore

    // Built once and kept: GPU buffers are shared between placements, a
    // character switch only re-places, and an environment switch swaps
    // the surface.
    private var surfaceProps: [KeepsakeSurface: VRMProp] = [:]
    private var objectProps: [String: (object: RoomObject, prop: VRMProp)] = [:]

    // What stands in the scene now.
    private var placedModel: ObjectIdentifier?
    private var placedScene: RoomScene?
    private var surfacePlacement: (surface: KeepsakeSurface, placement: VRMScenePlacement)?
    private var placements: [RoomObjectKind: (object: RoomObject, placement: VRMScenePlacement)] = [:]
    private var visible = true
    private var device: MTLDevice?
    private var buildTask: Task<Void, Never>?
    private var generation = 0

    init(store: MemoryStore = .shared) {
        self.store = store
    }

    // MARK: - What stands there

    /// The selected environment — nil while the 3D environment is off and
    /// the terrain's open ground shows instead.
    static var environmentKey: String? {
        UserSettings.shared.showEnvironment ? UserSettings.shared.selectedEnvironment : nil
    }

    /// What the keepsakes stand on in `environment`, and where.
    static func scene(environment: String?) -> RoomScene {
        EnvironmentCatalog.roomScene(for: environment)
    }

    /// The objects a character's keepsakes make. The frame shows its
    /// picture only while the file is still there (deleting the entry from
    /// the journal removes it); a diary keepsake without one borrows the
    /// oldest diary picture that remains, else it is the notebook.
    func objects(character: String) -> [RoomObject] {
        KeepsakeRoomRules.objects(from: store.milestones(character: character)).map { object in
            guard object.kind == .frame else { return object }
            if !object.note.isEmpty, CompanionSceneCapture.journalURL(named: object.note) != nil { return object }
            let fallback = store.firstJournalPicture(character: character)
                .flatMap { CompanionSceneCapture.journalURL(named: $0) != nil ? $0 : nil } ?? ""
            return RoomObject(kind: .frame, milestone: object.milestone, achievedAt: object.achievedAt, note: fallback)
        }
    }

    /// The `[Companion State]` line; nil when nothing stands there or the
    /// keepsakes are hidden. Names the surface the scene has now.
    func promptLine(character: String) -> String? {
        guard UserSettings.shared.showKeepsakes else { return nil }
        let surface = Self.scene(environment: Self.environmentKey).surface
        return KeepsakeRoomRules.promptLine(for: objects(character: character), on: surface)
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
        character: String, on model: VRMModel, device: MTLDevice, environment: String?,
        onChange: @escaping @MainActor () -> Void
    ) {
        if placedModel != ObjectIdentifier(model) {
            // The model that held them is gone; its nodes went with it.
            placedModel = ObjectIdentifier(model)
            surfacePlacement = nil
            placements.removeAll()
        }
        self.device = device
        let scene = Self.scene(environment: environment)
        if scene != placedScene, moveScene(to: scene, on: model) { onChange() }
        let wanted = objects(character: character)
        let wantedByKind = Dictionary(uniqueKeysWithValues: wanted.map { ($0.kind, $0) })
        // Objects gone or changed (a plant that grew, a frame that got its picture) come off first.
        for (kind, entry) in placements where wantedByKind[kind] != entry.object {
            model.removeSceneProp(entry.placement)
            placements[kind] = nil
        }
        let missing = wanted.filter { placements[$0.kind] == nil }
        generation += 1
        let thisBuild = generation
        buildTask?.cancel()
        buildTask = Task { [weak self] in
            guard let self else { return }
            var built: [(RoomObject, VRMProp)] = []
            for object in missing {
                if let prop = await prop(for: object, character: character, device: device) { built.append((object, prop)) }
                if Task.isCancelled || generation != thisBuild { return }
            }
            guard placedModel == ObjectIdentifier(model), let scene = placedScene else { return }
            for (object, prop) in built {
                let placement = model.placeProp(prop, at: transform(for: object.kind, in: scene), visible: visible)
                placements[object.kind] = (object, placement)
            }
            showSurface(on: model)
            onChange()
            if !built.isEmpty {
                nlLog("[Room] \(character): \(placements.count) keepsake object(s) on the \(scene.surface.rawValue)", level: .info)
            }
        }
    }

    /// Per frame: the surface follows the environment and the switch.
    /// Returns true when the draw list changed.
    func follow(environment: String?, visible: Bool, on model: VRMModel) -> Bool {
        guard placedModel == ObjectIdentifier(model) else { return false }
        var changed = false
        let scene = Self.scene(environment: environment)
        if scene != placedScene, moveScene(to: scene, on: model) { changed = true }
        if visible != self.visible {
            self.visible = visible
            for entry in placements.values { model.setSceneProp(entry.placement, visible: visible) }
            if let surfacePlacement { model.setSceneProp(surfacePlacement.placement, visible: visible && !placements.isEmpty) }
            changed = true
        }
        return changed
    }

    /// Something shown changed — a keepsake was recorded, a diary picture
    /// was deleted: the scene brings the objects up to date.
    func refresh() {
        VRMMetalState.active?.refreshRoom()
    }

    // MARK: - Helpers

    /// The objects move to `scene`'s surface; the surface standing there
    /// moves with them, or makes way for the scene's own kind. Returns
    /// true when the draw list changed.
    private func moveScene(to scene: RoomScene, on model: VRMModel) -> Bool {
        placedScene = scene
        for (kind, entry) in placements { model.moveSceneProp(entry.placement, to: transform(for: kind, in: scene)) }
        guard let current = surfacePlacement else { return false }
        if current.surface == scene.surface {
            model.moveSceneProp(current.placement, to: transform(forSurface: scene))
            return false
        }
        model.removeSceneProp(current.placement)
        surfacePlacement = nil
        showSurface(on: model)
        return true
    }

    /// The scene's surface stands under the objects, shown while there is
    /// something on it. Returns true when it was just added.
    @discardableResult
    private func showSurface(on model: VRMModel) -> Bool {
        guard let scene = placedScene, let device else { return false }
        let shown = visible && !placements.isEmpty
        if let current = surfacePlacement {
            model.setSceneProp(current.placement, visible: shown)
            return false
        }
        guard let prop = surfaceProp(scene.surface, device: device) else { return false }
        surfacePlacement = (scene.surface, model.placeProp(prop, at: transform(forSurface: scene), visible: shown))
        return true
    }

    private func surfaceProp(_ surface: KeepsakeSurface, device: MTLDevice) -> VRMProp? {
        if let cached = surfaceProps[surface] { return cached }
        let prop = KeepsakePropFactory.surface(surface, device: device)
        surfaceProps[surface] = prop
        return prop
    }

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

    private func transform(for kind: RoomObjectKind, in scene: RoomScene) -> RestTransform {
        let placed = KeepsakeRoomRules.placement(of: KeepsakeRoomRules.slot(for: kind), in: scene)
        return RestTransform(rotation: placed.rotation, translation: placed.position, scale: SIMD3<Float>(repeating: 1))
    }

    private func transform(forSurface scene: RoomScene) -> RestTransform {
        RestTransform(
            rotation: simd_quatf(angle: scene.spot.yaw, axis: SIMD3<Float>(0, 1, 0)),
            translation: scene.spot.position, scale: SIMD3<Float>(repeating: 1))
    }
}
