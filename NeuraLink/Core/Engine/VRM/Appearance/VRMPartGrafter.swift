//
//  VRMPartGrafter.swift
//  NeuraLink
//
//  Grafts a part (hair, outfit) from a fully loaded donor VRMModel onto a
//  host. The Unity reference parents hair-only prefabs under each body and
//  toggles them; here the equivalent is index bookkeeping over the host's
//  plain arrays:
//
//    1. pick donor primitives by slot (hair+hairBack, or body+clothes);
//    2. clone them (GPU buffers shared, new material indices), re-home the
//       materials + only the textures they use;
//    3. build a skin whose joints resolve to HOST nodes — humanoid bones by
//       name, everything else (hair chains, skirt bones) appended under its
//       mapped ancestor with the donor's local TRS;
//    4. bring the donor springs/colliders that drive the appended bones;
//    5. hide the host's own primitives in those slots.
//
//  Bind: donor inverse-bind matrices are kept (they map a vertex into the
//  donor joint's local frame; the host joint then places it), so the part
//  follows the host bones exactly. Across spec versions the renderer yaws
//  0.x models by 180°, so every bone-local quantity is conjugated by that
//  yaw (IBM, appended TRS, collider offsets, gravity).
//

import Foundation
import Metal
import simd

public enum VRMPartGraftError: Error, LocalizedError {
    case donorHasNoPart(AppearancePartKind)
    case noHumanoid

    public var errorDescription: String? {
        switch self {
        case .donorHasNoPart(let kind): return "The donor model has no \(kind.rawValue) part."
        case .noHumanoid: return "The model has no humanoid bone map."
        }
    }
}

public enum VRMPartGrafter {

