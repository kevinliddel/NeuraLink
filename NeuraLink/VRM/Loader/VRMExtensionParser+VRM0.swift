//
// VRMExtensionParser+VRM0.swift
// NeuraLink
//
// Created by Dedicatus on 14/04/2026.
//

import Foundation
import simd

extension VRMExtensionParser {

    // MARK: - VRM 0.x Secondary Animation

    func parseSecondaryAnimation(
        _ dict: [String: Any], document: GLTFDocument
    ) -> VRMSpringBone {
        var springBone = VRMSpringBone()
        springBone.specVersion = "0.0"

        // Parse collider groups first (referenced by boneGroups)
        if let colliderGroups = dict["colliderGroups"] as? [[String: Any]] {
            for (index, groupDict) in colliderGroups.enumerated() {
                var group = VRMColliderGroup(name: "colliderGroup_\(index)")

                if let colliders = groupDict["colliders"] as? [[String: Any]] {
                    for colliderDict in colliders {
                        let node: Int
                        if let groupNode = groupDict["node"] as? Int {
                            node = groupNode
                        } else if let colliderNode = colliderDict["node"] as? Int {
                            node = colliderNode
                        } else {
                            continue
                        }

                        let offset = parseVRM0Vector3(colliderDict["offset"]) ?? .zero
                        let radius = parseFloatValue(colliderDict["radius"]) ?? 0.0
                        let collider = VRMCollider(
                            node: node,
                            shape: .sphere(offset: offset, radius: radius))
                        let colliderIndex = springBone.colliders.count
                        springBone.colliders.append(collider)
                        group.colliders.append(colliderIndex)
                    }
                }

                springBone.colliderGroups.append(group)
            }
        }

        // Parse boneGroups — each entry in `bones` is a separate chain root.
        // Per VRM 0.x spec: "bones" contains root node indices; the chain extends
        // down through single-child descendants from each root.
        if let boneGroups = dict["boneGroups"] as? [[String: Any]] {
            let gltfNodes = document.nodes ?? []

            for groupDict in boneGroups {
                let sharedParams = parseBoneGroupParams(groupDict)

                if let roots = groupDict["bones"] as? [Int] {
                    for rootIndex in roots {
                        var spring = VRMSpring(name: groupDict["comment"] as? String)

                        if let center = groupDict["center"] as? Int {
                            spring.center = center
                        }

                        if let groups = groupDict["colliderGroups"] as? [Int] {
                            spring.colliderGroups = groups
                        }

                        // Build joint chain from root down through single-child descendants
                        let chainIndices = buildChain(from: rootIndex, nodes: gltfNodes)
                        for nodeIndex in chainIndices {
                            spring.joints.append(makeJoint(node: nodeIndex, params: sharedParams))
                        }

                        if spring.joints.count >= 1 {
                            springBone.springs.append(spring)
                        }
                    }
                }
            }
        }

        return springBone
    }

    // MARK: - Helpers

    /// Physics params shared by all joints in a VRM 0.x bone group.
    private struct BoneGroupParams {
        var stiffness: Float
        var gravityPower: Float
        var gravityDir: SIMD3<Float>
        var dragForce: Float
        var hitRadius: Float
    }

    private func parseBoneGroupParams(_ dict: [String: Any]) -> BoneGroupParams {
        let stiffness: Float
        if let v = dict["stiffness"] as? Float { stiffness = v } else if let v = dict["stiffness"] as? Double { stiffness = Float(v) } else if let v = dict["stiffness"] as? NSNumber { stiffness = v.floatValue }
        // Legacy typo variant
        else if let v = dict["stiffiness"] as? Float { stiffness = v } else if let v = dict["stiffiness"] as? Double { stiffness = Float(v) } else { stiffness = 1.0 }

        // Respect gravityPower = 0 — it means no gravity (e.g. chest/breast groups).
        // Do NOT override with 1.0; that forces gravity onto bones that opted out.
        let gravityPower: Float
        if let v = dict["gravityPower"] as? Float { gravityPower = v } else if let v = dict["gravityPower"] as? Double { gravityPower = Float(v) } else if let v = dict["gravityPower"] as? NSNumber { gravityPower = v.floatValue } else { gravityPower = 0.0 }

        let gravityDir: SIMD3<Float>
        if let gd = dict["gravityDir"] as? [String: Any] {
            let x = gd["x"] as? Float ?? 0
            let y = gd["y"] as? Float ?? -1
            let z = gd["z"] as? Float ?? 0
            gravityDir = SIMD3<Float>(x, y, z)
        } else {
            gravityDir = SIMD3<Float>(0, -1, 0)
        }

        let dragForce: Float
        if let v = dict["dragForce"] as? Float { dragForce = v } else if let v = dict["dragForce"] as? Double { dragForce = Float(v) } else if let v = dict["dragForce"] as? NSNumber { dragForce = v.floatValue } else { dragForce = 0.4 }

        let hitRadius: Float
        if let v = dict["hitRadius"] as? Float { hitRadius = v } else if let v = dict["hitRadius"] as? Double { hitRadius = Float(v) } else if let v = dict["hitRadius"] as? NSNumber { hitRadius = v.floatValue } else { hitRadius = 0.0 }

        return BoneGroupParams(
            stiffness: stiffness,
            gravityPower: gravityPower,
            gravityDir: gravityDir,
            dragForce: dragForce,
            hitRadius: hitRadius
        )
    }

    private func makeJoint(node: Int, params: BoneGroupParams) -> VRMSpringJoint {
        var joint = VRMSpringJoint(node: node)
        joint.stiffness = params.stiffness
        joint.gravityPower = params.gravityPower
        joint.gravityDir = params.gravityDir
        joint.dragForce = params.dragForce
        joint.hitRadius = params.hitRadius
        return joint
    }

    /// Traverses single-child descendants to build the full joint chain from a root.
    /// Stops when a leaf or a branching node (multiple children) is reached.
    private func buildChain(from root: Int, nodes: [GLTFNode]) -> [Int] {
        var chain = [root]
        var current = root
        while let children = nodes[safe: current]?.children, children.count == 1 {
            current = children[0]
            chain.append(current)
        }
        return chain
    }

    func parseVRM0Vector3(_ value: Any?) -> SIMD3<Float>? {
        guard let dict = value as? [String: Any] else { return nil }
        let x = dict["x"] as? Float ?? 0
        let y = dict["y"] as? Float ?? 0
        let z = dict["z"] as? Float ?? 0
        return SIMD3<Float>(x, y, z)
    }
}
