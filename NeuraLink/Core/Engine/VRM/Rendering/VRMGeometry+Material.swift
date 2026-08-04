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
    /// Normal-map strength: glTF `normalTexture.scale`, overridden by the
    /// VRM 0.x `_BumpScale` when present.
    public var normalScale: Float = 1.0
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
        // VRM 0.x only: transparent material whose _ZWrite stayed on.
        // Gated to 0.x — `zWriteEnabled` defaults true, so without the gate
        // every VRM 1.0 BLEND material lacking the explicit flag would flip
        // to depth-write, changing how existing 1.0 models render.
        guard vrmVersion == .v0_0 else { return false }
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
            normalScale = normalTextureInfo.scale ?? 1.0
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
        // VRM 0.x: material properties from document-level VRM extension.
        // These are the AUTHORITATIVE material state for 0.x — the glTF
        // block is only a courtesy duplicate that some exporters (VRoid 2.x)
        // fill in and others leave at defaults. Trusting glTF alone renders
        // cutout/transparent/double-sided outfits opaque and single-sided.
        else if let vrm0Prop = vrm0MaterialProperty {
            // Spec: "If VRM_USE_GLTFSHADER is specified, use same index of
            // gltf's material settings" — the materialProperties entry is a
            // placeholder and must not override anything.
            let shaderName = vrm0Prop.shader ?? "VRM/MToon"
            if shaderName == "VRM_USE_GLTFSHADER" {
                nlLog(
                    "[VRM0Material] '\(name ?? "unnamed")' uses VRM_USE_GLTFSHADER — glTF settings as-is (alphaMode=\(alphaMode))",
                    level: .info)
                return
            }

            // Non-MToon shaders (VRM/Unlit*, Standard) must NOT get toon
            // shading — mirrors how VRM 1.0 materials without
            // VRMC_materials_mtoon take the unshaded branch. A missing
            // shader string is treated as MToon (pre-spec exports).
            let isMToonShader = shaderName == "VRM/MToon"
            if isMToonShader {
                mtoon = vrm0Prop.toMToonMaterial()
            }

            // Also get base color from VRM 0.x _Color vector property if present (sRGB to Linear)
            // (applies to MToon and Unlit alike — both use _Color/_MainTex)
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

            // Alpha mode. MToon: from _BlendMode
            // (0=Opaque, 1=Cutout, 2=Transparent, 3=TransparentWithZWrite).
            // Unlit shaders: implied by the shader name.
            if isMToonShader {
                if let bm = vrm0Prop.floatProperties["_BlendMode"] {
                    blendMode = Int(bm)
                    switch blendMode {
                    case 0: alphaMode = "OPAQUE"
                    case 1: alphaMode = "MASK"
                    case 2, 3: alphaMode = "BLEND"
                    default: break  // unknown value — keep the glTF block's answer
                    }
                }
            } else {
                // Keep blendMode in sync — the _ZWrite default below infers
                // "plain transparent ⇒ no depth write" from blendMode == 2.
                switch shaderName {
                case "VRM/UnlitCutout":
                    alphaMode = "MASK"
                    blendMode = 1
                case "VRM/UnlitTransparent":
                    alphaMode = "BLEND"
                    blendMode = 2
                case "VRM/UnlitTransparentZWrite":
                    alphaMode = "BLEND"
                    blendMode = 3
                default: break  // UnlitTexture / Standard: keep glTF (OPAQUE default)
                }
            }

            // Cutout threshold for MASK mode.
            if let cutoff = vrm0Prop.floatProperties["_Cutoff"] {
                alphaCutoff = cutoff
            }

            // _CullMode: 0=Off (double-sided), 1=Front, 2=Back. Front culling
            // has no engine support — treat it as single-sided like Back.
            if let cull = vrm0Prop.floatProperties["_CullMode"] {
                doubleSided = (cull == 0)
            }

            // Normal-map strength.
            if let bumpScale = vrm0Prop.floatProperties["_BumpScale"] {
                normalScale = bumpScale
            }

            // _ZWrite: 1 = writes to depth, 0 = no depth write. When absent,
            // mirror Unity MToon's BlendMode setter: ZWrite off for plain
            // Transparent, on for everything else.
            if let zWrite = vrm0Prop.floatProperties["_ZWrite"] {
                zWriteEnabled = (zWrite == 1.0)
            } else {
                zWriteEnabled = (blendMode != 2)
            }

            nlLog(
                "[VRM0Material] '\(name ?? "unnamed")' shader=\(shaderName) blendMode=\(blendMode) → \(alphaMode) cutoff=\(alphaCutoff) doubleSided=\(doubleSided) zWrite=\(zWriteEnabled) queue=\(renderQueue) mtoon=\(mtoon != nil)",
                level: .info)
        }
        // VRM 0.x material with no properties entry at all — worth knowing
        // when debugging why a material renders as plain PBR.
        else if vrmVersion == .v0_0 {
            nlLog(
                "[VRM0Material] '\(name ?? "unnamed")' has no materialProperties entry — glTF block only (alphaMode=\(alphaMode))",
                level: .warning)
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

        // Global illumination. Real VRM 1.0 files carry giEqualizationFactor
        // (spec name) — giIntensityFactor was the pre-release name, kept as a
        // fallback. The engine's ambient term uses intensity semantics; the
        // documented relation is giEqualizationFactor = 1 − giIntensityFactor.
        // Without this mapping every 1.0 material silently fell to the 0.05
        // struct default while the 0.x path honored _IndirectLightIntensity —
        // a visible ambient mismatch between the two spec paths.
        if let giEqualization = mtoonExt["giEqualizationFactor"] as? Double {
            mtoon.giIntensityFactor = Float(1.0 - giEqualization)
        } else if let giIntensityFactor = mtoonExt["giIntensityFactor"] as? Double {
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
