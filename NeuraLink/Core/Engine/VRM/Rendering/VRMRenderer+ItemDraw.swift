//
//  VRMRenderer+ItemDraw.swift
//  NeuraLink
//
//  Per-draw state from the material as authored: the depth state and
//  culling its alpha mode calls for, and the MToon uniforms.
//
//  Created by Dedicatus on 16/04/2026.
//

import Foundation
@preconcurrency import Metal
import simd

// MARK: - Per-Item Draw Helpers

extension VRMRenderer {

    // MARK: Depth / Cull State

    /// No depth bias: VRM layers (brows, lashes, the mouth) are modelled
    /// apart from the skin, and a bias let hidden layers win at grazing
    /// angles (eye whites through lids, the inside of a collar).
    func applyDepthCullState(
        for item: RenderItem,
        encoder: MTLRenderCommandEncoder,
        materialAlphaMode: String,
        isDoubleSided: Bool
    ) {
        let depthState: MTLDepthStencilState?
        switch materialAlphaMode {
        case "mask":
            depthState = depthStencilStates["mask"]
        case "blend":
            // TransparentWithZWrite: blend with depth write on (the "face"
            // state is lessEqual + write).
            depthState = item.transparentZWrite ? depthStencilStates["face"] : depthStencilStates["blend"]
        default:
            depthState = depthStencilStates["opaque"]
        }
        setDepthStencilStateCached(depthState ?? depthStencilStates["opaque"], encoder: encoder)
        // Plain transparents draw both sides (no depth write, sorted), as
        // before; everything else honours the material's culling.
        let cullsBack = !isDoubleSided && !(materialAlphaMode == "blend" && !item.transparentZWrite)
        setCullModeCached(cullsBack ? .back : .none, encoder: encoder)
        setFrontFacingCached(.counterClockwise, encoder: encoder)
        setDepthBiasCached(0, slopeScale: 0, clamp: 0, encoder: encoder)
    }

    // MARK: Material Uniforms

    func buildMaterialUniforms(
        for item: RenderItem,
        model: VRMModel,
        materialAlphaMode: String
    ) -> MToonMaterialUniforms {
        var mtoonUniforms = MToonMaterialUniforms()
        mtoonUniforms.baseColorFactor = SIMD4<Float>(1.0, 1.0, 1.0, 1.0)

        guard let materialIndex = item.primitive.materialIndex, materialIndex < model.materials.count else {
            return mtoonUniforms
        }
        let material = model.materials[materialIndex]

        if let mtoon = material.mtoon {
            mtoonUniforms = MToonMaterialUniforms(from: mtoon)
            // (from:) resets normalScale to 1, which would drop glTF
            // normalTexture.scale / VRM 0.x _BumpScale.
            mtoonUniforms.normalScale = material.normalScale
        } else {
            mtoonUniforms.normalScale = material.normalScale
            mtoonUniforms.roughnessFactor = material.roughnessFactor
        }
        mtoonUniforms.baseColorFactor = material.baseColorFactor
        // Version-aware shading (0 = VRM 0.x smoothstep, 1 = VRM 1.0 linearstep).
        mtoonUniforms.vrmVersion = material.vrmVersion == .v0_0 ? 0 : 1
        // Emission from the glTF material (spec: factor × map); the MToon
        // init doesn't carry it. UV animation runs on the clock.
        mtoonUniforms.emissiveFactor = material.effectiveEmissiveFactor
        mtoonUniforms.time = materialTime
        mtoonUniforms.setUVTransform(
            expressionController?.textureTransformOverride(forMaterial: materialIndex) ?? material.uvTransform)

        switch materialAlphaMode {
        case "mask":
            // With MSAA, cutout draws through the alpha-to-coverage pipeline:
            // the shader turns alpha into a sharpened coverage (mode 3)
            // instead of discarding, so hair-strand edges are anti-aliased.
            mtoonUniforms.alphaMode = usesMultisampling ? 3 : 1
            mtoonUniforms.alphaCutoff = item.alphaCutoff
        case "blend":
            mtoonUniforms.alphaMode = 2
        default:
            mtoonUniforms.alphaMode = 0
        }

        // Character customization: per-material HSV recolour (Tier A).
        if let recolor = appearanceLayer.recolor(forMaterial: materialIndex) {
            mtoonUniforms.recolorHueShift = recolor.hueShift / 360.0
            mtoonUniforms.recolorSaturation = recolor.saturation
            mtoonUniforms.recolorBrightness = recolor.brightness
            mtoonUniforms.recolorEnabled = 1
        }
        return mtoonUniforms
    }
}