    @discardableResult
    public static func graft(
        _ kind: AppearancePartKind, from donor: VRMModel, donorSlug: String, onto host: VRMModel
    ) throws -> GraftReceipt {
        guard host.humanoid != nil else { throw VRMPartGraftError.noHumanoid }
        host.beginComposition()
        let yaw: simd_quatf? = donor.isVRM0 != host.isVRM0 ? VRMModel.vrmVersionYaw : nil
        let counts = Counts()

        // 1. Donor primitives by slot, grouped by their mesh node (skin).
        var selection: [(node: VRMNode, mesh: VRMMesh, primitives: [VRMPrimitive])] = []
        for node in donor.nodes {
            guard let meshIndex = node.mesh, meshIndex < donor.meshes.count else { continue }
            let mesh = donor.meshes[meshIndex]
            let picked = mesh.primitives.filter { primitive in
                guard let m = primitive.materialIndex, m < donor.materials.count else { return false }
                return kind.slots.contains(VRoidMaterialSlot.classify(materialName: donor.materials[m].name))
            }
            if !picked.isEmpty { selection.append((node, mesh, picked)) }
        }
        guard !selection.isEmpty else { throw VRMPartGraftError.donorHasNoPart(kind) }

        // 2 + 3. Re-home materials/textures, resolve skins, append meshes.
        var textureMap: [Int: Int] = [:]
        var materialMap: [Int: Int] = [:]
        var nodeMap: [Int: VRMNode] = [:]  // donor node index → host node
        for (donorNode, donorMesh, primitives) in selection {
            let newMesh = VRMMesh(name: donorMesh.name)
            var usedJoints = Set<Int>()
            for primitive in primitives {
                let clone = primitive.shallowClone()
                if let m = primitive.materialIndex {
                    clone.materialIndex = rehomeMaterial(m, donor: donor, host: host,
                                                         materialMap: &materialMap, textureMap: &textureMap, counts: counts)
                }
                usedJoints.formUnion(primitive.referencedJoints())
                newMesh.primitives.append(clone)
            }
            var skinIndex: Int?
            if let donorSkinIndex = donorNode.skin, donorSkinIndex < donor.skins.count {
                let skin = resolveSkin(donor.skins[donorSkinIndex], usedJoints: usedJoints, donor: donor,
                                       host: host, nodeMap: &nodeMap, yaw: yaw, counts: counts)
                host.skins.append(skin)
                skinIndex = host.skins.count - 1
                counts.skins += 1
            }
            host.meshes.append(newMesh)
            counts.meshes += 1
            let meshNode = VRMNode(
                index: host.nodes.count, name: donorNode.name ?? "\(kind.rawValue)_part",
                translation: donorNode.translation, rotation: donorNode.rotation, scale: donorNode.scale,
                mesh: host.meshes.count - 1, skin: skinIndex)
            host.nodes.append(meshNode)
            counts.nodes += 1
        }

        // 3b. Chain ends carry no weights but spring chains need them: bring
        // every donor descendant of an appended bone along.
        for donorIndex in Array(nodeMap.keys) {
            guard let mapped = nodeMap[donorIndex], !host.isBaseNode(mapped),
                donorIndex < donor.nodes.count
            else { continue }
            appendDescendants(of: donor.nodes[donorIndex], donor: donor, host: host, nodeMap: &nodeMap, yaw: yaw, counts: counts)
        }

        // 4. Physics for the appended bones.
        counts.springs = appendSprings(from: donor, host: host, nodeMap: nodeMap, yaw: yaw)

        // 5. Hide the host's own part.
        var hidden = 0
        for mesh in host.composition?.snapshot.meshes ?? [] {
            for primitive in mesh.primitives {
                guard let m = primitive.materialIndex, m < host.materials.count,
                    kind.slots.contains(VRoidMaterialSlot.classify(materialName: host.materials[m].name))
                else { continue }
                host.hiddenPrimitives.insert(ObjectIdentifier(primitive))
                hidden += 1
            }
        }

        host.buildNodeLookupTable()
        host.updateNodeTransforms()
        let receipt = GraftReceipt(
            kind: kind, donorSlug: donorSlug.lowercased(), meshCount: counts.meshes,
            materialCount: counts.materials, textureCount: counts.textures, nodeCount: counts.nodes,
            skinCount: counts.skins, springCount: counts.springs, hiddenPrimitiveCount: hidden)
        host.composition?.grafts.removeAll { $0.kind == kind }
        host.composition?.grafts.append(receipt)
        nlLog("[Graft] \(kind.rawValue) from '\(donorSlug)': +\(counts.meshes) meshes, +\(counts.nodes) nodes, +\(counts.springs) springs, hid \(hidden)", level: .info)
        return receipt
    }

    // MARK: - Materials & textures

    private final class Counts {
        var meshes = 0, materials = 0, textures = 0, nodes = 0, skins = 0, springs = 0
    }

    private static func rehomeMaterial(
        _ donorIndex: Int, donor: VRMModel, host: VRMModel,
        materialMap: inout [Int: Int], textureMap: inout [Int: Int], counts: Counts
    ) -> Int {
        if let existing = materialMap[donorIndex] { return existing }
        let source = donor.materials[donorIndex]
        let copy = VRMMaterial(copying: source)
        func rehome(_ texture: VRMTexture?) {
            guard let texture, let donorTexIndex = donor.textures.firstIndex(where: { $0 === texture }) else { return }
            _ = rehomeTexture(donorTexIndex, donor: donor, host: host, textureMap: &textureMap, counts: counts)
        }
        rehome(copy.baseColorTexture)
        rehome(copy.normalTexture)
        rehome(copy.emissiveTexture)
        if var mtoon = copy.mtoon {
            func remap(_ index: Int?) -> Int? {
                index.map { rehomeTexture($0, donor: donor, host: host, textureMap: &textureMap, counts: counts) }
            }
            mtoon.shadeMultiplyTexture = remap(mtoon.shadeMultiplyTexture)
            mtoon.matcapTexture = remap(mtoon.matcapTexture)
            mtoon.rimMultiplyTexture = remap(mtoon.rimMultiplyTexture)
            mtoon.outlineWidthMultiplyTexture = remap(mtoon.outlineWidthMultiplyTexture)
            mtoon.uvAnimationMaskTexture = remap(mtoon.uvAnimationMaskTexture)
            if var shift = mtoon.shadingShiftTexture, let remapped = remap(shift.index) {
                shift.index = remapped
                mtoon.shadingShiftTexture = shift
            }
            copy.mtoon = mtoon
        }
        host.materials.append(copy)
        counts.materials += 1
        materialMap[donorIndex] = host.materials.count - 1
        return host.materials.count - 1
    }

