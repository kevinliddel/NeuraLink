//
//  VRMRenderer+ItemDraw.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import Foundation
@preconcurrency import Metal
import simd

// MARK: - Per-Item Draw Helpers

extension VRMRenderer {

    // MARK: Depth / Cull State

    func applyDepthCullState(
        for item: RenderItem,
        encoder: MTLRenderCommandEncoder,
        materialAlphaMode: String,
        isDoubleSided: Bool
    ) {
        // FACE RENDERING: Apply deterministic states per face category
        if let faceCategory = item.faceCategory {
            switch faceCategory {
            case "body":
                // Body (with lace texture) renders FIRST (order=0)
                // Uses lessEqual - later materials win at equal depths
                // Depth bias: pushed back slightly to allow clothing/skin to win at seams
                if let faceState = depthStencilStates["face"] {
                    setDepthStencilStateCached(faceState, encoder: encoder)
                } else {
                    setDepthStencilStateCached(depthStencilStates["opaque"], encoder: encoder)
                }
                setCullModeCached(isDoubleSided ? .none : .back, encoder: encoder)
                setFrontFacingCached(.counterClockwise, encoder: encoder)
                // Z-FIGHTING FIX: Body renders first but pushed back in depth
                // Negative bias pushes away from camera, allowing overlays to win
                setDepthBiasCached(-0.1, slopeScale: 4.0, clamp: 1.0, encoder: encoder)

            case "clothing":
                // Clothing renders AFTER body - wins at overlaps via render order
                if let faceState = depthStencilStates["face"] {
                    setDepthStencilStateCached(faceState, encoder: encoder)
                } else {
                    setDepthStencilStateCached(depthStencilStates["opaque"], encoder: encoder)
                }
                setCullModeCached(isDoubleSided ? .none : .back, encoder: encoder)
                setFrontFacingCached(.counterClockwise, encoder: encoder)
                // Apply depth bias for clothing (overlay layer)
                let bias = depthBiasCalculator.depthBias(for: item.materialName, isOverlay: true)
                setDepthBiasCached(
                    bias, slopeScale: depthBiasCalculator.slopeScale,
                    clamp: depthBiasCalculator.clamp, encoder: encoder)

            case "skin":
                // Face skin renders AFTER body - wins at neck seam via render order
                // Z-FIGHTING FIX: Use different depth states for base vs overlay materials
                let isOverlay = item.isMouthOrLip || item.materialNameLower.contains("eyebrow")

                if isOverlay {
                    // Overlay materials (mouth, eyebrows): use faceOverlay state
                    // lessEqual allows winning at equal depth, no depth write prevents Z-fighting
                    if let overlayState = depthStencilStates["faceOverlay"] {
                        setDepthStencilStateCached(overlayState, encoder: encoder)
                    } else {
                        setDepthStencilStateCached(depthStencilStates["face"], encoder: encoder)
                    }
                } else {
                    // Base face skin: use normal face state with depth write
                    if let faceState = depthStencilStates["face"] {
                        setDepthStencilStateCached(faceState, encoder: encoder)
                    } else {
                        setDepthStencilStateCached(depthStencilStates["opaque"], encoder: encoder)
                    }
                }

                setCullModeCached(isDoubleSided ? .none : .back, encoder: encoder)
                setFrontFacingCached(.counterClockwise, encoder: encoder)

                // Apply material-specific depth bias from calculator
                let bias = depthBiasCalculator.depthBias(
                    for: item.materialName,
                    isOverlay: isOverlay
                )
                setDepthBiasCached(
                    bias, slopeScale: depthBiasCalculator.slopeScale,
                    clamp: depthBiasCalculator.clamp, encoder: encoder)

            case "faceOverlay":
                // Face mouth/lip overlays - render on top of face skin
                // Uses face state with depth bias to win depth test
                if let faceState = depthStencilStates["face"] {
                    setDepthStencilStateCached(faceState, encoder: encoder)
                } else {
                    setDepthStencilStateCached(depthStencilStates["mask"], encoder: encoder)
                }
                setCullModeCached(.none, encoder: encoder)
                setFrontFacingCached(.counterClockwise, encoder: encoder)
                // Apply depth bias for mouth/lip overlays
                let bias = depthBiasCalculator.depthBias(for: item.materialName, isOverlay: true)
                setDepthBiasCached(
                    bias, slopeScale: depthBiasCalculator.slopeScale,
                    clamp: depthBiasCalculator.clamp, encoder: encoder)
            // Face overlays use MASK mode for proper alpha cutout
            // This allows mouth/lip shapes to be properly masked without
            // edge artifacts from OPAQUE mode blending

            case "eyebrow", "eyeline":
                // Face features render after skin - win via render order
                if let faceState = depthStencilStates["face"] {
                    setDepthStencilStateCached(faceState, encoder: encoder)
                } else {
                    setDepthStencilStateCached(depthStencilStates["mask"], encoder: encoder)
                }
                setCullModeCached(.none, encoder: encoder)
                setFrontFacingCached(.counterClockwise, encoder: encoder)
                // Apply depth bias for eyebrow/eyeline overlays
                let bias = depthBiasCalculator.depthBias(for: item.materialName, isOverlay: true)
                setDepthBiasCached(
                    bias, slopeScale: depthBiasCalculator.slopeScale,
                    clamp: depthBiasCalculator.clamp, encoder: encoder)

            case "eye":
                // Eyes render after skin - win via render order
                // Depth bias: higher bias to ensure eyes win over eyelids/face
                if let faceState = depthStencilStates["face"] {
                    setDepthStencilStateCached(faceState, encoder: encoder)
                } else {
                    setDepthStencilStateCached(depthStencilStates["opaque"], encoder: encoder)
                }
                setCullModeCached(.none, encoder: encoder)
                setFrontFacingCached(.counterClockwise, encoder: encoder)
                // Apply depth bias for eye overlays (highest priority)
                let bias = depthBiasCalculator.depthBias(for: item.materialName, isOverlay: true)
                setDepthBiasCached(
                    bias, slopeScale: depthBiasCalculator.slopeScale,
                    clamp: depthBiasCalculator.clamp, encoder: encoder)

            case "highlight":
                // Eye highlights render last - win via render order
                if let blendDepthState = depthStencilStates["blend"] {
                    setDepthStencilStateCached(blendDepthState, encoder: encoder)
                } else {
                    setDepthStencilStateCached(depthStencilStates["opaque"], encoder: encoder)
                }
                setCullModeCached(.none, encoder: encoder)
                setFrontFacingCached(.counterClockwise, encoder: encoder)
                // Apply depth bias for highlight overlays (highest bias)
                let bias = depthBiasCalculator.depthBias(for: item.materialName, isOverlay: true)
                setDepthBiasCached(
                    bias, slopeScale: depthBiasCalculator.slopeScale,
                    clamp: depthBiasCalculator.clamp, encoder: encoder)

            case "transparentZWrite":
                // TransparentWithZWrite: blend with depth write ON
                // Uses face state (.lessEqual + depth write) to occlude what's behind
                // Key for lace, collar, and semi-transparent overlays
                if let faceState = depthStencilStates["face"] {
                    setDepthStencilStateCached(faceState, encoder: encoder)
                } else {
                    setDepthStencilStateCached(depthStencilStates["opaque"], encoder: encoder)
                }
                setCullModeCached(.none, encoder: encoder)  // Often double-sided for overlays
                setFrontFacingCached(.counterClockwise, encoder: encoder)
                // Apply depth bias for transparent overlays
                let bias = depthBiasCalculator.depthBias(for: item.materialName, isOverlay: true)
                setDepthBiasCached(
                    bias, slopeScale: depthBiasCalculator.slopeScale,
                    clamp: depthBiasCalculator.clamp, encoder: encoder)

            default:
                // Unknown face category - fallback to opaque
                setDepthStencilStateCached(depthStencilStates["opaque"], encoder: encoder)
                setCullModeCached(isDoubleSided ? .none : .back, encoder: encoder)
                setFrontFacingCached(.counterClockwise, encoder: encoder)
            }
        } else {
            // NON-FACE rendering: use standard alpha mode logic
            // Apply material-specific depth bias for all non-face materials
            let baseBias = depthBiasCalculator.depthBias(for: item.materialName, isOverlay: false)

            switch materialAlphaMode {
            case "opaque":
                setDepthStencilStateCached(depthStencilStates["opaque"], encoder: encoder)
                let cullMode = isDoubleSided ? MTLCullMode.none : .back
                setCullModeCached(cullMode, encoder: encoder)
                setFrontFacingCached(.counterClockwise, encoder: encoder)
                setDepthBiasCached(
                    baseBias, slopeScale: depthBiasCalculator.slopeScale,
                    clamp: depthBiasCalculator.clamp, encoder: encoder)

            case "mask":
                setDepthStencilStateCached(depthStencilStates["mask"], encoder: encoder)
                let cullMode = isDoubleSided ? MTLCullMode.none : .back
                setCullModeCached(cullMode, encoder: encoder)
                setFrontFacingCached(.counterClockwise, encoder: encoder)
                // Apply base depth bias for MASK materials
                setDepthBiasCached(
                    baseBias, slopeScale: depthBiasCalculator.slopeScale,
                    clamp: depthBiasCalculator.clamp, encoder: encoder)

            case "blend":
                if let blendDepthState = depthStencilStates["blend"] {
                    setDepthStencilStateCached(blendDepthState, encoder: encoder)
                } else {
                    setDepthStencilStateCached(depthStencilStates["opaque"], encoder: encoder)
                }
                setCullModeCached(.none, encoder: encoder)
                // Apply base depth bias for BLEND materials
                setDepthBiasCached(
                    baseBias, slopeScale: depthBiasCalculator.slopeScale,
                    clamp: depthBiasCalculator.clamp, encoder: encoder)

            default:
                setDepthStencilStateCached(depthStencilStates["opaque"], encoder: encoder)
                let cullMode = isDoubleSided ? MTLCullMode.none : .back
                setCullModeCached(cullMode, encoder: encoder)
                setDepthBiasCached(
                    baseBias, slopeScale: depthBiasCalculator.slopeScale,
                    clamp: depthBiasCalculator.clamp, encoder: encoder)
            }
        }
    }

