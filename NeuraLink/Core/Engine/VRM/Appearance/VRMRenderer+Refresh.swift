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

    /// Rebuilds the render-item list on the next frame and nothing else —
    /// for showing or hiding a prop's node, where `refreshModelStructure`'s
    /// spring-bone reset would make the hair jump.
    public func invalidateRenderItems() {
        cacheNeedsRebuild = true
        cachedRenderItems = nil
    }

    /// Call after `VRMPartGrafter.graft` / `restoreBaseComposition`.
    public func refreshModelStructure() {
        guard let model else { return }
        cacheNeedsRebuild = true
        cachedRenderItems = nil

        if !model.skins.isEmpty {
            skinningSystem?.setupForSkins(model.skins)
        }

        // A graft added or removed chains: rebuild the joints (from the rest
        // pose, not the current animated one) and settle them again.
        springBoneSolver.invalidate()
        enableSpringBone = model.springBone != nil
    }
}
