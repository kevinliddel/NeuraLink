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
                guard let node = colliderDict["node"] as? Int else { continue }
                // VRMC_springBone_extended_collider replaces the shape when
                // present (the plain one is its fallback for other readers).
                let extended = ((colliderDict["extensions"] as? [String: Any])?[
                    "VRMC_springBone_extended_collider"] as? [String: Any])?["shape"] as? [String: Any]
                if let shape = extended.flatMap(parseExtendedColliderShape)
                    ?? (colliderDict["shape"] as? [String: Any]).flatMap(parseColliderShape) {
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
                        // parseFloatValue, not `as? Float`: that cast is nil for
                        // any JSON decimal a Float can't hold exactly (0.85),
                        // which reset every such joint to the defaults.
                        joint.hitRadius = parseFloatValue(jointDict["hitRadius"]) ?? 0.0
                        joint.stiffness = parseFloatValue(jointDict["stiffness"]) ?? 1.0
                        joint.gravityPower = parseFloatValue(jointDict["gravityPower"]) ?? 0.0
                        joint.dragForce = parseFloatValue(jointDict["dragForce"]) ?? 0.4
                        if let gravityDir = parseVector3(jointDict["gravityDir"]) {
                            joint.gravityDir = gravityDir
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

    /// VRMC_springBone_extended_collider shapes: sphere / capsule with
    /// `inside`, and plane.
    func parseExtendedColliderShape(_ dict: [String: Any]) -> VRMColliderShape? {
        if let sphere = dict["sphere"] as? [String: Any] {
            let offset = parseVector3(sphere["offset"]) ?? .zero
            let radius = parseFloatValue(sphere["radius"]) ?? 0
            return (sphere["inside"] as? Bool ?? false)
                ? .insideSphere(offset: offset, radius: radius) : .sphere(offset: offset, radius: radius)
        }
        if let capsule = dict["capsule"] as? [String: Any] {
            let offset = parseVector3(capsule["offset"]) ?? .zero
            let radius = parseFloatValue(capsule["radius"]) ?? 0
            let tail = parseVector3(capsule["tail"]) ?? .zero
            return (capsule["inside"] as? Bool ?? false)
                ? .insideCapsule(offset: offset, radius: radius, tail: tail)
                : .capsule(offset: offset, radius: radius, tail: tail)
        }
        if let plane = dict["plane"] as? [String: Any] {
            return .plane(offset: parseVector3(plane["offset"]) ?? .zero,
                          normal: parseVector3(plane["normal"]) ?? SIMD3<Float>(0, 0, 1))
        }
        return nil
    }

    func parseFloatValue(_ value: Any?) -> Float? {
        if let floatVal = value as? Float { return floatVal }
        if let doubleVal = value as? Double { return Float(doubleVal) }
        if let numVal = value as? NSNumber { return numVal.floatValue }
        return nil
    }

    /// Each element through parseFloatValue (see the joint parse above).
    func parseFloatArray(_ value: Any?) -> [Float]? {
        guard let array = value as? [Any] else { return nil }
        let floats = array.compactMap { parseFloatValue($0) }
        return floats.count == array.count ? floats : nil
    }

    func parseVector3(_ value: Any?) -> SIMD3<Float>? {
        guard let array = parseFloatArray(value), array.count == 3 else { return nil }
        return SIMD3<Float>(array[0], array[1], array[2])
    }
}
