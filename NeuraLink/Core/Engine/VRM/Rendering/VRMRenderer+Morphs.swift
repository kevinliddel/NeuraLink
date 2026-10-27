//
//  VRMRenderer+Morphs.swift
//  NeuraLink
//
//  The per-frame morph pass: for every primitive whose mesh has weights in
//  play, the morphed positions and, when the file carries normal deltas,
//  the morphed normals (an expression that bends the face also turns its
//  shading). Positions are returned for the draws; normals are left in
//  `morphedNormalBuffers` for the same frame.
//
//  Created by Dedicatus on 16/04/2026.
//

import Metal

// MARK: - Compute Pass for Morphs

extension VRMRenderer {

    func applyMorphTargetsCompute(commandBuffer: MTLCommandBuffer) -> [MorphKey: MTLBuffer] {
        morphedNormalBuffers.removeAll(keepingCapacity: true)
        guard let model, let morphTargetSystem, let controller = expressionController else { return [:] }

        var morphedPositions: [MorphKey: MTLBuffer] = [:]
        for (meshIndex, mesh) in model.meshes.enumerated() {
            for (primitiveIndex, primitive) in mesh.primitives.enumerated() where !primitive.morphTargets.isEmpty {
                let activeSet = morphTargetSystem.buildActiveSet(
                    weights: controller.weightsForMesh(meshIndex, morphCount: primitive.morphTargets.count))
                guard !activeSet.isEmpty,
                      let basePositions = primitive.basePositionsBuffer,
                      let positionDeltas = primitive.morphPositionsSoA,
                      let positionsOut = morphTargetSystem.getOrCreateMorphedPositionBuffer(
                        primitiveID: ObjectIdentifier(primitive).hashValue, vertexCount: primitive.vertexCount),
                      morphTargetSystem.accumulate(
                        .positions, base: basePositions, deltas: positionDeltas, output: positionsOut,
                        vertexCount: primitive.vertexCount, morphCount: primitive.morphTargets.count,
                        activeSet: activeSet, commandBuffer: commandBuffer)
                else { continue }
                let key: MorphKey = (UInt64(meshIndex) << 32) | UInt64(primitiveIndex)
                morphedPositions[key] = positionsOut

                if let baseNormals = primitive.baseNormalsBuffer, let normalDeltas = primitive.morphNormalsSoA,
                   let normalsOut = morphTargetSystem.getOrCreateMorphedNormalBuffer(
                    primitiveID: ObjectIdentifier(primitive).hashValue, vertexCount: primitive.vertexCount),
                   morphTargetSystem.accumulate(
                    .normals, base: baseNormals, deltas: normalDeltas, output: normalsOut,
                    vertexCount: primitive.vertexCount, morphCount: primitive.morphTargets.count,
                    activeSet: activeSet, commandBuffer: commandBuffer) {
                    morphedNormalBuffers[key] = normalsOut
                }
            }
        }
        return morphedPositions
    }

    /// Binds this frame's morphed positions and normals for a draw (an
    /// empty placeholder where there are none) and the flag saying which
    /// are real: bit 1 positions, bit 2 normals.
    func bindMorphedVertexData(
        for key: MorphKey, morphedPositions: [MorphKey: MTLBuffer], encoder: MTLRenderCommandEncoder
    ) {
        if emptyFloat3Buffer == nil {
            emptyFloat3Buffer = device.makeBuffer(length: MemoryLayout<SIMD3<Float>>.stride, options: .storageModeShared)
        }
        let positions = morphedPositions[key]
        let normals = positions == nil ? nil : morphedNormalBuffers[key]
        encoder.setVertexBuffer(positions ?? emptyFloat3Buffer, offset: 0, index: ResourceIndices.morphedPositionsBuffer)
        encoder.setVertexBuffer(normals ?? emptyFloat3Buffer, offset: 0, index: ResourceIndices.morphedNormalsBuffer)
        var flags: UInt32 = (positions != nil ? 1 : 0) | (normals != nil ? 2 : 0)
        encoder.setVertexBytes(&flags, length: MemoryLayout<UInt32>.size, index: ResourceIndices.hasMorphedPositionsFlag)
    }
}
