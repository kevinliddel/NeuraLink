//
// VRMTypes+Expressions.swift
// NeuraLink
//
// Created by Dedicatus on 14/04/2026.
//

import Foundation
import simd

// MARK: - Expression Types

public enum VRMExpressionPreset: String, CaseIterable, Sendable {
    case happy
    case angry
    case sad
    case relaxed
    case surprised

    case aa
    case ih
    case ou
    case ee
    case oh

    case blink
    case blinkLeft
    case blinkRight
    case lookUp
    case lookDown
    case lookLeft
    case lookRight

    case neutral
    case custom  // VRM 1.0 spec: User-defined expressions not covered by standard presets
}

public struct VRMExpression {
    public var name: String?
    public var preset: VRMExpressionPreset?
    public var morphTargetBinds: [VRMMorphTargetBind] = []
    public var materialColorBinds: [VRMMaterialColorBind] = []
    public var textureTransformBinds: [VRMTextureTransformBind] = []
    public var isBinary: Bool = false
    public var overrideBlink: VRMExpressionOverrideType = .none
    public var overrideLookAt: VRMExpressionOverrideType = .none
    public var overrideMouth: VRMExpressionOverrideType = .none

    public init(name: String? = nil, preset: VRMExpressionPreset? = nil) {
        self.name = name
        self.preset = preset
    }
}

public struct VRMMorphTargetBind {
    public var node: Int
    public var index: Int
    public var weight: Float

    public init(node: Int, index: Int, weight: Float) {
        self.node = node
        self.index = index
        self.weight = weight
    }
}

public struct VRMMaterialColorBind {
    public var material: Int
    public var type: VRMMaterialColorType
    public var targetValue: SIMD4<Float>

    public init(material: Int, type: VRMMaterialColorType, targetValue: SIMD4<Float>) {
        self.material = material
        self.type = type
        self.targetValue = targetValue
    }
}

public enum VRMMaterialColorType: String {
    case color
    case emissionColor
    case shadeColor
    case matcapColor
    case rimColor
    case outlineColor
}

public struct VRMTextureTransformBind {
    public var material: Int
    public var scale: SIMD2<Float>?
    public var offset: SIMD2<Float>?

    public init(material: Int, scale: SIMD2<Float>? = nil, offset: SIMD2<Float>? = nil) {
        self.material = material
        self.scale = scale
        self.offset = offset
    }
}

public enum VRMExpressionOverrideType: String {
    case none
    case block
    case blend
}