    private static func rehomeTexture(
        _ donorIndex: Int, donor: VRMModel, host: VRMModel, textureMap: inout [Int: Int], counts: Counts
    ) -> Int {
        if let existing = textureMap[donorIndex] { return existing }
        guard donorIndex < donor.textures.count else { return donorIndex }
        host.textures.append(donor.textures[donorIndex])
        counts.textures += 1
        textureMap[donorIndex] = host.textures.count - 1
        return host.textures.count - 1
    }

    // MARK: - Skeleton

    private static func resolveSkin(
        _ donorSkin: VRMSkin, usedJoints: Set<Int>, donor: VRMModel, host: VRMModel,
        nodeMap: inout [Int: VRMNode], yaw: simd_quatf?, counts: Counts
    ) -> VRMSkin {
        var joints: [VRMNode] = []
        var ibms: [float4x4] = []
        let yawMatrix = yaw.map { float4x4($0) }
        for (i, joint) in donorSkin.joints.enumerated() {
            let ibm = i < donorSkin.inverseBindMatrices.count ? donorSkin.inverseBindMatrices[i] : matrix_identity_float4x4
            // Joints the part never weights still need a valid slot in the
            // palette; bind them to hips so a stray index can't explode.
            let hostNode: VRMNode
            if usedJoints.contains(i) {
                hostNode = resolveNode(joint, donor: donor, host: host, nodeMap: &nodeMap, yaw: yaw, counts: counts)
            } else {
                hostNode = host.compositionBindTarget(forDonorBoneNamed: joint.name) ?? host.nodes[0]
            }
            joints.append(hostNode)
            ibms.append(yawMatrix.map { $0 * ibm } ?? ibm)
        }
        return VRMSkin(name: donorSkin.name, joints: joints, inverseBindMatrices: ibms)
    }

    /// Host node standing in for a donor node: bound by name for humanoid /
    /// J_Adj bones, otherwise appended (with its unmapped ancestors) under
    /// the nearest mapped ancestor.
    private static func resolveNode(
        _ donorNode: VRMNode, donor: VRMModel, host: VRMModel,
        nodeMap: inout [Int: VRMNode], yaw: simd_quatf?, counts: Counts
    ) -> VRMNode {
        if let mapped = nodeMap[donorNode.index] { return mapped }
        if let bound = host.compositionBindTarget(forDonorBoneNamed: donorNode.name) {
            nodeMap[donorNode.index] = bound
            return bound
        }
        // Parent first so the chain above us exists in the host.
        let hostParent: VRMNode? = donorNode.parent.map {
            resolveNode($0, donor: donor, host: host, nodeMap: &nodeMap, yaw: yaw, counts: counts)
        }
        // Conjugate EVERY appended local frame by the version yaw so
        // world = R·Wd·R⁻¹ holds down the whole appended chain, matching the
        // host bones (identity rest) and the R·IBM used for skinning.
        let translation: SIMD3<Float>
        let rotation: simd_quatf
        if let yaw {
            translation = yaw.act(donorNode.initialTranslation)
            rotation = yaw * donorNode.initialRotation * yaw.inverse
        } else {
            translation = donorNode.initialTranslation
            rotation = donorNode.initialRotation
        }
        let node = VRMNode(
            index: host.nodes.count, name: donorNode.name, translation: translation,
            rotation: rotation, scale: donorNode.initialScale)
        host.nodes.append(node)
        counts.nodes += 1
        if let hostParent {
            node.parent = hostParent
            hostParent.children.append(node)
        } else if let root = host.nodes.first(where: { $0.parent == nil && $0.mesh == nil }) {
            node.parent = root
            root.children.append(node)
        }
        nodeMap[donorNode.index] = node
        return node
    }

