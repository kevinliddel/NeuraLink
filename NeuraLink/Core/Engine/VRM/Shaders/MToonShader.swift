//
//  MToonShader.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import Foundation
import Metal
import simd

// MARK: - MToonMaterialUniforms

// MToon material properties for rendering - exactly matches Metal struct layout
public struct MToonMaterialUniforms {
    // Block 0: 16 bytes - Base material properties
    public var baseColorFactor: SIMD4<Float> = [1, 1, 1, 1]  // 16 bytes

    // Block 1: 16 bytes - Shade and basic factors (packed float3 + float)
    public var shadeColorR: Float = 0.9
    public var shadeColorG: Float = 0.9
    public var shadeColorB: Float = 0.9
    public var shadingToonyFactor: Float = 0.9

    // Block 2: 16 bytes - Material factors (float + packed float3)
    public var shadingShiftFactor: Float = 0.0
    public var emissiveR: Float = 0.0
    public var emissiveG: Float = 0.0
    public var emissiveB: Float = 0.0

    // Block 3: 16 bytes - PBR factors
    public var metallicFactor: Float = 0.0
    public var roughnessFactor: Float = 1.0
    public var giIntensityFactor: Float = 1.0  // spec default is 1.0
    public var shadingShiftTextureScale: Float = 1.0

    // Block 4: 16 bytes - MatCap properties (packed float3 + int)
    public var matcapR: Float = 1.0
    public var matcapG: Float = 1.0
    public var matcapB: Float = 1.0
    public var hasMatcapTexture: Int32 = 0

    // Block 5: 16 bytes - Rim lighting part 1 (packed float3 + float)
    public var rimColorR: Float = 0.0
    public var rimColorG: Float = 0.0
    public var rimColorB: Float = 0.0
    public var parametricRimFresnelPowerFactor: Float = 5.0  // Higher = narrower rim edge

    // Block 6: 16 bytes - Rim lighting part 2
    public var parametricRimLiftFactor: Float = 0.0
    public var rimLightingMixFactor: Float = 0.0
    public var hasRimMultiplyTexture: Int32 = 0
    private var _padding1: Float = 0.0

    // Block 7: 16 bytes - Outline properties part 1 (float + packed float3)
    public var outlineWidthFactor: Float = 0.0
    public var outlineColorR: Float = 1.0
    public var outlineColorG: Float = 1.0
    public var outlineColorB: Float = 1.0

    // Block 8: 16 bytes - Outline properties part 2
    public var outlineLightingMixFactor: Float = 1.0
    public var outlineMode: Float = 0.0
    public var hasOutlineWidthMultiplyTexture: Int32 = 0
    private var _padding2: Float = 0.0

    // Block 9: 16 bytes - UV Animation
    public var uvAnimationScrollXSpeedFactor: Float = 0.0
    public var uvAnimationScrollYSpeedFactor: Float = 0.0
    public var uvAnimationRotationSpeedFactor: Float = 0.0
    public var time: Float = 0.0

    // Block 10: 16 bytes - Texture flags
    public var hasUvAnimationMaskTexture: Int32 = 0
    public var hasBaseColorTexture: Int32 = 0
    public var hasShadeMultiplyTexture: Int32 = 0
    public var hasShadingShiftTexture: Int32 = 0

    // Block 11: 16 bytes - More texture flags
    public var hasNormalTexture: Int32 = 0
    public var hasEmissiveTexture: Int32 = 0
    public var alphaMode: UInt32 = 0
    public var alphaCutoff: Float = 0.5

    // Block 12: 16 bytes - Version flag and UV offset
    public var vrmVersion: UInt32 = 1  // Default to VRM 1.0
    public var uvOffsetX: Float = 0.0  // UV offset for texture remapping (e.g., face overlays)
    public var uvOffsetY: Float = 0.0  // UV offset for texture remapping
    public var uvScale: Float = 1.0  // UV scale for texture remapping

    public init() {}

    // Computed properties for convenient SIMD3 access
    public var shadeColorFactor: SIMD3<Float> {
        get { SIMD3<Float>(shadeColorR, shadeColorG, shadeColorB) }
        set {
            shadeColorR = newValue.x
            shadeColorG = newValue.y
            shadeColorB = newValue.z
        }
    }

    public var emissiveFactor: SIMD3<Float> {
        get { SIMD3<Float>(emissiveR, emissiveG, emissiveB) }
        set {
            emissiveR = newValue.x
            emissiveG = newValue.y
            emissiveB = newValue.z
        }
    }

    public var matcapFactor: SIMD3<Float> {
        get { SIMD3<Float>(matcapR, matcapG, matcapB) }
        set {
            matcapR = newValue.x
            matcapG = newValue.y
            matcapB = newValue.z
        }
    }

    public var parametricRimColorFactor: SIMD3<Float> {
        get { SIMD3<Float>(rimColorR, rimColorG, rimColorB) }
        set {
            rimColorR = newValue.x
            rimColorG = newValue.y
            rimColorB = newValue.z
        }
    }

    public var outlineColorFactor: SIMD3<Float> {
        get { SIMD3<Float>(outlineColorR, outlineColorG, outlineColorB) }
        set {
            outlineColorR = newValue.x
            outlineColorG = newValue.y
            outlineColorB = newValue.z
        }
    }

