//
//  VRMGeometry+Material.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import Foundation
import Metal
import simd

// MARK: - VRM Material

public class VRMMaterial {
    public let name: String?
    public var baseColorFactor: SIMD4<Float> = [1, 1, 1, 1]
    public var baseColorTexture: VRMTexture?
    public var normalTexture: VRMTexture?
    public var emissiveTexture: VRMTexture?
    public var metallicFactor: Float = 0.0
    public var roughnessFactor: Float = 1.0
    public var emissiveFactor: SIMD3<Float> = [0, 0, 0]
    public var doubleSided: Bool = false
    public var alphaMode: String = "OPAQUE"
    public var alphaCutoff: Float = 0.5

    // MToon properties
    public var mtoon: VRMMToonMaterial?

    // VRM spec version for version-aware shader behavior
    // VRM 0.0 uses smoothstep shading, VRM 1.0 uses linearstep
    public var vrmVersion: VRMSpecVersion = .v1_0

    // Render queue for sorting (VRM 0.x: Unity render queue values, higher = render later)
    // Default is 2000 (geometry), transparent materials typically 3000+
    public var renderQueue: Int = 2000

    // VRM transparent with depth write - transparent materials that still write to depth buffer
    // This is critical for proper layering of face materials (eyebrows, eyelashes over skin)
    public var transparentWithZWrite: Bool = false

    // Render queue offset from VRM extension (relative to category base)
    public var renderQueueOffset: Int = 0

    // Z-write enabled (for VRM 0.x compatibility)
    public var zWriteEnabled: Bool = true

    // Blend mode from VRM 0.x (0=Opaque, 1=Cutout, 2=Transparent, 3=TransparentWithZWrite)
    public var blendMode: Int = 0

    /// Computed property: Is this material transparent but should write to depth?
    /// Used for proper layering of overlapping transparent materials (e.g., eyebrows over face skin)
    public var isTransparentWithZWrite: Bool {
        // Explicit flag from VRM 1.0 extension
        if transparentWithZWrite {
            return true
        }
        // VRM 0.x: BlendMode 3 is explicitly TransparentWithZWrite
        if blendMode == 3 {
            return true
        }
        // VRM 0.x: Infer from properties - transparent material with zWrite enabled
        let isTransparent = alphaMode == "BLEND" || blendMode == 2
        return isTransparent && zWriteEnabled
    }

