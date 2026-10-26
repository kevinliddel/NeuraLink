//
//  VRMRenderer+DrawCall.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import Foundation
@preconcurrency import Metal
import simd

// MARK: - Per-Item Draw Execution

extension VRMRenderer {
    /// Renders a single RenderItem whose pipeline has already been selected.
    /// Called once per item from the main draw loop in drawCore.
    func renderAcceptedItem(
        _ item: RenderItem,
        pipeline: MTLRenderPipelineState,
        encoder: MTLRenderCommandEncoder,
        model: VRMModel,
        uniformsBuffer: MTLBuffer,
        morphedBuffers: [MorphKey: MTLBuffer],
        hasSkinning: Bool
    ) {
        let primitive = item.primitive
        let prim = primitive
        let meshName = item.mesh.name ?? "unnamed"
        let meshPrimIndex = item.mesh.primitives.firstIndex(where: { $0 === primitive }) ?? -1
        let materialAlphaMode = item.alphaMode
        let isDoubleSided = item.doubleSided
        let meshUsesSkinning = primitive.hasJoints && primitive.hasWeights
        let isSkinned = ((item.node.skin != nil) || meshUsesSkinning) && hasSkinning

        if lastPipelineState !== pipeline {
            encoder.setRenderPipelineState(pipeline)
            lastPipelineState = pipeline
        }

        #if os(macOS)
            if debugWireframe { encoder.setTriangleFillMode(.lines) }
        #endif

        if lastPipelineState !== pipeline { lastPipelineState = pipeline }

        // Model matrix: VRM 1.0 faces +Z, rotate 180° Y to face camera at -Z
        let vrmRotation = vrmVersionRotation
        if isSkinned {
            uniforms.modelMatrix = vrmRotation
            uniforms.normalMatrix = vrmRotation
            uniformsBuffer.contents().copyMemory(
                from: &uniforms, byteCount: MemoryLayout<Uniforms>.size)
        } else {
            // A rigid item (a hand-held prop) has matrices of its own. The
            // ring buffer is bound by reference and read by the GPU after the
            // whole frame is encoded, so writing them there would hand every
            // draw the last item's matrices — they go in as bytes per draw
            // instead, and the buffer keeps the skinned items' values.
            uniforms.modelMatrix = simd_mul(vrmRotation, item.node.worldMatrix)
            uniforms.normalMatrix = uniforms.modelMatrix.inverse.transpose
        }

        guard let vertexBuffer = primitive.vertexBuffer else { return }

        var currentVertexOffset: UInt32 = 0

        // Morphed positions and normals (VRMRenderer+Morphs)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: ResourceIndices.vertexBuffer)
        bindMorphedVertexData(
            for: (UInt64(item.meshIndex) << 32) | UInt64(item.primIdxInMesh), morphedPositions: morphedBuffers,
            encoder: encoder)

        if isSkinned {
            encoder.setVertexBuffer(uniformsBuffer, offset: 0, index: ResourceIndices.uniformsBuffer)
        } else {
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: ResourceIndices.uniformsBuffer)
        }

        // Skinning joint buffer
        if hasSkinning && (item.node.skin != nil || meshUsesSkinning) {
            let skinIndex: Int
            if let nodeSkinIndex = item.node.skin {
                skinIndex = nodeSkinIndex
            } else if meshUsesSkinning && !model.skins.isEmpty {
                skinIndex = 0
            } else {
                skinIndex = -1
            }

            if skinIndex >= 0 && skinIndex < model.skins.count,
                let jointBuffer = skinningSystem?.getJointMatricesBuffer() {
                let byteOffset = model.skins[skinIndex].bufferByteOffset
                encoder.setVertexBuffer(
                    jointBuffer, offset: byteOffset, index: ResourceIndices.jointMatricesBuffer)
            }
        }

