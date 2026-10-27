//
//  VRMRenderer+RenderItems.swift
//  NeuraLink
//
//  The draw list: one item per visible primitive, with the material's
//  alpha mode, culling and render queue as authored, in the order Unity
//  and three-vrm draw a VRM.
//
//  Created by Dedicatus on 16/04/2026.
//

import Foundation
@preconcurrency import Metal
import simd

// MARK: - Render Item Building

extension VRMRenderer {
    func buildRenderItems(model: VRMModel) -> [RenderItem] {
        var items: [RenderItem] = []
        items.reserveCapacity(model.meshes.reduce(0) { $0 + $1.primitives.count })
        var primitiveIndex = 0

        for node in model.nodes {
            guard let meshIndex = node.mesh, meshIndex < model.meshes.count else { continue }
            let mesh = model.meshes[meshIndex]
            for (primIdxInMesh, primitive) in mesh.primitives.enumerated() {
                // Character customization: host parts replaced by a graft.
                if !model.hiddenPrimitives.isEmpty,
                    model.hiddenPrimitives.contains(ObjectIdentifier(primitive)) {
                    continue
                }
                let material = primitive.materialIndex.flatMap { $0 < model.materials.count ? model.materials[$0] : nil }
                let alphaMode = material?.alphaMode.lowercased() ?? "opaque"
                items.append(RenderItem(
                    node: node,
                    mesh: mesh,
                    primitive: primitive,
                    materialName: material?.name ?? "unnamed",
                    meshIndex: meshIndex,
                    alphaMode: ["mask", "blend"].contains(alphaMode) ? alphaMode : "opaque",
                    doubleSided: material?.doubleSided ?? false,
                    alphaCutoff: material?.alphaCutoff ?? 0.5,
                    materialRenderQueue: material?.renderQueue ?? 2000,
                    transparentZWrite: material?.isTransparentWithZWrite ?? false,
                    primitiveIndex: primitiveIndex,
                    primIdxInMesh: primIdxInMesh,
                    boundsCentre: primitive.drawnBoundsCentre()))
                primitiveIndex += 1
            }
        }
        sortRenderItems(&items)
        return items
    }

    /// Draw order, as Unity and three-vrm draw a VRM: everything that
    /// writes depth first, then the transparent parts by render queue and,
    /// within a queue, back to front by the centre of what each primitive
    /// draws. (Every primitive of a skinned mesh shares the node origin, so
    /// that can't order a face's brows, lashes and iris.)
    func sortRenderItems(_ items: inout [RenderItem]) {
        var viewZByIndex = [Int: Float]()
        for item in items where item.alphaMode == "blend" {
            let skinned = item.node.skin != nil || (item.primitive.hasJoints && item.primitive.hasWeights)
            let local = SIMD4<Float>(item.boundsCentre, 1)
            let world = vrmVersionRotation * (skinned ? local : item.node.worldMatrix * local)
            viewZByIndex[item.primitiveIndex] = (viewMatrix * world).z
        }
        items.sort { lhs, rhs in
            let lhsBlend = lhs.alphaMode == "blend", rhsBlend = rhs.alphaMode == "blend"
            if lhsBlend != rhsBlend { return rhsBlend }
            if lhs.materialRenderQueue != rhs.materialRenderQueue {
                return lhs.materialRenderQueue < rhs.materialRenderQueue
            }
            if lhsBlend {
                // View space looks down −Z: more negative is farther.
                let lhsZ = viewZByIndex[lhs.primitiveIndex] ?? 0, rhsZ = viewZByIndex[rhs.primitiveIndex] ?? 0
                if lhsZ != rhsZ { return lhsZ < rhsZ }
            }
            return lhs.primitiveIndex < rhs.primitiveIndex
        }
    }
}

extension VRMPrimitive {
    /// Centre of the bounding box of the vertices this primitive's indices
    /// reach (primitives of one mesh often share a vertex buffer).
    func drawnBoundsCentre() -> SIMD3<Float> {
        guard let vertexBuffer, vertexCount > 0 else { return .zero }
        let vertices = vertexBuffer.contents().bindMemory(to: VRMVertex.self, capacity: vertexCount)
        var low = SIMD3<Float>(repeating: .infinity)
        var high = SIMD3<Float>(repeating: -.infinity)
        func include(_ index: Int) {
            guard index < vertexCount else { return }
            low = simd_min(low, vertices[index].position)
            high = simd_max(high, vertices[index].position)
        }
        if let indexBuffer, indexCount > 0 {
            let base = indexBuffer.contents() + indexBufferOffset
            if indexType == .uint16 {
                let indices = base.bindMemory(to: UInt16.self, capacity: indexCount)
                for slot in 0..<indexCount { include(Int(indices[slot])) }
            } else {
                let indices = base.bindMemory(to: UInt32.self, capacity: indexCount)
                for slot in 0..<indexCount { include(Int(indices[slot])) }
            }
        } else {
            for index in 0..<vertexCount { include(index) }
        }
        return low.x <= high.x ? (low + high) * 0.5 : .zero
    }
}
