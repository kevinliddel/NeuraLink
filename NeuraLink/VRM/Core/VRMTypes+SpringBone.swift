//
// VRMTypes+SpringBone.swift
// NeuraLink
//
// Created by Dedicatus on 14/04/2026.
//

import Foundation
import simd

// MARK: - SpringBone Types

public struct VRMSpringBone {
    public var specVersion: String = "1.0"
    public var colliders: [VRMCollider] = []
    public var colliderGroups: [VRMColliderGroup] = []
    public var springs: [VRMSpring] = []

    public init() {}
}

public struct VRMCollider {
    public var node: Int
    public var shape: VRMColliderShape

    public init(node: Int, shape: VRMColliderShape) {
        self.node = node
        self.shape = shape
    }
}

public enum VRMColliderShape {
    case sphere(offset: SIMD3<Float>, radius: Float)
    case capsule(offset: SIMD3<Float>, radius: Float, tail: SIMD3<Float>)
    case plane(offset: SIMD3<Float>, normal: SIMD3<Float>)
}

public struct VRMColliderGroup {
    public var name: String?
    public var colliders: [Int] = []

    public init(name: String? = nil, colliders: [Int] = []) {
        self.name = name
        self.colliders = colliders
    }
}

public struct VRMSpring {
    public var name: String?
    public var joints: [VRMSpringJoint] = []
    public var colliderGroups: [Int] = []
    public var center: Int?

    public init(name: String? = nil) {
        self.name = name
    }
}

public struct VRMSpringJoint {
    public var node: Int
    public var hitRadius: Float = 0.0
    public var stiffness: Float = 1.0
    public var gravityPower: Float = 0.0
    public var gravityDir: SIMD3<Float> = [0, -1, 0]
    public var dragForce: Float = 0.4

    public init(node: Int) {
        self.node = node
    }
}