        // Zero morph weights (GPU compute already applied morphs)
        if !primitive.morphTargets.isEmpty {
            encoder.setVertexBytes(
                Self.zeroMorphWeights,
                length: Self.zeroMorphWeights.count * MemoryLayout<Float>.size,
                index: ResourceIndices.morphWeightsBuffer)
        }
        encoder.setVertexBytes(
            &currentVertexOffset, length: MemoryLayout<UInt32>.size,
            index: ResourceIndices.vertexOffsetBuffer)

        if let materialIndex = primitive.materialIndex, materialIndex != lastMaterialId {
            lastMaterialId = materialIndex
        }

        // Build base MToon uniforms (color factors, alpha mode, outline settings)
        var mtoonUniforms = buildMaterialUniforms(
            for: item, model: model, materialAlphaMode: materialAlphaMode)

        // Bind fragment textures (each with its own sampler) and set the
        // presence flags.
        if let materialIndex = primitive.materialIndex, materialIndex < model.materials.count {
            bindMaterialTextures(model.materials[materialIndex], model: model, uniforms: &mtoonUniforms, encoder: encoder)
        }

        applyDepthCullState(
            for: item, encoder: encoder, materialAlphaMode: materialAlphaMode,
            isDoubleSided: isDoubleSided)

        // MARK: Indexed draw path
        if let indexBuffer = primitive.indexBuffer {
            if config.strict != .off {
                do {
                    try strictValidator?.recordDrawCall(
                        vertexCount: primitive.vertexCount,
                        indexCount: primitive.indexCount,
                        primitiveIndex: item.meshIndex
                    )
                } catch {
                    if config.strict == .fail { encoder.endEncoding() }
                    return
                }
            }

            // Expression-driven material color overrides
            if let materialIndex = primitive.materialIndex {
                let ec = expressionController
                if let c = ec?.getMaterialColorOverride(materialIndex: materialIndex, type: .color) {
                    mtoonUniforms.baseColorFactor = c
                }
                if let c = ec?.getMaterialColorOverride(
                    materialIndex: materialIndex, type: .emissionColor) {
                    mtoonUniforms.emissiveFactor = SIMD3<Float>(c.x, c.y, c.z)
                }
                if let c = ec?.getMaterialColorOverride(
                    materialIndex: materialIndex, type: .shadeColor) {
                    mtoonUniforms.shadeColorFactor = SIMD3<Float>(c.x, c.y, c.z)
                }
                if let c = ec?.getMaterialColorOverride(
                    materialIndex: materialIndex, type: .matcapColor) {
                    mtoonUniforms.matcapFactor = SIMD3<Float>(c.x, c.y, c.z)
                }
                if let c = ec?.getMaterialColorOverride(
                    materialIndex: materialIndex, type: .rimColor) {
                    mtoonUniforms.parametricRimColorFactor = SIMD3<Float>(c.x, c.y, c.z)
                }
                if let c = ec?.getMaterialColorOverride(
                    materialIndex: materialIndex, type: .outlineColor) {
                    mtoonUniforms.outlineColorFactor = SIMD3<Float>(c.x, c.y, c.z)
                }
            }

            encoder.setVertexBytes(
                &mtoonUniforms, length: MemoryLayout<MToonMaterialUniforms>.stride, index: 8)
            encoder.setFragmentBytes(
                &mtoonUniforms, length: MemoryLayout<MToonMaterialUniforms>.stride, index: 8)
            if isSkinned {
                encoder.setFragmentBuffer(uniformsBuffer, offset: 0, index: 1)
            } else {
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 1)
            }

            // Matrix slice validation
            if isSkinned,
                let skinIndex = item.node.skin ?? (primitive.hasJoints ? Optional(0) : nil),
                skinIndex >= 0 && skinIndex < model.skins.count {
                let skin = model.skins[skinIndex]
                assert(
                    skinningSystem?.getJointMatricesBuffer() != nil,
                    "[MATRIX SLICE] Joint buffer is nil for skinned draw!")
                let totalMatrices = skinningSystem?.getTotalMatrixCount() ?? 0
                assert(
                    skin.matrixOffset + skin.joints.count <= totalMatrices,
                    "[MATRIX SLICE] Out of bounds! offset=\(skin.matrixOffset) + count=\(skin.joints.count) > total=\(totalMatrices)"
                )
            }