    private static func appendDescendants(
        of donorNode: VRMNode, donor: VRMModel, host: VRMModel,
        nodeMap: inout [Int: VRMNode], yaw: simd_quatf?, counts: Counts
    ) {
        for child in donorNode.children where child.mesh == nil {
            _ = resolveNode(child, donor: donor, host: host, nodeMap: &nodeMap, yaw: yaw, counts: counts)
            appendDescendants(of: child, donor: donor, host: host, nodeMap: &nodeMap, yaw: yaw, counts: counts)
        }
    }

    // MARK: - Physics

    /// Appends the donor springs that drive appended bones (plus the
    /// collider groups they reference). Returns the number of springs added.
    private static func appendSprings(
        from donor: VRMModel, host: VRMModel, nodeMap: [Int: VRMNode], yaw: simd_quatf?
    ) -> Int {
        guard let donorSpring = donor.springBone else { return 0 }
        let appended = Set(nodeMap.values.filter { !host.isBaseNode($0) }.map { ObjectIdentifier($0) })
        guard !appended.isEmpty else { return 0 }

        var hostSpring = host.springBone ?? VRMSpringBone()
        var colliderMap: [Int: Int] = [:]
        var groupMap: [Int: Int] = [:]
        var added = 0

        for spring in donorSpring.springs {
            let mappedJoints = spring.joints.compactMap { joint -> VRMSpringJoint? in
                guard let node = nodeMap[joint.node] else { return nil }
                var copy = joint
                copy.node = node.index
                if let yaw { copy.gravityDir = yaw.act(joint.gravityDir) }
                return copy
            }
            // The chain must be intact and belong to the part.
            guard mappedJoints.count == spring.joints.count,
                mappedJoints.contains(where: { appended.contains(ObjectIdentifier(host.nodes[$0.node])) })
            else { continue }
            var copy = spring
            copy.joints = mappedJoints
            copy.center = spring.center.flatMap { nodeMap[$0]?.index }
            copy.colliderGroups = spring.colliderGroups.compactMap { groupIndex in
                rehomeColliderGroup(groupIndex, donor: donorSpring, host: &hostSpring, nodeMap: nodeMap,
                                    yaw: yaw, colliderMap: &colliderMap, groupMap: &groupMap)
            }
            hostSpring.springs.append(copy)
            added += 1
        }
        if added > 0 { host.springBone = hostSpring }
        return added
    }

    private static func rehomeColliderGroup(
        _ groupIndex: Int, donor: VRMSpringBone, host: inout VRMSpringBone, nodeMap: [Int: VRMNode],
        yaw: simd_quatf?, colliderMap: inout [Int: Int], groupMap: inout [Int: Int]
    ) -> Int? {
        if let existing = groupMap[groupIndex] { return existing }
        guard groupIndex < donor.colliderGroups.count else { return nil }
        let group = donor.colliderGroups[groupIndex]
        var colliders: [Int] = []
        for colliderIndex in group.colliders {
            if let existing = colliderMap[colliderIndex] {
                colliders.append(existing)
                continue
            }
            guard colliderIndex < donor.colliders.count,
                let node = nodeMap[donor.colliders[colliderIndex].node]
            else { continue }
            var collider = donor.colliders[colliderIndex]
            collider.node = node.index
            if let yaw { collider.shape = rotated(collider.shape, by: yaw) }
            host.colliders.append(collider)
            colliderMap[colliderIndex] = host.colliders.count - 1
            colliders.append(host.colliders.count - 1)
        }
        guard !colliders.isEmpty else { return nil }
        host.colliderGroups.append(VRMColliderGroup(name: group.name, colliders: colliders))
        groupMap[groupIndex] = host.colliderGroups.count - 1
        return host.colliderGroups.count - 1
    }

