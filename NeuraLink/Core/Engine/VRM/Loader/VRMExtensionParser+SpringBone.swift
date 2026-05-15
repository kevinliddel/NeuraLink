//
// VRMExtensionParser+SpringBone.swift
// NeuraLink
//
// Created by Dedicatus on 15/04/2026.
//

import Foundation
import simd

// MARK: - SpringBone Parsing

extension VRMExtensionParser {
    func parseSpringBone(_ dict: [String: Any]) throws -> VRMSpringBone {
        var springBone = VRMSpringBone()

        if let specVersion = dict["specVersion"] as? String {
            springBone.specVersion = specVersion
        }

        if let colliders = dict["colliders"] as? [[String: Any]] {
            for colliderDict in colliders {
                guard let node = colliderDict["node"] as? Int,
                    let shapeDict = colliderDict["shape"] as? [String: Any]
                else { continue }
                if let shape = parseColliderShape(shapeDict) {
                    springBone.colliders.append(VRMCollider(node: node, shape: shape))
                }
            }
        }

        if let colliderGroups = dict["colliderGroups"] as? [[String: Any]] {
            for groupDict in colliderGroups {
                var group = VRMColliderGroup()
                group.name = groupDict["name"] as? String
                group.colliders = groupDict["colliders"] as? [Int] ?? []
                springBone.colliderGroups.append(group)
            }
        }

        if let springs = dict["springs"] as? [[String: Any]] {
            for springDict in springs {
                var spring = VRMSpring(name: springDict["name"] as? String)
                spring.colliderGroups = springDict["colliderGroups"] as? [Int] ?? []
                spring.center = springDict["center"] as? Int

                if let joints = springDict["joints"] as? [[String: Any]] {
                    for jointDict in joints {
                        guard let node = jointDict["node"] as? Int else { continue }
                        var joint = VRMSpringJoint(node: node)
                        joint.hitRadius = jointDict["hitRadius"] as? Float ?? 0.0
                        joint.stiffness = jointDict["stiffness"] as? Float ?? 1.0
                        joint.gravityPower = jointDict["gravityPower"] as? Float ?? 0.0
                        joint.dragForce = jointDict["dragForce"] as? Float ?? 0.4
                        if let gravityDir = jointDict["gravityDir"] as? [Float],
                            gravityDir.count == 3 {
                            joint.gravityDir = SIMD3<Float>(
                                gravityDir[0], gravityDir[1], gravityDir[2])
                        }
                        spring.joints.append(joint)
                    }
                }

                springBone.springs.append(spring)
            }
        }

        return springBone
    }

    func parseColliderShape(_ dict: [String: Any]) -> VRMColliderShape? {
        if let sphereDict = dict["sphere"] as? [String: Any] {
            let offset = parseVector3(sphereDict["offset"]) ?? SIMD3<Float>(0, 0, 0)
            let radius = parseFloatValue(sphereDict["radius"]) ?? 0.0
            return .sphere(offset: offset, radius: radius)
        } else if let capsuleDict = dict["capsule"] as? [String: Any] {
            let offset = parseVector3(capsuleDict["offset"]) ?? SIMD3<Float>(0, 0, 0)
            let radius = parseFloatValue(capsuleDict["radius"]) ?? 0.0
            let tail = parseVector3(capsuleDict["tail"]) ?? SIMD3<Float>(0, 0, 0)
            return .capsule(offset: offset, radius: radius, tail: tail)
        }
        return nil
    }

    func parseFloatValue(_ value: Any?) -> Float? {
        if let floatVal = value as? Float { return floatVal }
        if let doubleVal = value as? Double { return Float(doubleVal) }
        if let numVal = value as? NSNumber { return numVal.floatValue }
        return nil
    }

    func parseVector3(_ value: Any?) -> SIMD3<Float>? {
        guard let array = value as? [Float], array.count == 3 else { return nil }
        return SIMD3<Float>(array[0], array[1], array[2])
    }
}