            // Re-bind is not needed if we didn't change it, but since we modify mtoonUniforms above,
            // we do need to re-bind. However, we already did it at line 241/243.
            // Let's just do it ONCE after all overrides.

            // Index buffer guardrails
            let indexBufferSize = indexBuffer.length
            let indexTypeSize = primitive.indexType == MTLIndexType.uint16 ? 2 : 4
            let requiredSize = primitive.indexBufferOffset + (primitive.indexCount * indexTypeSize)
            precondition(
                primitive.indexBufferOffset < indexBufferSize,
                "[INDEX GUARDRAIL] indexBufferOffset \(primitive.indexBufferOffset) >= buffer size \(indexBufferSize)"
            )
            precondition(
                requiredSize <= indexBufferSize,
                "[INDEX GUARDRAIL] Required size \(requiredSize) > buffer size \(indexBufferSize)")
            precondition(
                primitive.indexCount > 0,
                "[INDEX GUARDRAIL] indexCount must be > 0, got \(primitive.indexCount)")
            precondition(
                primitive.indexBufferOffset % indexTypeSize == 0,
                "[INDEX GUARDRAIL] indexBufferOffset \(primitive.indexBufferOffset) not aligned to \(indexTypeSize) bytes"
            )

            // Skin/palette compatibility
            if let skinIndex = item.node.skin, skinIndex < model.skins.count {
                let skin = model.skins[skinIndex]
                let required = prim.requiredPaletteSize
                if required > skin.joints.count {
                    preconditionFailure(
                        "[SKIN MISMATCH] Node '\(item.node.name ?? "?")' mesh '\(meshName)' prim \(meshPrimIndex):\n"
                            + "  Primitive needs ≥\(required) joints, skin '\(skin.name ?? "?")' has \(skin.joints.count)"
                    )
                }
                if let vb = prim.vertexBuffer, prim.hasJoints {
                    let verts = vb.contents().bindMemory(
                        to: VRMVertex.self, capacity: min(10, prim.vertexCount))
                    var sampleMaxJoint: UInt32 = 0
                    for i in 0..<min(10, prim.vertexCount) {
                        let v = verts[i]
                        sampleMaxJoint = max(
                            sampleMaxJoint, v.joints.x, v.joints.y, v.joints.z, v.joints.w)
                    }
                    if Int(sampleMaxJoint) >= skin.joints.count {
                        preconditionFailure(
                            "[SKIN MISMATCH] Node '\(item.node.name ?? "?")' mesh '\(meshName)' prim \(meshPrimIndex):\n"
                                + "  maxJoint=\(sampleMaxJoint) >= paletteCount=\(skin.joints.count)"
                        )
                    }
                }
            }

            encoder.drawIndexedPrimitives(
                type: primitive.primitiveType,
                indexCount: primitive.indexCount,
                indexType: primitive.indexType,
                indexBuffer: indexBuffer,
                indexBufferOffset: primitive.indexBufferOffset
            )
        } else {
            // MARK: Non-indexed draw path
            if config.strict != .off {
                do {
                    try strictValidator?.recordDrawCall(
                        vertexCount: primitive.vertexCount,
                        indexCount: 0,
                        primitiveIndex: item.meshIndex
                    )
                } catch {
                    if config.strict == .fail { encoder.endEncoding() }
                    return
                }
            }

            encoder.setVertexBytes(
                &mtoonUniforms, length: MemoryLayout<MToonMaterialUniforms>.stride, index: 8)
            encoder.setFragmentBytes(
                &mtoonUniforms, length: MemoryLayout<MToonMaterialUniforms>.stride, index: 8)
            encoder.setFragmentBuffer(uniformsBuffer, offset: 0, index: 1)

            encoder.drawPrimitives(
                type: primitive.primitiveType,
                vertexStart: 0,
                vertexCount: primitive.vertexCount
            )
        }
    }
}
