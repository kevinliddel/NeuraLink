//
// VRMExtensionParser+VRM0.swift
// NeuraLink
//
// Created by Dedicatus on 14/04/2026.
//

import Foundation
import simd

extension VRMExtensionParser {

    // MARK: - VRM 0.0 Secondary Animation Support

    func parseSecondaryAnimation(_ dict: [String: Any]) -> VRMSpringBone {
        var springBone = VRMSpringBone()
        springBone.specVersion = "0.0"  // Mark as VRM 0.0 format

        // VRM 0.0 uses boneGroups for spring chains
        if let boneGroups = dict["boneGroups"] as? [[String: Any]] {
            for groupDict in boneGroups {
                var spring = VRMSpring(name: groupDict["comment"] as? String)

                // Center bone
                if let center = groupDict["center"] as? Int {
                    spring.center = center
                }

                // Bones array becomes joints
                if let bones = groupDict["bones"] as? [Int] {
                    for boneIndex in bones {
                        var joint = VRMSpringJoint(node: boneIndex)

                        // VRM 0.0 physics parameters - handle both correct and typo versions
                        // JSON numbers may come as Double or NSNumber, so try multiple casts
                        if let stiffFloat = groupDict["stiffness"] as? Float {
                            joint.stiffness = stiffFloat
                        } else if let stiffDouble = groupDict["stiffness"] as? Double {
                            joint.stiffness = Float(stiffDouble)
                        } else if let stiffNum = groupDict["stiffness"] as? NSNumber {
                            joint.stiffness = stiffNum.floatValue
                        } else if let stiffFloat = groupDict["stiffiness"] as? Float {  // Legacy typo
                            joint.stiffness = stiffFloat
                        } else if let stiffDouble = groupDict["stiffiness"] as? Double {
                            joint.stiffness = Float(stiffDouble)
                        } else {
                            joint.stiffness = 1.0  // Default only if not found at all
                        }

                        // Apply minimum gravityPower of 1.0 when model specifies 0
                        // Many VRM 0.x models have gravityPower=0 but expect gravity to work
                        let rawGravityPower: Float
                        if let gpFloat = groupDict["gravityPower"] as? Float {
                            rawGravityPower = gpFloat
                        } else if let gpDouble = groupDict["gravityPower"] as? Double {
                            rawGravityPower = Float(gpDouble)
                        } else if let gpNum = groupDict["gravityPower"] as? NSNumber {
                            rawGravityPower = gpNum.floatValue
                        } else {
                            rawGravityPower = 0.0
                        }
                        joint.gravityPower = rawGravityPower > 0 ? rawGravityPower : 1.0

                        if let dragFloat = groupDict["dragForce"] as? Float {
                            joint.dragForce = dragFloat
                        } else if let dragDouble = groupDict["dragForce"] as? Double {
                            joint.dragForce = Float(dragDouble)
                        } else if let dragNum = groupDict["dragForce"] as? NSNumber {
                            joint.dragForce = dragNum.floatValue
                        } else {
                            joint.dragForce = 0.4
                        }

                        if let hitFloat = groupDict["hitRadius"] as? Float {
                            joint.hitRadius = hitFloat
                        } else if let hitDouble = groupDict["hitRadius"] as? Double {
                            joint.hitRadius = Float(hitDouble)
                        } else if let hitNum = groupDict["hitRadius"] as? NSNumber {
                            joint.hitRadius = hitNum.floatValue
                        } else {
                            joint.hitRadius = 0.0
                        }

                        // Gravity direction
                        if let gravityDir = groupDict["gravityDir"] as? [String: Any] {
                            let x = gravityDir["x"] as? Float ?? 0
                            let y = gravityDir["y"] as? Float ?? -1
                            let z = gravityDir["z"] as? Float ?? 0
                            joint.gravityDir = SIMD3<Float>(x, y, z)
                        }

                        spring.joints.append(joint)
                    }
                }

                // Collider groups (VRM 0.0 uses indices directly)
                if let colliderGroups = groupDict["colliderGroups"] as? [Int] {
                    spring.colliderGroups = colliderGroups
                }

                springBone.springs.append(spring)
            }
        }

        // VRM 0.0 collider groups
        if let colliderGroups = dict["colliderGroups"] as? [[String: Any]] {
            for (index, groupDict) in colliderGroups.enumerated() {
                var group = VRMColliderGroup(name: "colliderGroup_\(index)")

                // VRM 0.0 stores colliders inline in each group
                if let colliders = groupDict["colliders"] as? [[String: Any]] {
                    for colliderDict in colliders {
                        // Note: VRM 0.0 stores node at group level, not collider level
                        let node: Int
                        if let groupNode = groupDict["node"] as? Int {
                            node = groupNode
                        } else if let colliderNode = colliderDict["node"] as? Int {
                            node = colliderNode
                        } else {
                            continue
                        }

                        // VRM 0.0 collider format
                        let offset =
                            parseVRM0Vector3(colliderDict["offset"]) ?? SIMD3<Float>(0, 0, 0)
                        let radius = parseFloatValue(colliderDict["radius"]) ?? 0.0

                        // VRM 0.0 only supports spheres in most implementations
                        let shape = VRMColliderShape.sphere(offset: offset, radius: radius)
                        let collider = VRMCollider(node: node, shape: shape)

                        // Add to global colliders list
                        let colliderIndex = springBone.colliders.count
                        springBone.colliders.append(collider)
                        group.colliders.append(colliderIndex)
                    }
                }

                springBone.colliderGroups.append(group)
            }
        }

        return springBone
    }

    func parseVRM0Vector3(_ value: Any?) -> SIMD3<Float>? {
        if let dict = value as? [String: Any] {
            let x = dict["x"] as? Float ?? 0
            let y = dict["y"] as? Float ?? 0
            let z = dict["z"] as? Float ?? 0
            return SIMD3<Float>(x, y, z)
        }
        return nil
    }
}
