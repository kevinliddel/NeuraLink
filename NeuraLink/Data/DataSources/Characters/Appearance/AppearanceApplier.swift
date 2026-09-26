//
//  AppearanceApplier.swift
//  NeuraLink
//
//  Turns an AppearanceSpec into renderer state on the live model, in order:
//    1. parts   → VRMPartGrafter (restore base, re-graft every active part,
//                 refresh renderer structure); donor models load async;
//    2. colours → AppearanceMaterialLayer, keyed by material index (after
//                 parts, because grafts append materials);
//    3. textures → donor scan → straight upload → swap into the shared
//                 VRMTexture.
//  A generation counter drops stale async work when the user moves on or
//  the character switches. Never reloads the model.
//

import Foundation
import Metal
import MetalKit
import Observation

@Observable
@MainActor
final class AppearanceApplier {
    static let shared = AppearanceApplier()

    /// Minimum fraction of the target slot's UV cells the donor must cover
    /// (see `DonorSlotTexture.coverage(for:)`) for a texture swap.
    static let compatibilityThreshold: Float = 0.95

    /// True while a part graft (donor model load) is in flight — the panel
    /// shows a spinner on the cards.
    private(set) var isGrafting = false

    private var generation = 0
    private var coverageCache: (model: ObjectIdentifier, masks: [VRoidMaterialSlot: UVCoverageMask])?
    /// Most recent donor model, kept for cheap hair+outfit from one donor.
    private var donorCache: (slug: String, model: VRMModel)?
    private var donorLoads: [String: Task<VRMModel?, Never>] = [:]

    private init() {}

    // MARK: - Apply

    /// Applies the stored look for `slug` (clears when none is saved).
    func applyStored(slug: String, to state: VRMMetalState) {
        guard let spec = AppearanceStore.shared.spec(for: slug), !spec.isEmpty else {
            clear(on: state)
            return
        }
        apply(spec, to: state)
    }

    /// Applies `spec` to the model currently displayed by `state`.
    func apply(_ spec: AppearanceSpec, to state: VRMMetalState) {
        guard let model = state.currentModel, let renderer = state.renderer else { return }
        generation += 1
        let myGeneration = generation
        let layer = renderer.appearanceLayer

        // Colours first so sliders feel instant; re-applied after parts.
        applyRecolors(spec.recolors, model: model, layer: layer)

        Task { [weak self] in
            guard let self else { return }
            let partsChanged = await self.applyParts(spec.parts, model: model, renderer: renderer, generation: myGeneration)
            guard self.generation == myGeneration else { return }
            if partsChanged { self.applyRecolors(spec.recolors, model: model, layer: layer) }
            self.reconcileTextureOverrides(spec.textures, model: model, layer: layer)
            guard !spec.textures.isEmpty, let device = state.mtkView.device else { return }
            await self.applyTextures(spec.textures, model: model, layer: layer, device: device, generation: myGeneration)
        }
    }

    /// Restores the original look (parts, colours, textures) without
    /// touching the saved spec.
    func clear(on state: VRMMetalState) {
        generation += 1
        guard let renderer = state.renderer else { return }
        renderer.appearanceLayer.clearRecolors()
        if let model = state.currentModel {
            renderer.appearanceLayer.restoreAllTextures(in: model)
            if model.hasGrafts {
                model.restoreBaseComposition()
                renderer.refreshModelStructure()
            }
        }
    }

    /// Frees the cached donor model (panel closed).
    func releaseDonorCache() {
        donorCache = nil
    }

    // MARK: - Parts

    /// Returns true when the model's grafts changed.
    private func applyParts(
        _ parts: [AppearancePartKind: String], model: VRMModel, renderer: VRMRenderer, generation myGeneration: Int
    ) async -> Bool {
        let wanted = Dictionary(uniqueKeysWithValues: parts.map { ($0.key, $0.value.lowercased()) })
        let current = model.composition?.activeParts ?? [:]
        guard wanted != current else { return false }

        isGrafting = true
        defer { isGrafting = false }
        var donors: [String: VRMModel] = [:]
        for slug in Set(wanted.values) {
            if let donor = await donorModel(slug: slug) { donors[slug] = donor }
            guard generation == myGeneration else { return false }
        }

        model.restoreBaseComposition()
        for kind in AppearancePartKind.allCases {
            guard let slug = wanted[kind], let donor = donors[slug] else { continue }
            do {
                try VRMPartGrafter.graft(kind, from: donor, donorSlug: slug, onto: model)
            } catch {
                nlLog("[Appearance] graft \(kind.rawValue) from '\(slug)' failed: \(error.localizedDescription)", level: .warning)
            }
        }
        renderer.refreshModelStructure()
        coverageCache = nil
        return true
    }

    /// Fully loaded donor model (GPU buffers + textures), cached one deep.
    func donorModel(slug: String) async -> VRMModel? {
        let key = slug.lowercased()
        if let cached = donorCache, cached.slug == key { return cached.model }
        if let inFlight = donorLoads[key] { return await inFlight.value }
        guard let entry = VRMModelRegistry.shared.entry(named: key),
            let device = MTLCreateSystemDefaultDevice()
        else { return nil }
        let task = Task<VRMModel?, Never> {
            do {
                return try await VRMModel.load(from: entry.url, device: device)
            } catch {
                nlLog("[Appearance] donor model load failed for '\(key)': \(error.localizedDescription)", level: .warning)
                return nil
            }
        }
        donorLoads[key] = task
        let model = await task.value
        donorLoads[key] = nil
        if let model { donorCache = (key, model) }
        return model
    }

