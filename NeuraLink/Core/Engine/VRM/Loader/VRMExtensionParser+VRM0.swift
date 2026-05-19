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

            // Identify core humanoid bone node indices to prevent physics being applied
            // to skeleton bones (which causes chest/torso pulsating/vibrating artifacts).
            let coreBoneNodes = parseVRM0HumanoidBoneNodes(from: document)

            for groupDict in boneGroups {
                let sharedParams = parseBoneGroupParams(groupDict)

                if let roots = groupDict["bones"] as? [Int] {
                    for rootIndex in roots {
                        // Bust/breast bones (J_Sec_L/R_Bust1/2) are children of UpperChest
                        // and deform the chest mesh with any physics motion, producing the
                        // 'pulsating chest' artifact. Excluding the entire spring chain here
                        // (rather than pinning parameters) ensures the GPU simulation never
                        // touches these nodes — they will simply follow UpperChest rigidly.
                        let rootName = gltfNodes[safe: rootIndex]?.name?.lowercased() ?? ""
                        let isBustRoot = rootName.contains("bust")
                            || rootName.contains("breast")
                            || rootName.contains("mune")
                        if isBustRoot { continue }

                        var spring = VRMSpring(name: groupDict["comment"] as? String)

                        if let center = groupDict["center"] as? Int {
                            spring.center = center
                        }

                        if let groups = groupDict["colliderGroups"] as? [Int] {
                            spring.colliderGroups = groups
                        }

                        // Build joint chain from root down through single-child descendants
                        let chainIndices = buildChain(from: rootIndex, nodes: gltfNodes, excluded: coreBoneNodes)
                        for nodeIndex in chainIndices {
                            let nodeName = gltfNodes[safe: nodeIndex]?.name
                            spring.joints.append(makeJoint(node: nodeIndex, params: sharedParams, nodeName: nodeName))
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

    private func makeJoint(node: Int, params: BoneGroupParams, nodeName: String?) -> VRMSpringJoint {
        var joint = VRMSpringJoint(node: node)

        // Bust/breast roots are excluded before this point (see parseSecondaryAnimation),
        // so no bust-specific clamping is needed here.

        var stiffness = params.stiffness
        var gravityPower = params.gravityPower
        var drag = params.dragForce

        let lowerName = nodeName?.lowercased() ?? ""
        let isCore = lowerName.contains("chest") || lowerName.contains("spine")
            || lowerName.contains("hips") || lowerName.contains("neck")

        if isCore {
            // Safety net: core humanoid bones that somehow escaped the coreBoneNodes exclusion
            // must never accumulate physics velocity. Pin them completely.
            gravityPower = 0.0
            drag = 1.0
            stiffness = 1.0
        } else {
            // General safety clamps for secondary bones (hair, ribbons, skirts, etc.)
            gravityPower = min(gravityPower, 0.8)
            drag = max(drag, 0.3)
            stiffness = max(stiffness, 0.05)
        }

        joint.stiffness = stiffness
        joint.gravityPower = gravityPower
        joint.gravityDir = params.gravityDir
        joint.dragForce = drag
        joint.hitRadius = params.hitRadius
        return joint
    }

    /// Traverses single-child descendants to build the full joint chain from a root.
    /// Stops when a leaf or a branching node (multiple children) is reached.
    private func buildChain(from root: Int, nodes: [GLTFNode], excluded: Set<Int>) -> [Int] {
        // Optimization: Standard humanoid bones should NEVER be spring bones.
        // Including them causes 'pulsating' or 'vibrating' artifacts as the physics 
        // engine tries to simulate gravity on the character's core structure.
        let coreBones: Set<VRMHumanoidBone> = [
            .hips, .spine, .chest, .upperChest, .neck, .head,
            .leftUpperArm, .rightUpperArm, .leftUpperLeg, .rightUpperLeg,
            .leftShoulder, .rightShoulder
        ]
        
        var chain = [Int]()
        var current = root
        
        // Safety check: if the root itself is a core bone (explicitly mapped or guessed), ignore it.
        let rootIsCore = excluded.contains(root) || (VRMHumanoidBone.heuristic(for: nodes[safe: root]?.name ?? "").map { coreBones.contains($0) } ?? false)
        if rootIsCore {
            return []
        }
        
        while true {
            chain.append(current)
            
            guard let children = nodes[safe: current]?.children, children.count == 1 else {
                break
            }
            
            let next = children[0]
            // Stop if the NEXT bone is a core bone
            let nextIsCore = excluded.contains(next) || (VRMHumanoidBone.heuristic(for: nodes[safe: next]?.name ?? "").map { coreBones.contains($0) } ?? false)
            if nextIsCore {
                break
            }
            
            current = next
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

    /// Reads the VRM 0.x humanoid bone→node mapping from the model's `VRM` extension.
    /// Returns the set of node indices that correspond to core skeleton bones.
    /// These must be excluded from secondary animation (spring bone) physics chains
    /// to prevent the 'pulsating torso' artifact caused by gravity on structural bones.
    func parseVRM0HumanoidBoneNodes(from document: GLTFDocument) -> Set<Int> {
        let coreBoneNames: Set<String> = [
            "hips", "spine", "chest", "upperChest", "neck", "head",
            "leftShoulder", "rightShoulder",
            "leftUpperArm", "rightUpperArm",
            "leftUpperLeg", "rightUpperLeg"
        ]

        guard let vrmExt     = document.extensions?["VRM"] as? [String: Any],
              let humanoid   = vrmExt["humanoid"] as? [String: Any],
              let humanBones = humanoid["humanBones"] as? [[String: Any]]
        else { return [] }

        var nodeIndices = Set<Int>()
        for boneDict in humanBones {
            guard let boneName = boneDict["bone"] as? String,
                  coreBoneNames.contains(boneName),
                  let nodeIndex = boneDict["node"] as? Int
            else { continue }
            nodeIndices.insert(nodeIndex)
        }
        return nodeIndices
    }
}
