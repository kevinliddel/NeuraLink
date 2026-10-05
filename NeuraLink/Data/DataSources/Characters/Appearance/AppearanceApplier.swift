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
    /// Recently loaded donor models keyed by "slug#part" (a part load skips
    /// the textures the part doesn't use). Two deep: hair + outfit of the
    /// donor being tried.
    private var donorCache: [(key: String, model: VRMModel)] = []
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

    /// Same, but doesn't return until the look is actually on the model.
    ///
    /// Used on load: grafting is asynchronous, so a caller that displays the
    /// model and moves on shows the character in its original clothes for a
    /// beat before the saved outfit appears.
    func applyStoredAndWait(slug: String, to state: VRMMetalState) async {
        guard let spec = AppearanceStore.shared.spec(for: slug), !spec.isEmpty else {
            clear(on: state)
            return
        }
        guard let plan = beginApplying(spec, to: state) else { return }
        await finishApplying(plan)
    }

    /// Applies `spec` to the model currently displayed by `state`.
    func apply(_ spec: AppearanceSpec, to state: VRMMetalState) {
        guard let plan = beginApplying(spec, to: state) else { return }
        Task { [weak self] in
            await self?.finishApplying(plan)
            // The widget portrait follows the new look (debounced inside —
            // a slider drag re-renders once it settles).
            CompanionSnapshotWriter.shared.refreshPortrait(from: state)
        }
    }

    /// What one application needs, captured before any awaiting so a model
    /// swap mid-flight is caught by the generation check rather than by
    /// reading changed state.
    private struct ApplyPlan {
        let spec: AppearanceSpec
        let state: VRMMetalState
        let model: VRMModel
        let renderer: VRMRenderer
        let layer: AppearanceMaterialLayer
        let generation: Int
    }

    private func beginApplying(_ spec: AppearanceSpec, to state: VRMMetalState) -> ApplyPlan? {
        guard let model = state.currentModel, let renderer = state.renderer else { return nil }
        generation += 1
        let layer = renderer.appearanceLayer
        // Colours first so sliders feel instant; re-applied after parts.
        applyRecolors(spec.recolors, model: model, layer: layer)
        return ApplyPlan(
            spec: spec, state: state, model: model, renderer: renderer, layer: layer,
            generation: generation)
    }

    private func finishApplying(_ plan: ApplyPlan) async {
        let partsChanged = await applyParts(
            plan.spec.parts, model: plan.model, renderer: plan.renderer, generation: plan.generation)
        guard generation == plan.generation else { return }
        if partsChanged { applyRecolors(plan.spec.recolors, model: plan.model, layer: plan.layer) }
        reconcileTextureOverrides(plan.spec.textures, model: plan.model, layer: plan.layer)
        guard !plan.spec.textures.isEmpty, let device = plan.state.mtkView.device else { return }
        await applyTextures(
            plan.spec.textures, model: plan.model, layer: plan.layer, device: device,
            generation: plan.generation)
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
        CompanionSnapshotWriter.shared.refreshPortrait(from: state)
    }

    /// Frees the cached donor models (panel closed).
    func releaseDonorCache() {
        donorCache.removeAll()
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
        var donors: [AppearancePartKind: VRMModel] = [:]
        for (kind, slug) in wanted {
            if let donor = await donorModel(slug: slug, part: kind) { donors[kind] = donor }
            guard generation == myGeneration else { return false }
        }

        model.restoreBaseComposition()
        for kind in AppearancePartKind.allCases {
            guard let slug = wanted[kind], let donor = donors[kind] else { continue }
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

    /// Loaded donor model. With `part`, only the textures that part uses
    /// are decoded (the scan knows which) — a hair load is a fraction of a
    /// full one. Cached two deep.
    func donorModel(slug: String, part: AppearancePartKind? = nil) async -> VRMModel? {
        let key = "\(slug.lowercased())#\(part?.rawValue ?? "full")"
        if let cached = donorCache.first(where: { $0.key == key }) { return cached.model }
        if let inFlight = donorLoads[key] { return await inFlight.value }
        guard let source = await donorSource(slug: slug),
            let device = MTLCreateSystemDefaultDevice()
        else { return nil }
        var filter: Set<Int>?
        if let part, let scan = await donorScan(slug: slug), let indices = scan.partTextureIndices[part] {
            filter = indices
        }
        let options = VRMLoadingOptions(textureIndexFilter: filter)
        let task = Task<VRMModel?, Never> {
            do {
                return try await VRMModel.load(from: source.url, device: device, options: options)
            } catch {
                nlLog("[Appearance] donor model load failed for '\(key)': \(error.localizedDescription)", level: .warning)
                return nil
            }
        }
        donorLoads[key] = task
        let model = await task.value
        donorLoads[key] = nil
        if let model {
            donorCache.removeAll { $0.key == key }
            donorCache.append((key, model))
            if donorCache.count > 2 { donorCache.removeFirst() }
        }
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
            guard await isCompatible(donor: donor, slot: slot, model: model) else {
                nlLog("[Appearance] '\(ref.donorSlug)' \(ref.slot.rawValue) does not cover this model's \(slot.rawValue) UVs — skipped", level: .info)
                continue
            }
            let texture = await Task.detached(priority: .userInitiated) { () -> MTLTexture? in
                guard let data = donor.loadImageData() else { return nil }
                return AppearanceTextureFactory.makeTexture(imageData: data, device: device)
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
        guard let source = await donorSource(slug: slug) else { return nil }
        do {
            return try await VRMDonorTextureCache.shared.scan(url: source.url, slug: source.name)
        } catch {
            nlLog("[Appearance] donor scan failed for '\(slug)': \(error.localizedDescription)", level: .warning)
            return nil
        }
    }

    /// True when the donor texture covers (almost) every atlas cell the
    /// target slot samples. Decodes the donor texture (once per image) for
    /// its painted-area masks.
    func isCompatible(donor: DonorSlotTexture, slot: VRoidMaterialSlot, model: VRMModel) async -> Bool {
        guard let target = targetCoverage(for: slot, in: model), !target.isEmpty else { return false }
        // Cheap pre-check: the donor's own UV footprint alone may already cover it.
        if target.fraction(coveredBy: donor.uvCoverage) >= Self.compatibilityThreshold { return true }
        guard let masks = await VRMDonorTextureCache.shared.coverageMasks(for: donor) else { return false }
        return target.fraction(coveredBy: donor.coverage(for: slot, masks: masks)) >= Self.compatibilityThreshold
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
                    model.slot(ofMaterial: materialIndex) == slot,
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
        model.materials.indices.filter { model.slot(ofMaterial: $0) == slot }
    }

    nonisolated static func materialIndicesBySlot(in model: VRMModel) -> [VRoidMaterialSlot: [Int]] {
        var result: [VRoidMaterialSlot: [Int]] = [:]
        for index in model.materials.indices {
            result[model.slot(ofMaterial: index), default: []].append(index)
        }
        return result
    }

    /// Slots the BASE model has materials for (drives the panel's tabs).
    nonisolated static func presentSlots(in model: VRMModel) -> Set<VRoidMaterialSlot> {
        let baseCount = model.composition?.snapshot.materials.count ?? model.materials.count
        return Set((0..<baseCount).map { model.slot(ofMaterial: $0) }).subtracting([.other])
    }

    // MARK: - Donor sources

    /// A donor is either another character in the registry (slug) or a
    /// parts-library model (`lib:<stem>`, see PartsLibrary). A library part
    /// lives in the Hugging Face dataset, so resolving one may have to wait
    /// for it to arrive; a character is always in the app already.
    func donorSource(slug: String) async -> (url: URL, name: String, displayName: String)? {
        if let item = PartsLibrary.shared.item(slug: slug) {
            guard let url = try? await item.resolvedURL() else {
                nlLog("[Appearance] part '\(slug)' has not been downloaded yet", level: .warning)
                return nil
            }
            return (url, item.donorSlug, item.displayName)
        }
        guard let entry = VRMModelRegistry.shared.entry(named: slug) else { return nil }
        return (entry.url, entry.name.lowercased(), entry.displayName)
    }
}
