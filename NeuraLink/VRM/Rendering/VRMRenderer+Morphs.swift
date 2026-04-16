//
//  VRMRenderer+Morphs.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import Metal

// MARK: - Compute Pass for Morphs

extension VRMRenderer {

    func applyMorphTargetsCompute(commandBuffer: MTLCommandBuffer) -> [MorphKey: MTLBuffer] {
        guard let model = model,
            let morphTargetSystem = morphTargetSystem
        else { return [:] }

        // Decide if compute path is needed (presence of any morphs > 0 or >8 targets anywhere)
        var needsComputePath = false

        // Check if any primitive has active morphs with non-zero weights
        var hasActiveMorphs = false
        if let controller = expressionController {
            for (meshIndex, mesh) in model.meshes.enumerated() {
                for primitive in mesh.primitives where !primitive.morphTargets.isEmpty {
                    let weights = controller.weightsForMesh(
                        meshIndex, morphCount: primitive.morphTargets.count)
                    let hasNonZero = weights.contains { $0 > 0.001 }
                    if hasNonZero {
                        hasActiveMorphs = true
                        break
                    }
                }
                if hasActiveMorphs { break }
            }
        }

        // Check if any primitive has too many morphs for direct binding
        if !needsComputePath {
            for mesh in model.meshes {
                for primitive in mesh.primitives {
                    if primitive.morphTargets.count > 8 {
                        needsComputePath = true
                        break
                    }
                }
                if needsComputePath { break }
            }
        }

        // ALWAYS run compute path if we have active morphs, regardless of morph count
        if !needsComputePath && hasActiveMorphs {
            needsComputePath = true
        }

        guard needsComputePath else { return [:] }

        // Apply morphs to each primitive that has morph targets
        // Store morphed buffer references for render pass using STABLE KEYS
        var morphedBuffers: [MorphKey: MTLBuffer] = [:]

        for (meshIndex, mesh) in model.meshes.enumerated() {
            for (primitiveIndex, primitive) in mesh.primitives.enumerated()
            where !primitive.morphTargets.isEmpty {
                if primitive.morphTargets.count > 8 {
                    assert(
                        primitive.basePositionsBuffer != nil,
                        "[VRMRenderer] FATAL: Compute path required but basePositionsBuffer is nil for primitive with \(primitive.morphTargets.count) morphs!"
                    )
                }

                guard let basePositions = primitive.basePositionsBuffer,
                    let deltaPositions = primitive.morphPositionsSoA,
                    let outputBuffer = morphTargetSystem.getOrCreateMorphedPositionBuffer(
                        primitiveID: ObjectIdentifier(primitive).hashValue,
                        vertexCount: primitive.vertexCount
                    )
                else {
                    continue
                }

                let localWeights =
                    expressionController?.weightsForMesh(
                        meshIndex, morphCount: primitive.morphTargets.count) ?? []
                let primitiveActiveSet = morphTargetSystem.buildActiveSet(weights: localWeights)

                guard !primitiveActiveSet.isEmpty else { continue }

                let success = morphTargetSystem.applyMorphsCompute(
                    basePositions: basePositions,
                    deltaPositions: deltaPositions,
                    outputPositions: outputBuffer,
                    vertexCount: primitive.vertexCount,
                    morphCount: primitive.morphTargets.count,
                    commandBuffer: commandBuffer
                )

                if success {
                    let stableKey: MorphKey = (UInt64(meshIndex) << 32) | UInt64(primitiveIndex)
                    morphedBuffers[stableKey] = outputBuffer
                }
            }
        }

        return morphedBuffers
    }
}