    public init(
        from gltfMaterial: GLTFMaterial, textures: [VRMTexture],
        vrm0MaterialProperty: VRM0MaterialProperty? = nil, vrmVersion: VRMSpecVersion = .v1_0
    ) {
        self.name = gltfMaterial.name
        self.vrmVersion = vrmVersion

        if let pbr = gltfMaterial.pbrMetallicRoughness {
            if let baseColor = pbr.baseColorFactor, baseColor.count == 4 {
                let unclamped = SIMD4<Float>(baseColor[0], baseColor[1], baseColor[2], baseColor[3])

                // Clamp to valid range [0.0, 1.0] per glTF 2.0 spec
                baseColorFactor = simd_clamp(
                    unclamped, SIMD4<Float>(repeating: 0.0), SIMD4<Float>(repeating: 1.0))
            }
            metallicFactor = pbr.metallicFactor ?? 0.0
            roughnessFactor = pbr.roughnessFactor ?? 1.0

            if let textureIndex = pbr.baseColorTexture?.index, textureIndex < textures.count {
                baseColorTexture = textures[textureIndex]
            }
        }

        // Load normal texture (provides surface detail like nose contours)
        if let normalTextureInfo = gltfMaterial.normalTexture,
            normalTextureInfo.index < textures.count {
            normalTexture = textures[normalTextureInfo.index]
        }

        // Load emissive texture (for glow effects)
        if let emissiveTextureInfo = gltfMaterial.emissiveTexture,
            emissiveTextureInfo.index < textures.count {
            emissiveTexture = textures[emissiveTextureInfo.index]
        }

        if let emissive = gltfMaterial.emissiveFactor, emissive.count == 3 {
            emissiveFactor = SIMD3<Float>(emissive[0], emissive[1], emissive[2])
        }

        doubleSided = gltfMaterial.doubleSided ?? false
        alphaMode = gltfMaterial.alphaMode ?? "OPAQUE"
        alphaCutoff = gltfMaterial.alphaCutoff ?? 0.5

        // Parse MToon extension if present
        // VRM 1.0: per-material VRMC_materials_mtoon extension
        if let extensions = gltfMaterial.extensions,
            let mtoonExt = extensions["VRMC_materials_mtoon"] as? [String: Any] {
            mtoon = parseMToonExtension(mtoonExt, textures: textures)

            // VRM 1.0: explicit transparentWithZWrite flag
            if let twzw = mtoonExt["transparentWithZWrite"] as? Bool {
                transparentWithZWrite = twzw
            }
            // VRM 1.0: renderQueueOffsetNumber for sorting within category
            // Compute final renderQueue from base + offset per VRM 1.0 spec
            if let rqOffset = mtoonExt["renderQueueOffsetNumber"] as? Int {
                renderQueueOffset = rqOffset

                // VRM 1.0 base render queue values per alpha mode
                let base: Int
                switch alphaMode.uppercased() {
                case "OPAQUE":
                    base = 2000
                case "MASK":
                    base = 2450
                case "BLEND":
                    base = 3000
                default:
                    base = 2000
                }
                renderQueue = base + rqOffset
            }
        }
        // VRM 0.x: material properties from document-level VRM extension
        else if let vrm0Prop = vrm0MaterialProperty {
            mtoon = vrm0Prop.toMToonMaterial()

            // Also get base color from VRM 0.x _Color vector property if present (sRGB to Linear)
            if let colorVec = vrm0Prop.vectorProperties["_Color"], colorVec.count >= 4 {
                // Convert RGB from sRGB to linear, alpha stays linear
                let r = sRGBToLinear(colorVec[0])
                let g = sRGBToLinear(colorVec[1])
                let b = sRGBToLinear(colorVec[2])
                let a = colorVec[3]  // Alpha stays linear
                baseColorFactor = SIMD4<Float>(r, g, b, a)
            }

            // Get renderQueue from VRM 0.x material (used for sorting transparent materials)
            if let queue = vrm0Prop.renderQueue {
                renderQueue = queue
            }

            // VRM 0.x: Read _ZWrite and _BlendMode from floatProperties
            // _ZWrite: 1 = writes to depth, 0 = no depth write
            if let zWrite = vrm0Prop.floatProperties["_ZWrite"] {
                zWriteEnabled = (zWrite == 1.0)
            }
            // _BlendMode: 0=Opaque, 1=Cutout, 2=Transparent, 3=TransparentWithZWrite
            if let bm = vrm0Prop.floatProperties["_BlendMode"] {
                blendMode = Int(bm)
            }
        }
    }

