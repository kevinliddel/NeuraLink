//
// VRMTypes+Materials.swift
// NeuraLink
//
// Created by Dedicatus on 14/04/2026.
//

import Foundation
import simd

// MARK: - VRM 0.x Material Properties

/// VRM 0.x stores MToon properties in materialProperties array at document level
public struct VRM0MaterialProperty {
    public var name: String?
    public var shader: String?
    public var renderQueue: Int?

    // Float properties (Unity shader property names)
    public var floatProperties: [String: Float] = [:]

    // Vector properties (Unity shader property names)
    public var vectorProperties: [String: [Float]] = [:]

    // Texture properties (Unity shader property names -> texture index)
    public var textureProperties: [String: Int] = [:]

    // Keyword flags
    public var keywordMap: [String: Bool] = [:]
    public var tagMap: [String: String] = [:]

    public init() {}

    /// Helper to convert sRGB color value to linear (gamma decoding)
    private func sRGBToLinear(_ value: Float) -> Float {
        // Standard sRGB to linear conversion
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    /// Convert VRM 0.x material properties to VRM 1.0 MToon structure
    /// Based on three-vrm VRMMaterialsV0CompatPlugin transformations
    public func toMToonMaterial() -> VRMMToonMaterial {
        var mtoon = VRMMToonMaterial()

        // Shade color from _ShadeColor vector property (sRGB to Linear conversion)
        if let shadeColor = vectorProperties["_ShadeColor"], shadeColor.count >= 3 {
            mtoon.shadeColorFactor = SIMD3<Float>(
                sRGBToLinear(shadeColor[0]),
                sRGBToLinear(shadeColor[1]),
                sRGBToLinear(shadeColor[2])
            )
        } else {
            // VRM 1.0 spec defaults shadeColorFactor to white if unspecified
            mtoon.shadeColorFactor = SIMD3<Float>(1.0, 1.0, 1.0)
        }

        // VRM 0.x -> VRM 1.0 shading transformation (from three-vrm)
        // These properties are interdependent:
        // shadingToonyFactor = lerp(shadeToony, 1.0, 0.5 + 0.5 * shadeShift)
        // shadingShiftFactor = -shadeShift - (1.0 - shadingToonyFactor)
        let shadeToony = floatProperties["_ShadeToony"] ?? 0.9
        let shadeShift = floatProperties["_ShadeShift"] ?? 0.0

        // Apply the VRM 0.x -> 1.0 transformation
        let lerpFactor = 0.5 + 0.5 * shadeShift
        let shadingToonyFactor = shadeToony * (1.0 - lerpFactor) + 1.0 * lerpFactor
        let shadingShiftFactor = -shadeShift - (1.0 - shadingToonyFactor)

        mtoon.shadingToonyFactor = shadingToonyFactor
        mtoon.shadingShiftFactor = shadingShiftFactor

        // Shade texture from texture properties
        // In VRM 0.0, if _ShadeTexture is not defined, _MainTex is implicitly used for shadows.
        // We must bind it so the shader can multiply the shade color with the texture.
        if let shadeTexIndex = textureProperties["_ShadeTexture"] {
            mtoon.shadeMultiplyTexture = shadeTexIndex
        } else if let mainTexIndex = textureProperties["_MainTex"] {
            mtoon.shadeMultiplyTexture = mainTexIndex
        }

        // Global illumination: giEqualizationFactor = 1.0 - giIntensityFactor
        if let giIntensity = floatProperties["_IndirectLightIntensity"] {
            mtoon.giIntensityFactor = giIntensity
        }

        // Matcap/Sphere Add texture
        if let matcapIndex = textureProperties["_SphereAdd"] {
            mtoon.matcapTexture = matcapIndex
            mtoon.matcapFactor = SIMD3<Float>(1.0, 1.0, 1.0)  // White when texture exists
        }

        // Rim lighting (sRGB to Linear for color)
        if let rimColor = vectorProperties["_RimColor"], rimColor.count >= 3 {
            mtoon.parametricRimColorFactor = SIMD3<Float>(
                sRGBToLinear(rimColor[0]),
                sRGBToLinear(rimColor[1]),
                sRGBToLinear(rimColor[2])
            )
        }
        if let rimTexIndex = textureProperties["_RimTexture"] {
            mtoon.rimMultiplyTexture = rimTexIndex
        }
        if let rimPower = floatProperties["_RimFresnelPower"] {
            mtoon.parametricRimFresnelPowerFactor = rimPower
        }
        if let rimLift = floatProperties["_RimLift"] {
            mtoon.parametricRimLiftFactor = rimLift
        }
        if let rimMix = floatProperties["_RimLightingMix"] {
            mtoon.rimLightingMixFactor = rimMix
        }

        // Outline properties (width needs 0.01 multiplier for cm to normalized conversion)
        if let outlineWidth = floatProperties["_OutlineWidth"] {
            mtoon.outlineWidthFactor = outlineWidth * 0.01  // cm to normalized units
        }
        if let outlineTexIndex = textureProperties["_OutlineWidthTexture"] {
            mtoon.outlineWidthMultiplyTexture = outlineTexIndex
        }
        if let outlineMode = floatProperties["_OutlineWidthMode"] {
            switch Int(outlineMode) {
            case 1: mtoon.outlineWidthMode = .worldCoordinates
            case 2: mtoon.outlineWidthMode = .screenCoordinates
            default: mtoon.outlineWidthMode = .none
            }
        }
        if let outlineColor = vectorProperties["_OutlineColor"], outlineColor.count >= 3 {
            mtoon.outlineColorFactor = SIMD3<Float>(
                sRGBToLinear(outlineColor[0]),
                sRGBToLinear(outlineColor[1]),
                sRGBToLinear(outlineColor[2])
            )
        }
        // Outline lighting mix depends on color mode
        let outlineColorMode = floatProperties["_OutlineColorMode"] ?? 0.0
        if Int(outlineColorMode) == 1 {
            // Mixed mode: default to 1.0 if not specified
            mtoon.outlineLightingMixFactor = floatProperties["_OutlineLightingMix"] ?? 1.0
        } else {
            mtoon.outlineLightingMixFactor = floatProperties["_OutlineLightingMix"] ?? 0.0
        }

        // UV Animation (note: Y scroll is negated for V0->V1 conversion)
        if let uvMaskIndex = textureProperties["_UvAnimMaskTexture"] {
            mtoon.uvAnimationMaskTexture = uvMaskIndex
        }
        if let uvScrollX = floatProperties["_UvAnimScrollX"] {
            mtoon.uvAnimationScrollXSpeedFactor = uvScrollX
        }
        if let uvScrollY = floatProperties["_UvAnimScrollY"] {
            mtoon.uvAnimationScrollYSpeedFactor = -uvScrollY  // Negated for V0->V1
        }
        if let uvRotation = floatProperties["_UvAnimRotation"] {
            mtoon.uvAnimationRotationSpeedFactor = uvRotation
        }

        return mtoon
    }
}

// MARK: - MToon Material

public struct VRMMToonMaterial {
    public var shadeColorFactor: SIMD3<Float> = [1.0, 1.0, 1.0]
    public var shadeMultiplyTexture: Int?
    public var shadingShiftFactor: Float = 0.0
    public var shadingShiftTexture: VRMShadingShiftTexture?
    public var shadingToonyFactor: Float = 0.9
    public var giIntensityFactor: Float = 0.05
    public var matcapFactor: SIMD3<Float> = [1.0, 1.0, 1.0]  // White default for texture multiplication
    public var matcapTexture: Int?
    public var parametricRimColorFactor: SIMD3<Float> = [0.0, 0.0, 0.0]  // Rim should start disabled
    public var parametricRimFresnelPowerFactor: Float = 5.0  // Higher = narrower rim edge
    public var parametricRimLiftFactor: Float = 0.0
    public var rimMultiplyTexture: Int?
    public var rimLightingMixFactor: Float = 0.0
    public var outlineWidthMode: VRMOutlineWidthMode = .none
    public var outlineWidthFactor: Float = 0.0
    public var outlineWidthMultiplyTexture: Int?
    public var outlineColorFactor: SIMD3<Float> = [0.0, 0.0, 0.0]  // Black default (matches three-vrm)
    public var outlineLightingMixFactor: Float = 1.0
    public var uvAnimationMaskTexture: Int?
    public var uvAnimationScrollXSpeedFactor: Float = 0.0
    public var uvAnimationScrollYSpeedFactor: Float = 0.0
    public var uvAnimationRotationSpeedFactor: Float = 0.0

    public init() {}
}

public struct VRMShadingShiftTexture {
    public var index: Int
    public var texCoord: Int?
    public var scale: Float?

    public init(index: Int, texCoord: Int? = nil, scale: Float? = nil) {
        self.index = index
        self.texCoord = texCoord
        self.scale = scale
    }
}

public enum VRMOutlineWidthMode: String {
    case none
    case worldCoordinates
    case screenCoordinates
}