    // MARK: Material Uniforms

    func buildMaterialUniforms(
        for item: RenderItem,
        model: VRMModel,
        materialAlphaMode: String
    ) -> MToonMaterialUniforms {
        // Set material and textures using MToon system
        // Initialize with sensible defaults to prevent white rendering
        var mtoonUniforms = MToonMaterialUniforms()
        mtoonUniforms.baseColorFactor = SIMD4<Float>(1.0, 1.0, 1.0, 1.0)  // White base

        let primitive = item.primitive

        let isFaceMaterial = item.isFaceMaterial

        if let materialIndex = primitive.materialIndex,
            materialIndex < model.materials.count {
            let material = model.materials[materialIndex]

            // Set VRM version for version-aware shading (0 = VRM 0.0, 1 = VRM 1.0)
            mtoonUniforms.vrmVersion = material.vrmVersion == .v0_0 ? 0 : 1

            // Set base PBR properties
            mtoonUniforms.baseColorFactor = material.baseColorFactor
            mtoonUniforms.metallicFactor = material.metallicFactor
            mtoonUniforms.roughnessFactor = material.roughnessFactor
            mtoonUniforms.emissiveFactor = material.emissiveFactor

            // LIGHTING FIX: Zero out emissive to prevent washout
            mtoonUniforms.emissiveFactor = SIMD3<Float>(0, 0, 0)

            // PHASE 4 FIX: Force face materials to render with full brightness
            if isFaceMaterial {
                // Force white baseColorFactor for face materials to show texture at full brightness
                mtoonUniforms.baseColorFactor = SIMD4<Float>(1.0, 1.0, 1.0, 1.0)

                // LIGHTING FIX: Improve face shading for contours (skin only, not eyes)
                if item.faceCategory != "eye" {
                    mtoonUniforms.shadeColorFactor = SIMD3<Float>(0.78, 0.65, 0.60)  // Stronger warm shadow
                    mtoonUniforms.shadingToonyFactor = 0.3  // Even softer transition
                    mtoonUniforms.shadingShiftFactor = -0.2  // More shadow for contours
                }

                // Ensure texture flag is set
                if material.baseColorTexture != nil {
                    mtoonUniforms.hasBaseColorTexture = 1
                }
            }

            // Set alpha mode properties - DO NOT override for face parts
            if isFaceMaterial {
                // Preserve original alpha behavior for face parts (skin/eyes/lashes/lines)
                switch materialAlphaMode {
                case "mask": mtoonUniforms.alphaMode = 1
                case "blend": mtoonUniforms.alphaMode = 2
                default: mtoonUniforms.alphaMode = 0
                }
                mtoonUniforms.alphaCutoff = item.effectiveAlphaCutoff
            } else {
                // Use EFFECTIVE alpha mode for other materials and non-mask face materials
                switch item.effectiveAlphaMode {
                case "mask":
                    mtoonUniforms.alphaMode = 1
                case "blend":
                    mtoonUniforms.alphaMode = 2
                default:  // "opaque" or unknown
                    mtoonUniforms.alphaMode = 0
                }
                mtoonUniforms.alphaCutoff = item.effectiveAlphaCutoff
            }

            // If material has MToon extension, use those properties
            if let mtoon = material.mtoon {
                mtoonUniforms = MToonMaterialUniforms(from: mtoon)
                mtoonUniforms.baseColorFactor = material.baseColorFactor  // Keep base color from PBR
                // Set VRM version for version-aware shading (0 = VRM 0.0, 1 = VRM 1.0)
                mtoonUniforms.vrmVersion = material.vrmVersion == .v0_0 ? 0 : 1

                // UV FIX: Shift FaceMouth UVs to lip texture area (bottom right of atlas)
                if item.isMouthOrLip {
                    mtoonUniforms.uvOffsetX = 0.35  // Shift right to lip area
                    mtoonUniforms.uvOffsetY = 0.25  // Shift down to lip area
                    mtoonUniforms.uvScale = 0.5  // Scale down to fit lip texture
                }

                // LIGHTING FIX: Zero emissive AFTER MToon init to prevent washout
                mtoonUniforms.emissiveFactor = SIMD3<Float>(0, 0, 0)

                // ALPHA FIX: Restore effectiveAlphaMode AFTER MToon init
                // MToon extension may have wrong alphaMode; use our detected/fixed value
                switch item.effectiveAlphaMode {
                case "mask":
                    mtoonUniforms.alphaMode = 1
                    mtoonUniforms.alphaCutoff = item.effectiveAlphaCutoff
                case "blend":
                    mtoonUniforms.alphaMode = 2
                default:
                    mtoonUniforms.alphaMode = 0
                }
            } else {
                // NO MToon extension - use default PBR values
                switch item.effectiveAlphaMode {
                case "mask":
                    mtoonUniforms.alphaMode = 1
                case "blend":
                    mtoonUniforms.alphaMode = 2
                default:
                    mtoonUniforms.alphaMode = 0
                }
                mtoonUniforms.alphaCutoff = item.effectiveAlphaCutoff

                // Eye material rendering adjustments
                if let faceCat = item.faceCategory, faceCat == "eye" {
                    // Eyes should appear vivid and unshaded; disable stylized shading paths
                    mtoonUniforms.shadeColorFactor = SIMD3<Float>(repeating: 1.0)
                    mtoonUniforms.shadingToonyFactor = 0.0
                    mtoonUniforms.shadingShiftFactor = 0.0
                    mtoonUniforms.rimLightingMixFactor = 0.0
                    mtoonUniforms.parametricRimColorFactor = SIMD3<Float>(repeating: 0.0)
                    mtoonUniforms.hasMatcapTexture = 0
                }
            }

            // Bind textures in MToon order
            // Index 0: Base color texture
            // (Texture binding is done inline in drawCore since it requires the encoder)
        }

        return mtoonUniforms
    }
}
