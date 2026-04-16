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
        let materialAlphaMode = item.effectiveAlphaMode
        let isDoubleSided = item.effectiveDoubleSided
        let meshUsesSkinning = primitive.hasJoints && primitive.hasWeights
        let isSkinned = ((item.node.skin != nil) || meshUsesSkinning) && hasSkinning

        encoder.setRenderPipelineState(pipeline)

        #if os(macOS)
            if debugWireframe { encoder.setTriangleFillMode(.lines) }
        #endif

        if lastPipelineState !== pipeline { lastPipelineState = pipeline }

        // Model matrix: VRM 1.0 faces +Z, rotate 180° Y to face camera at -Z
        let vrmRotation = vrmVersionRotation
        if isSkinned {
            uniforms.modelMatrix = vrmRotation
            uniforms.normalMatrix = vrmRotation
        } else {
            uniforms.modelMatrix = simd_mul(vrmRotation, item.node.worldMatrix)
            uniforms.normalMatrix = uniforms.modelMatrix.inverse.transpose
        }
        uniformsBuffer.contents().copyMemory(
            from: &uniforms, byteCount: MemoryLayout<Uniforms>.size)

        guard let vertexBuffer = primitive.vertexBuffer else { return }

        var currentVertexOffset: UInt32 = 0

        // Morph buffer binding
        let stableKey: MorphKey = (UInt64(item.meshIndex) << 32) | UInt64(item.primIdxInMesh)
        let morphedPosBuffer = morphedBuffers[stableKey]

        if let morphedPosBuffer {
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: ResourceIndices.vertexBuffer)
            encoder.setVertexBuffer(
                morphedPosBuffer, offset: 0, index: ResourceIndices.morphedPositionsBuffer)
            var hasMorphedFlag: UInt32 = 1
            encoder.setVertexBytes(
                &hasMorphedFlag, length: MemoryLayout<UInt32>.size,
                index: ResourceIndices.hasMorphedPositionsFlag)
        } else {
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: ResourceIndices.vertexBuffer)
            if emptyFloat3Buffer == nil {
                emptyFloat3Buffer = device.makeBuffer(
                    length: MemoryLayout<SIMD3<Float>>.stride, options: .storageModeShared)
            }
            encoder.setVertexBuffer(
                emptyFloat3Buffer, offset: 0, index: ResourceIndices.morphedPositionsBuffer)
            var hasMorphedFlag: UInt32 = 0
            encoder.setVertexBytes(
                &hasMorphedFlag, length: MemoryLayout<UInt32>.size,
                index: ResourceIndices.hasMorphedPositionsFlag)
        }

        encoder.setVertexBuffer(uniformsBuffer, offset: 0, index: ResourceIndices.uniformsBuffer)

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
                let jointBuffer = skinningSystem?.getJointMatricesBuffer()
            {
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

        // Build base MToon uniforms (color factors, face category, outline settings)
        var mtoonUniforms = buildMaterialUniforms(
            for: item, model: model, materialAlphaMode: materialAlphaMode)

        // Bind fragment textures and update presence flags
        if let materialIndex = primitive.materialIndex, materialIndex < model.materials.count {
            let material = model.materials[materialIndex]

            if let mtlTexture = material.baseColorTexture?.mtlTexture {
                encoder.setFragmentTexture(mtlTexture, index: 0)
                mtoonUniforms.hasBaseColorTexture = 1
            }

            if let mtoon = material.mtoon {
                if let textureIndex = mtoon.shadeMultiplyTexture,
                    textureIndex < model.textures.count,
                    let mtlTexture = model.textures[textureIndex].mtlTexture
                {
                    encoder.setFragmentTexture(mtlTexture, index: 1)
                    mtoonUniforms.hasShadeMultiplyTexture = 1
                } else {
                    encoder.setFragmentTexture(nil, index: 1)
                    mtoonUniforms.hasShadeMultiplyTexture = 0
                }
            }

            if let mtoon = material.mtoon,
                let shadingShift = mtoon.shadingShiftTexture,
                shadingShift.index < model.textures.count,
                let mtlTexture = model.textures[shadingShift.index].mtlTexture
            {
                encoder.setFragmentTexture(mtlTexture, index: 2)
                mtoonUniforms.hasShadingShiftTexture = 1
                mtoonUniforms.shadingShiftTextureScale = shadingShift.scale ?? 1.0
            }

            if let mtlTexture = material.normalTexture?.mtlTexture {
                encoder.setFragmentTexture(mtlTexture, index: 3)
                mtoonUniforms.hasNormalTexture = 1
            }

            if let mtlTexture = material.emissiveTexture?.mtlTexture {
                encoder.setFragmentTexture(mtlTexture, index: 4)
                mtoonUniforms.hasEmissiveTexture = 1
            }

            if let mtoon = material.mtoon,
                let textureIndex = mtoon.matcapTexture,
                textureIndex < model.textures.count,
                let mtlTexture = model.textures[textureIndex].mtlTexture
            {
                encoder.setFragmentTexture(mtlTexture, index: 5)
                mtoonUniforms.hasMatcapTexture = 1
            }

            if let mtoon = material.mtoon,
                let textureIndex = mtoon.rimMultiplyTexture,
                textureIndex < model.textures.count,
                let mtlTexture = model.textures[textureIndex].mtlTexture
            {
                encoder.setFragmentTexture(mtlTexture, index: 6)
                mtoonUniforms.hasRimMultiplyTexture = 1
            }

            if let mtoon = material.mtoon,
                let textureIndex = mtoon.uvAnimationMaskTexture,
                textureIndex < model.textures.count,
                let mtlTexture = model.textures[textureIndex].mtlTexture
            {
                encoder.setFragmentTexture(mtlTexture, index: 7)
                mtoonUniforms.hasUvAnimationMaskTexture = 1
            }

            if let cachedSampler = samplerStates["default"] {
                encoder.setFragmentSamplerState(cachedSampler, index: 0)
            }
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
                if let c = ec?.getMaterialColorOverride(materialIndex: materialIndex, type: .color)
                {
                    mtoonUniforms.baseColorFactor = c
                }
                if let c = ec?.getMaterialColorOverride(
                    materialIndex: materialIndex, type: .emissionColor)
                {
                    mtoonUniforms.emissiveFactor = SIMD3<Float>(c.x, c.y, c.z)
                }
                if let c = ec?.getMaterialColorOverride(
                    materialIndex: materialIndex, type: .shadeColor)
                {
                    mtoonUniforms.shadeColorFactor = SIMD3<Float>(c.x, c.y, c.z)
                }
                if let c = ec?.getMaterialColorOverride(
                    materialIndex: materialIndex, type: .matcapColor)
                {
                    mtoonUniforms.matcapFactor = SIMD3<Float>(c.x, c.y, c.z)
                }
                if let c = ec?.getMaterialColorOverride(
                    materialIndex: materialIndex, type: .rimColor)
                {
                    mtoonUniforms.parametricRimColorFactor = SIMD3<Float>(c.x, c.y, c.z)
                }
                if let c = ec?.getMaterialColorOverride(
                    materialIndex: materialIndex, type: .outlineColor)
                {
                    mtoonUniforms.outlineColorFactor = SIMD3<Float>(c.x, c.y, c.z)
                }
            }

            encoder.setVertexBytes(
                &mtoonUniforms, length: MemoryLayout<MToonMaterialUniforms>.stride, index: 8)
            encoder.setFragmentBytes(
                &mtoonUniforms, length: MemoryLayout<MToonMaterialUniforms>.stride, index: 8)
            encoder.setFragmentBuffer(uniformsBuffer, offset: 0, index: 1)

            // Matrix slice validation
            if isSkinned,
                let skinIndex = item.node.skin ?? (primitive.hasJoints ? Optional(0) : nil),
                skinIndex >= 0 && skinIndex < model.skins.count
            {
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

            // CRITICAL: Re-bind fragment uniforms after overrides
            var materialUniforms = mtoonUniforms
            encoder.setFragmentBytes(
                &materialUniforms, length: MemoryLayout<MToonMaterialUniforms>.stride, index: 8)

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
