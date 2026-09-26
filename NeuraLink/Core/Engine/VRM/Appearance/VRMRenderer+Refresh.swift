//
//  VRMRenderer+Refresh.swift
//  NeuraLink
//
//  Re-initializes the per-model renderer subsystems after a part graft or
//  restore changed the model's meshes/skins/springs in place — the parts of
//  `loadModel` that depend on structure, without touching expressions, the
//  look-at controller or the expression colour seeds.
//

import Foundation
import Metal

extension VRMRenderer {

    /// Call after `VRMPartGrafter.graft` / `restoreBaseComposition`.
    public func refreshModelStructure() {
        guard let model else { return }
        cacheNeedsRebuild = true
        cachedRenderItems = nil

        if !model.skins.isEmpty {
            skinningSystem?.setupForSkins(model.skins)
        }

        if model.springBone != nil, let device = model.device {
            do {
                // Chains are already expanded (the model was loaded with a
                // device); re-expanding would duplicate them.
                try model.initializeSpringBoneGPUSystem(device: device, expandChains: false)
                try springBoneComputeSystem?.populateSpringBoneData(model: model)
                springBoneComputeSystem?.warmupPhysics(model: model, steps: 30)
            } catch {
                nlLog("[VRMRenderer] spring bone refresh failed: \(error)", level: .warning)
            }
        }
        enableSpringBone = model.springBone != nil
    }
}
