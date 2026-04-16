//
// VRMRendererError.swift
// NeuraLink
//
// Created by Dedicatus on 14/04/2026.
//

import Foundation

// MARK: - Material Validation Errors

public enum VRMMaterialValidationError: LocalizedError {
    case invalidOutlineMode(Int)
    case matcapFactorOutOfRange(SIMD4<Float>)
    case rimFresnelPowerNegative(Float)
    case rimLightingMixOutOfRange(Float)
    case outlineLightingMixOutOfRange(Float)
    case giIntensityOutOfRange(Float)
    case shadingToonyOutOfRange(Float)
    case shadingShiftOutOfRange(Float)

    public var errorDescription: String? {
        switch self {
        case .invalidOutlineMode(let mode):
            return "Invalid outline mode \(mode) (expected 0=none, 1=world, 2=screen)"
        case .matcapFactorOutOfRange(let factor):
            return "Matcap factor \(factor) out of range [0.0, 4.0]"
        case .rimFresnelPowerNegative(let power):
            return "Rim fresnel power \(power) must be non-negative"
        case .rimLightingMixOutOfRange(let mix):
            return "Rim lighting mix \(mix) out of range [0.0, 1.0]"
        case .outlineLightingMixOutOfRange(let mix):
            return "Outline lighting mix \(mix) out of range [0.0, 1.0]"
        case .giIntensityOutOfRange(let intensity):
            return "GI intensity \(intensity) out of range [0.0, 1.0]"
        case .shadingToonyOutOfRange(let toony):
            return "Shading toony factor \(toony) out of range [0.0, 1.0]"
        case .shadingShiftOutOfRange(let shift):
            return "Shading shift factor \(shift) out of range [-1.0, 1.0]"
        }
    }
}