    // Helper to create from VRMMToonMaterial
    public init(from mtoon: VRMMToonMaterial, time: Float = 0.0) {
        self.shadeColorFactor = mtoon.shadeColorFactor
        self.shadingToonyFactor = mtoon.shadingToonyFactor
        self.shadingShiftFactor = mtoon.shadingShiftFactor
        self.giIntensityFactor = mtoon.giIntensityFactor
        self.shadingShiftTextureScale = mtoon.shadingShiftTexture?.scale ?? 1.0

        self.matcapFactor = mtoon.matcapFactor
        self.hasMatcapTexture = mtoon.matcapTexture != nil ? 1 : 0

        self.parametricRimColorFactor = mtoon.parametricRimColorFactor
        self.parametricRimFresnelPowerFactor = mtoon.parametricRimFresnelPowerFactor
        self.parametricRimLiftFactor = mtoon.parametricRimLiftFactor
        self.rimLightingMixFactor = mtoon.rimLightingMixFactor
        self.hasRimMultiplyTexture = mtoon.rimMultiplyTexture != nil ? 1 : 0

        self.outlineWidthFactor = mtoon.outlineWidthFactor
        self.outlineColorFactor = mtoon.outlineColorFactor
        self.outlineLightingMixFactor = mtoon.outlineLightingMixFactor
        switch mtoon.outlineWidthMode {
        case .none:
            self.outlineMode = 0.0
        case .worldCoordinates:
            self.outlineMode = 1.0
        case .screenCoordinates:
            self.outlineMode = 2.0
        }
        self.hasOutlineWidthMultiplyTexture = mtoon.outlineWidthMultiplyTexture != nil ? 1 : 0

        self.uvAnimationScrollXSpeedFactor = mtoon.uvAnimationScrollXSpeedFactor
        self.uvAnimationScrollYSpeedFactor = mtoon.uvAnimationScrollYSpeedFactor
        self.uvAnimationRotationSpeedFactor = mtoon.uvAnimationRotationSpeedFactor
        self.time = time
        self.hasUvAnimationMaskTexture = mtoon.uvAnimationMaskTexture != nil ? 1 : 0

        self.hasShadeMultiplyTexture = mtoon.shadeMultiplyTexture != nil ? 1 : 0
        self.hasShadingShiftTexture = mtoon.shadingShiftTexture != nil ? 1 : 0
    }

    // Validation function to check for correctness
    public func validate() throws {
        // Validate outline mode
        guard outlineMode == 0 || outlineMode == 1 || outlineMode == 2 else {
            throw VRMMaterialValidationError.invalidOutlineMode(Int(outlineMode))
        }

        // Validate matcap factor
        guard all(matcapFactor .>= 0) && all(matcapFactor .<= 4) else {
            throw VRMMaterialValidationError.matcapFactorOutOfRange(SIMD4<Float>(matcapFactor, 1.0))
        }

        // Validate rim fresnel power
        guard parametricRimFresnelPowerFactor >= 0 else {
            throw VRMMaterialValidationError.rimFresnelPowerNegative(
                parametricRimFresnelPowerFactor)
        }

        // Validate rim lighting mix
        guard rimLightingMixFactor >= 0 && rimLightingMixFactor <= 1 else {
            throw VRMMaterialValidationError.rimLightingMixOutOfRange(rimLightingMixFactor)
        }

        // Validate outline lighting mix
        guard outlineLightingMixFactor >= 0 && outlineLightingMixFactor <= 1 else {
            throw VRMMaterialValidationError.outlineLightingMixOutOfRange(outlineLightingMixFactor)
        }

        // Validate GI intensity
        guard giIntensityFactor >= 0 && giIntensityFactor <= 1 else {
            throw VRMMaterialValidationError.giIntensityOutOfRange(giIntensityFactor)
        }

        // Validate shading toony factor
        guard shadingToonyFactor >= 0 && shadingToonyFactor <= 1 else {
            throw VRMMaterialValidationError.shadingToonyOutOfRange(shadingToonyFactor)
        }

        // Validate shading shift factor
        guard shadingShiftFactor >= -1 && shadingShiftFactor <= 1 else {
            throw VRMMaterialValidationError.shadingShiftOutOfRange(shadingShiftFactor)
        }

        #if DEBUG
            // Additional debug checks
            let epsilon: Float = 0.001
            if parametricRimLiftFactor < -epsilon || parametricRimLiftFactor > 1 + epsilon {
                vrmLog("Warning: Rim lift factor unusual value: \(parametricRimLiftFactor)")
            }
            if uvAnimationRotationSpeedFactor > 10 {
                vrmLog(
                    "Warning: Very high UV rotation speed: \(uvAnimationRotationSpeedFactor) rad/s")
            }
            if outlineWidthFactor > 0.1 {
                vrmLog("Warning: Very large outline width: \(outlineWidthFactor)")
            }
        #endif
    }

    // Debug description for shader debugging
    public var debugDescription: String {
        return """
            MToon Material Debug:
            - Outline Mode: \(outlineMode) (0=none, 1=world, 2=screen)
            - MatCap Factor: \(matcapFactor)
            - Rim Color: \(parametricRimColorFactor), Power: \(parametricRimFresnelPowerFactor), Lift: \(parametricRimLiftFactor)
            - Outline Width: \(outlineWidthFactor), Color: \(outlineColorFactor)
            - UV Animation: scroll(\(uvAnimationScrollXSpeedFactor), \(uvAnimationScrollYSpeedFactor)), rot(\(uvAnimationRotationSpeedFactor))
            - Textures: base(\(hasBaseColorTexture)), matcap(\(hasMatcapTexture)), rim(\(hasRimMultiplyTexture))
            """
    }
}

public enum MToonOutlineWidthMode: String {
    case none = "none"
    case worldCoordinates = "worldCoordinates"
    case screenCoordinates = "screenCoordinates"
}