    // MARK: - Colours

    private func applyRecolors(_ recolors: [VRoidMaterialSlot: SlotRecolor], model: VRMModel, layer: AppearanceMaterialLayer) {
        layer.clearRecolors()
        let indicesBySlot = Self.materialIndicesBySlot(in: model)
        for (slot, recolor) in recolors where !recolor.isIdentity {
            for index in indicesBySlot[slot] ?? [] {
                layer.setRecolor(recolor, materialIndex: index)
            }
        }
    }

    // MARK: - Textures

    /// Restores overrides no longer requested.
    private func reconcileTextureOverrides(
        _ textures: [VRoidMaterialSlot: DonorTextureRef], model: VRMModel, layer: AppearanceMaterialLayer
    ) {
        let indicesBySlot = Self.materialIndicesBySlot(in: model)
        let wanted = Set(textures.keys.flatMap { slot in
            (indicesBySlot[slot] ?? []).compactMap { layer.baseTextureIndex(materialIndex: $0, in: model) }
        })
        for textureIndex in model.textures.indices
        where layer.isTextureOverridden(textureIndex: textureIndex) && !wanted.contains(textureIndex) {
            layer.restoreTexture(textureIndex: textureIndex, in: model)
        }
    }

    private func applyTextures(
        _ textures: [VRoidMaterialSlot: DonorTextureRef],
        model: VRMModel, layer: AppearanceMaterialLayer, device: MTLDevice, generation myGeneration: Int
    ) async {
        for (slot, ref) in textures {
            guard generation == myGeneration else { return }
            guard let scan = await donorScan(slug: ref.donorSlug), let donor = scan.slots[ref.slot] else { continue }
            guard isCompatible(donor: donor, slot: slot, model: model) else {
                nlLog("[Appearance] '\(ref.donorSlug)' \(ref.slot.rawValue) does not cover this model's \(slot.rawValue) UVs — skipped", level: .info)
                continue
            }
            let texture = await Task.detached(priority: .userInitiated) { () -> MTLTexture? in
                AppearanceTextureFactory.makeTexture(imageData: donor.imageData, device: device)
            }.value
            guard generation == myGeneration, let texture else { continue }
            for materialIndex in Self.materialIndices(for: slot, in: model) {
                if let textureIndex = layer.baseTextureIndex(materialIndex: materialIndex, in: model) {
                    layer.overrideTexture(texture, textureIndex: textureIndex, in: model)
                }
            }
        }
    }

    // MARK: - Donors

    /// Scans a registry character's file; nil when unknown or unreadable.
    func donorScan(slug: String) async -> DonorScan? {
        guard let entry = VRMModelRegistry.shared.entry(named: slug) else { return nil }
        do {
            return try await VRMDonorTextureCache.shared.scan(url: entry.url, slug: entry.name)
        } catch {
            nlLog("[Appearance] donor scan failed for '\(slug)': \(error.localizedDescription)", level: .warning)
            return nil
        }
    }

    /// True when the donor texture covers (almost) every atlas cell the
    /// target slot samples.
    func isCompatible(donor: DonorSlotTexture, slot: VRoidMaterialSlot, model: VRMModel) -> Bool {
        guard let target = targetCoverage(for: slot, in: model), !target.isEmpty else { return false }
        return target.fraction(coveredBy: donor.coverage(for: slot)) >= Self.compatibilityThreshold
    }

    /// Union of the UV footprints of every BASE primitive drawn with a
    /// material of `slot` (grafted parts excluded — they carry their own
    /// textures). Cached per model instance.
    func targetCoverage(for slot: VRoidMaterialSlot, in model: VRMModel) -> UVCoverageMask? {
        let id = ObjectIdentifier(model)
        if let cached = coverageCache, cached.model == id, let mask = cached.masks[slot] {
            return mask
        }
        var masks = (coverageCache?.model == id) ? (coverageCache?.masks ?? [:]) : [:]
        var union = UVCoverageMask()
        let meshes = model.composition?.snapshot.meshes ?? model.meshes
        for mesh in meshes {
            for primitive in mesh.primitives {
                guard let materialIndex = primitive.materialIndex, materialIndex < model.materials.count,
                    VRoidMaterialSlot.classify(materialName: model.materials[materialIndex].name) == slot,
                    let coverage = primitive.computeUVCoverage()
                else { continue }
                union.formUnion(coverage)
            }
        }
        masks[slot] = union
        coverageCache = (id, masks)
        return union
    }

    // MARK: - Slots

    nonisolated static func materialIndices(for slot: VRoidMaterialSlot, in model: VRMModel) -> [Int] {
        model.materials.indices.filter {
            VRoidMaterialSlot.classify(materialName: model.materials[$0].name) == slot
        }
    }

    nonisolated static func materialIndicesBySlot(in model: VRMModel) -> [VRoidMaterialSlot: [Int]] {
        var result: [VRoidMaterialSlot: [Int]] = [:]
        for (index, material) in model.materials.enumerated() {
            result[VRoidMaterialSlot.classify(materialName: material.name), default: []].append(index)
        }
        return result
    }

    /// Slots the BASE model has materials for (drives the panel's tabs).
    nonisolated static func presentSlots(in model: VRMModel) -> Set<VRoidMaterialSlot> {
        let materials = model.composition?.snapshot.materials ?? model.materials
        return Set(materials.map { VRoidMaterialSlot.classify(materialName: $0.name) }).subtracting([.other])
    }
}
