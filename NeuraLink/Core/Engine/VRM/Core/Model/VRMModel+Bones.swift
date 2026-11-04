//
// VRMModel+Bones.swift
// NeuraLink
//
// Created by Dedicatus on 14/04/2026.
//

import Foundation
import Metal
import simd

extension VRMModel {

    // MARK: - Convenience Methods for Bone Manipulation

    /// Sets the local rotation for a specific humanoid bone.
    public func setLocalRotation(_ rotation: simd_quatf, for bone: VRMHumanoidBone) {
        guard let humanoid = humanoid,
            let nodeIndex = humanoid.getBoneNode(bone),
            nodeIndex < nodes.count
        else {
            return
        }

        withLock {
            nodes[nodeIndex].rotation = rotation
            nodes[nodeIndex].updateLocalMatrix()
        }
    }

    /// Gets the local rotation for a specific humanoid bone.
    public func getLocalRotation(for bone: VRMHumanoidBone) -> simd_quatf? {
        guard let humanoid = humanoid,
            let nodeIndex = humanoid.getBoneNode(bone),
            nodeIndex < nodes.count
        else {
            return nil
        }

        return withLock {
            nodes[nodeIndex].rotation
        }
    }

    /// Sets the translation of the hips bone.
    public func setHipsTranslation(_ translation: simd_float3) {
        guard let humanoid = humanoid,
            let hipsIndex = humanoid.getBoneNode(.hips),
            hipsIndex < nodes.count
        else {
            return
        }

        withLock {
            nodes[hipsIndex].translation = translation
            nodes[hipsIndex].updateLocalMatrix()
        }
    }

    /// Gets the current translation of the hips bone.
    public func getHipsTranslation() -> simd_float3? {
        guard let humanoid = humanoid,
            let hipsIndex = humanoid.getBoneNode(.hips),
            hipsIndex < nodes.count
        else {
            return nil
        }

        return withLock {
            nodes[hipsIndex].translation
        }
    }

    /// Finds a node by its normalized name using O(1) hash table lookup.
    public func findNodeByNormalizedName(_ normalizedName: String) -> VRMNode? {
        return nodeLookupTable[normalizedName]
    }

    /// Recalculates world transforms for all nodes based on their local transforms.
    ///
    /// Call this after modifying node local transforms (translation, rotation, scale)
    /// to propagate changes through the hierarchy. This is automatically called
    /// during animation updates.
    ///
    /// - Complexity: O(n) where n is the number of nodes.
    public func updateNodeTransforms() {
        for node in nodes where node.parent == nil {
            node.updateWorldTransform()
        }
    }

    // MARK: - Spring Bones

    /// VRM 0.x names only the root of each chain; every node under it is a
    /// joint. Expands each root into its chain, once, at load. VRM 1.0 lists
    /// every joint already: expanding it made each joint the root of another
    /// copy of the rest of its chain, so the same bones were simulated by
    /// several chains at once.
    public func expandVRM0SpringBoneChains() {
        guard isVRM0, var springBone = springBone else { return }

        var expandedSprings: [VRMSpring] = []

        for spring in springBone.springs {
            // For each root in the spring, create a separate chain with proper ordering
            for rootJoint in spring.joints {
                guard rootJoint.node < nodes.count else { continue }
                let rootNode = nodes[rootJoint.node]

                // DFS traversal to build chain in parent-child order
                var chainJoints: [VRMSpringJoint] = []
                traverseChainDFS(node: rootNode, settings: rootJoint, joints: &chainJoints)

                if chainJoints.count >= 2 {
                    // Create a new spring for this chain
                    var chainSpring = spring
                    chainSpring.joints = chainJoints
                    expandedSprings.append(chainSpring)
                }
            }
        }

        // Only replace if we expanded
        if !expandedSprings.isEmpty {
            let originalCount = springBone.springs.reduce(0) { $0 + $1.joints.count }
            let expandedCount = expandedSprings.reduce(0) { $0 + $1.joints.count }
            if expandedCount > originalCount {
                springBone.springs = expandedSprings
                self.springBone = springBone
            }
        }
    }

    /// DFS traversal to build a chain in correct parent-child order
    func traverseChainDFS(
        node: VRMNode, settings: VRMSpringJoint, joints: inout [VRMSpringJoint]
    ) {
        guard let nodeIndex = nodes.firstIndex(where: { $0 === node }) else { return }

        // Create joint for this node
        var joint = VRMSpringJoint(node: nodeIndex)
        joint.stiffness = settings.stiffness
        joint.gravityPower = settings.gravityPower
        joint.dragForce = settings.dragForce
        joint.hitRadius = settings.hitRadius
        joint.gravityDir = settings.gravityDir
        joints.append(joint)

        // Recurse to children (DFS maintains order)
        for child in node.children {
            traverseChainDFS(node: child, settings: settings, joints: &joints)
        }
    }

    /// Total spring-bone joints the current spring data needs room for.
    public var springBoneJointCount: Int {
        springBone?.springs.reduce(0) { $0 + $1.joints.count } ?? 0
    }
}