    /// Helper to convert sRGB color value to linear (gamma decoding)
    private func sRGBToLinear(_ value: Float) -> Float {
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private func parseMToonExtension(_ mtoonExt: [String: Any], textures: [VRMTexture])
        -> VRMMToonMaterial {
        var mtoon = VRMMToonMaterial()

        // Shade color factor
        if let shadeColorFactor = mtoonExt["shadeColorFactor"] as? [Double],
            shadeColorFactor.count >= 3 {
            mtoon.shadeColorFactor = SIMD3<Float>(
                Float(shadeColorFactor[0]),
                Float(shadeColorFactor[1]),
                Float(shadeColorFactor[2]))
        }

        // Shading properties
        if let shadingToonyFactor = mtoonExt["shadingToonyFactor"] as? Double {
            mtoon.shadingToonyFactor = Float(shadingToonyFactor)
        }
        if let shadingShiftFactor = mtoonExt["shadingShiftFactor"] as? Double {
            mtoon.shadingShiftFactor = Float(shadingShiftFactor)
        }

        // Global illumination
        if let giIntensityFactor = mtoonExt["giIntensityFactor"] as? Double {
            mtoon.giIntensityFactor = Float(giIntensityFactor)
        }

        // MatCap properties
        if let matcapFactor = mtoonExt["matcapFactor"] as? [Double], matcapFactor.count >= 3 {
            mtoon.matcapFactor = SIMD3<Float>(
                Float(matcapFactor[0]),
                Float(matcapFactor[1]),
                Float(matcapFactor[2]))
        }

        // Parametric rim lighting
        if let parametricRimColorFactor = mtoonExt["parametricRimColorFactor"] as? [Double],
            parametricRimColorFactor.count >= 3 {
            mtoon.parametricRimColorFactor = SIMD3<Float>(
                Float(parametricRimColorFactor[0]),
                Float(parametricRimColorFactor[1]),
                Float(parametricRimColorFactor[2]))
        }
        if let parametricRimFresnelPowerFactor = mtoonExt["parametricRimFresnelPowerFactor"]
            as? Double {
            mtoon.parametricRimFresnelPowerFactor = Float(parametricRimFresnelPowerFactor)
        }
        if let parametricRimLiftFactor = mtoonExt["parametricRimLiftFactor"] as? Double {
            mtoon.parametricRimLiftFactor = Float(parametricRimLiftFactor)
        }
        if let rimLightingMixFactor = mtoonExt["rimLightingMixFactor"] as? Double {
            mtoon.rimLightingMixFactor = Float(rimLightingMixFactor)
        }

        // Outline properties
        if let outlineWidthMode = mtoonExt["outlineWidthMode"] as? String {
            mtoon.outlineWidthMode = VRMOutlineWidthMode(rawValue: outlineWidthMode) ?? .none
        }
        if let outlineWidthFactor = mtoonExt["outlineWidthFactor"] as? Double {
            mtoon.outlineWidthFactor = Float(outlineWidthFactor)
        }
        if let outlineColorFactor = mtoonExt["outlineColorFactor"] as? [Double],
            outlineColorFactor.count >= 3 {
            mtoon.outlineColorFactor = SIMD3<Float>(
                Float(outlineColorFactor[0]),
                Float(outlineColorFactor[1]),
                Float(outlineColorFactor[2]))
        }
        if let outlineLightingMixFactor = mtoonExt["outlineLightingMixFactor"] as? Double {
            mtoon.outlineLightingMixFactor = Float(outlineLightingMixFactor)
        }

        // UV Animation properties
        if let uvAnimationScrollXSpeedFactor = mtoonExt["uvAnimationScrollXSpeedFactor"] as? Double {
            mtoon.uvAnimationScrollXSpeedFactor = Float(uvAnimationScrollXSpeedFactor)
        }
        if let uvAnimationScrollYSpeedFactor = mtoonExt["uvAnimationScrollYSpeedFactor"] as? Double {
            mtoon.uvAnimationScrollYSpeedFactor = Float(uvAnimationScrollYSpeedFactor)
        }
        if let uvAnimationRotationSpeedFactor = mtoonExt["uvAnimationRotationSpeedFactor"]
            as? Double {
            mtoon.uvAnimationRotationSpeedFactor = Float(uvAnimationRotationSpeedFactor)
        }

        // Texture references
        if let shadeMultiplyTexture = mtoonExt["shadeMultiplyTexture"] as? [String: Any],
            let index = shadeMultiplyTexture["index"] as? Int {
            mtoon.shadeMultiplyTexture = index
        }

        // Shading shift texture with scale support
        if let shadingShiftTexture = mtoonExt["shadingShiftTexture"] as? [String: Any],
            let index = shadingShiftTexture["index"] as? Int {
            let texCoord = shadingShiftTexture["texCoord"] as? Int
            let scale = shadingShiftTexture["scale"] as? Double
            mtoon.shadingShiftTexture = VRMShadingShiftTexture(
                index: index,
                texCoord: texCoord,
                scale: scale.map(Float.init)
            )
        }

        // MatCap texture
        if let matcapTexture = mtoonExt["matcapTexture"] as? [String: Any],
            let index = matcapTexture["index"] as? Int {
            mtoon.matcapTexture = index
        }

        // Rim multiply texture
        if let rimMultiplyTexture = mtoonExt["rimMultiplyTexture"] as? [String: Any],
            let index = rimMultiplyTexture["index"] as? Int {
            mtoon.rimMultiplyTexture = index
        }

        // Outline width multiply texture
        if let outlineWidthMultiplyTexture = mtoonExt["outlineWidthMultiplyTexture"]
            as? [String: Any],
            let index = outlineWidthMultiplyTexture["index"] as? Int {
            mtoon.outlineWidthMultiplyTexture = index
        }

        // UV animation mask texture
        if let uvAnimationMaskTexture = mtoonExt["uvAnimationMaskTexture"] as? [String: Any],
            let index = uvAnimationMaskTexture["index"] as? Int {
            mtoon.uvAnimationMaskTexture = index
        }

        return mtoon
    }
}
