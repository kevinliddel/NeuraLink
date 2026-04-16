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

    // MARK: - SpringBone GPU System

    /// Expand VRM 0.0 spring bone chains by traversing node hierarchy
    /// In VRM 0.0, the bones array contains ROOT bone indices, and all descendants should become joints
    public func expandVRM0SpringBoneChains() {
        guard var springBone = springBone else { return }

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

    public func initializeSpringBoneGPUSystem(device: MTLDevice) throws {
        guard springBone != nil else {
            // No SpringBone data in this model
            return
        }

        // Expand VRM 0.0 chains (no-op for VRM 1.0 which already has full joint lists)
        expandVRM0SpringBoneChains()

        // Re-read after expansion
        guard let expandedSpringBone = self.springBone else { return }

        // Count total bones from all springs
        var totalBones = 0
        for spring in expandedSpringBone.springs {
            totalBones += spring.joints.count
        }

        // Count colliders
        let totalSpheres = expandedSpringBone.colliders.filter {
            if case .sphere = $0.shape { return true }
            return false
        }.count

        let totalCapsules = expandedSpringBone.colliders.filter {
            if case .capsule = $0.shape { return true }
            return false
        }.count

        // Initialize buffers
        springBoneBuffers = SpringBoneBuffers(device: device)
        springBoneBuffers?.allocateBuffers(
            numBones: totalBones,
            numSpheres: totalSpheres,
            numCapsules: totalCapsules
        )

        // Initialize global parameters
        // settlingFrames: 120 frames (~1 second) to let bones settle with gravity before enabling inertia compensation
        springBoneGlobalParams = SpringBoneGlobalParams(
            gravity: SIMD3<Float>(0, -9.8, 0),  // Standard gravity
            dtSub: 1.0 / 120.0,  // 120Hz fixed substeps
            windAmplitude: 0.0,
            windFrequency: 1.0,
            windPhase: 0.0,
            windDirection: SIMD3<Float>(1, 0, 0),
            substeps: 2,
            numBones: UInt32(totalBones),
            numSpheres: UInt32(totalSpheres),
            numCapsules: UInt32(totalCapsules),
            settlingFrames: 120
        )

        // TODO: Populate bone parameters, rest lengths, and colliders
        // This will be implemented in the compute system
    }

    // MARK: - Floor Plane Colliders

    /// Adds a horizontal floor plane collider at the specified Y position.
    public func setFloorPlane(at floorY: Float) {
        let floor = PlaneCollider(floorY: floorY)
        springBoneBuffers?.setPlaneColliders([floor])
        springBoneGlobalParams?.numPlanes = 1
    }

    /// Adds a floor plane collider from an ARKit plane anchor transform.
    public func setFloorPlane(arkitTransform transform: simd_float4x4) {
        let floor = PlaneCollider(arkitTransform: transform)
        springBoneBuffers?.setPlaneColliders([floor])
        springBoneGlobalParams?.numPlanes = 1
    }

    /// Removes the floor plane collider.
    public func removeFloorPlane() {
        springBoneBuffers?.setPlaneColliders([])
        springBoneGlobalParams?.numPlanes = 0
    }
}