    private static func rotated(_ shape: VRMColliderShape, by yaw: simd_quatf) -> VRMColliderShape {
        switch shape {
        case .sphere(let offset, let radius):
            return .sphere(offset: yaw.act(offset), radius: radius)
        case .capsule(let offset, let radius, let tail):
            return .capsule(offset: yaw.act(offset), radius: radius, tail: yaw.act(tail))
        case .plane(let offset, let normal):
            return .plane(offset: yaw.act(offset), normal: yaw.act(normal))
        }
    }
}

// MARK: - Primitive helpers

extension VRMPrimitive {
    /// New primitive sharing this one's GPU buffers (vertex, index, morph)
    /// with its own material index. Morph state is per-primitive in the
    /// renderer's caches, so a clone behaves like a separate draw.
    public func shallowClone() -> VRMPrimitive {
        let clone = VRMPrimitive()
        clone.vertexBuffer = vertexBuffer
        clone.indexBuffer = indexBuffer
        clone.vertexCount = vertexCount
        clone.indexCount = indexCount
        clone.indexType = indexType
        clone.indexBufferOffset = indexBufferOffset
        clone.primitiveType = primitiveType
        clone.materialIndex = materialIndex
        clone.hasNormals = hasNormals
        clone.hasTexCoords = hasTexCoords
        clone.hasTangents = hasTangents
        clone.hasColors = hasColors
        clone.hasJoints = hasJoints
        clone.hasWeights = hasWeights
        clone.requiredPaletteSize = requiredPaletteSize
        clone.morphTargets = morphTargets
        clone.morphPositionBuffers = morphPositionBuffers
        clone.morphNormalBuffers = morphNormalBuffers
        clone.morphTangentBuffers = morphTangentBuffers
        clone.morphPositionsSoA = morphPositionsSoA
        clone.morphNormalsSoA = morphNormalsSoA
        clone.basePositionsBuffer = basePositionsBuffer
        clone.baseNormalsBuffer = baseNormalsBuffer
        return clone
    }

    /// Skin joint slots this primitive actually weights, read back from the
    /// shared-storage buffers. Only vertices its INDEX buffer references
    /// count: VRoid 2.x merges every body part into one vertex array, so
    /// scanning the whole buffer would credit a back-hair primitive with the
    /// feet and skirt bones. Empty when unskinned.
    public func referencedJoints() -> Set<Int> {
        guard hasJoints, let vertexBuffer, vertexBuffer.storageMode == .shared,
            let jointsOffset = MemoryLayout<VRMVertex>.offset(of: \VRMVertex.joints),
            let weightsOffset = MemoryLayout<VRMVertex>.offset(of: \VRMVertex.weights)
        else { return [] }
        let stride = MemoryLayout<VRMVertex>.stride
        guard vertexBuffer.length >= vertexCount * stride else { return [] }
        let base = vertexBuffer.contents()
        var used = Set<Int>()
        func visit(_ i: Int) {
            guard i < vertexCount else { return }
            let joints = base.load(fromByteOffset: i * stride + jointsOffset, as: SIMD4<UInt32>.self)
            let weights = base.load(fromByteOffset: i * stride + weightsOffset, as: SIMD4<Float>.self)
            for k in 0..<4 where weights[k] > 0 { used.insert(Int(joints[k])) }
        }
        if let indexBuffer, indexCount > 0, indexBuffer.storageMode == .shared {
            let indexBase = indexBuffer.contents().advanced(by: indexBufferOffset)
            var seen = Set<Int>()
            for n in 0..<indexCount {
                let vertex: Int
                switch indexType {
                case .uint16: vertex = Int(indexBase.load(fromByteOffset: n * 2, as: UInt16.self))
                case .uint32: vertex = Int(indexBase.load(fromByteOffset: n * 4, as: UInt32.self))
                @unknown default: return []
                }
                if seen.insert(vertex).inserted { visit(vertex) }
            }
        } else {
            for i in 0..<vertexCount { visit(i) }
        }
        return used
    }
}
