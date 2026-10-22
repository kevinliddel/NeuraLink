//
//  VRMRenderer+Outline.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import Metal
import simd

// MARK: - MToon Outline Rendering

extension VRMRenderer {

    /// Inverted-hull outlines for `renderItems`. Opaque and cutout outlines
    /// draw right after the opaque surfaces with depth writes on, so a
    /// transparent surface behind them is hidden as it is behind the surface;
    /// transparent materials' outlines draw last without writing depth.
    /// The encoder's cached state is reset afterwards: this pass binds its
    /// own pipeline, textures and depth state.
    func renderMToonOutlines(
        encoder: MTLRenderCommandEncoder,
        renderItems: [RenderItem],
        model: VRMModel,
        morphedBuffers: [MorphKey: MTLBuffer],
        writesDepth: Bool
    ) {
        defer { resetEncoderStateCache() }
        guard mtoonOutlinePipelineState != nil || mtoonSkinnedOutlinePipelineState != nil else {
            return
        }
        guard self.outlineWidth > 0 else { return }

        let hasSkinning = !model.skins.isEmpty

        encoder.setCullMode(.front)
        encoder.setFrontFacing(.counterClockwise)

        if let outlineDepthState = depthStencilStates[writesDepth ? "opaque" : "blend"] {
            encoder.setDepthStencilState(outlineDepthState)
        }

        encoder.setDepthBias(0.0, slopeScale: 0.0, clamp: 0.0)

        for item in renderItems {
            let primitive = item.primitive

            guard let materialIndex = primitive.materialIndex,
                materialIndex < model.materials.count
            else {
                continue
            }

            let material = model.materials[materialIndex]

            guard let mtoon = material.mtoon,
                mtoon.outlineWidthMode != .none,
                mtoon.outlineWidthFactor > 0.0001
            else {
                continue
            }

            guard let vertexBuffer = primitive.vertexBuffer,
                let indexBuffer = primitive.indexBuffer
            else {
                continue
            }

            let nodeHasSkin = item.node.skin != nil && hasSkinning
            let meshUsesSkinning = primitive.hasJoints && primitive.hasWeights
            let isSkinned = (nodeHasSkin || meshUsesSkinning) && hasSkinning

            let outlinePipeline: MTLRenderPipelineState? =
                isSkinned
                ? mtoonSkinnedOutlinePipelineState
                : mtoonOutlinePipelineState

            guard let pipeline = outlinePipeline else { continue }

            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(uniformsBuffers[currentUniformBufferIndex], offset: 0, index: 1)

            var mtoonUniforms = MToonMaterialUniforms(from: mtoon)
            mtoonUniforms.baseColorFactor = material.baseColorFactor
            mtoonUniforms.vrmVersion = material.vrmVersion == .v0_0 ? 0 : 1
            mtoonUniforms.outlineWidthFactor *= self.outlineWidth / 0.02
            // The fragment lights the outline with the surface's colour.
            mtoonUniforms.hasShadeMultiplyTexture = mtoon.shadeMultiplyTexture != nil ? 1 : 0

            // The hull must honor the same alpha cutout as the main pass.
            // VRoid hides unused outfit geometry (long skirts, pant legs) with
            // alpha-0 texels under MASK; the main pass discards them and writes
            // no depth, so an outline hull without cutout paints them as solid
            // outline-colored panels.
            switch item.effectiveAlphaMode {
            case "mask":
                mtoonUniforms.alphaMode = 1
                mtoonUniforms.alphaCutoff = item.effectiveAlphaCutoff
            case "blend":
                mtoonUniforms.alphaMode = 2
            default:
                mtoonUniforms.alphaMode = 0
            }
            if let baseTexture = material.baseColorTexture?.mtlTexture {
                mtoonUniforms.hasBaseColorTexture = 1
                encoder.setFragmentTexture(baseTexture, index: 0)
            } else {
                mtoonUniforms.hasBaseColorTexture = 0
                encoder.setFragmentTexture(nil, index: 0)
            }
            // Width-multiply texture: bind it, or clear the flag. The vertex
            // shader multiplies the width by the sample, so a set flag with
            // no bound texture zeroed the outline on those materials.
            if let widthIndex = mtoon.outlineWidthMultiplyTexture,
               widthIndex < model.textures.count,
               let widthTexture = model.textures[widthIndex].mtlTexture {
                mtoonUniforms.hasOutlineWidthMultiplyTexture = 1
                encoder.setVertexTexture(widthTexture, index: 0)
            } else {
                mtoonUniforms.hasOutlineWidthMultiplyTexture = 0
            }
            if let sampler = samplerStates["default"] {
                encoder.setFragmentSamplerState(sampler, index: 0)
                encoder.setVertexSamplerState(sampler, index: 0)
            }

            let globalColor = self.outlineColor
            if globalColor.x > 0 || globalColor.y > 0 || globalColor.z > 0 {
                mtoonUniforms.outlineColorFactor = globalColor
            }

            if let outlineOverride = expressionController?.getMaterialColorOverride(
                materialIndex: materialIndex, type: .outlineColor) {
                mtoonUniforms.outlineColorFactor = SIMD3<Float>(
                    outlineOverride.x, outlineOverride.y, outlineOverride.z)
            }

            encoder.setVertexBytes(
                &mtoonUniforms, length: MemoryLayout<MToonMaterialUniforms>.stride, index: 8)
            encoder.setFragmentBytes(
                &mtoonUniforms, length: MemoryLayout<MToonMaterialUniforms>.stride, index: 8)

            if isSkinned {
                bindMorphedPositions(for: item, morphedBuffers: morphedBuffers, encoder: encoder)
            }
            if isSkinned, let skinIndex = item.node.skin, skinIndex < model.skins.count {
                let skin = model.skins[skinIndex]
                if let jointBuffer = skinningSystem?.getJointMatricesBuffer() {
                    let byteOffset = skin.matrixOffset * MemoryLayout<float4x4>.stride
                    encoder.setVertexBuffer(
                        jointBuffer, offset: byteOffset, index: ResourceIndices.jointMatricesBuffer)
                }
            }

            encoder.drawIndexedPrimitives(
                type: primitive.primitiveType,
                indexCount: primitive.indexCount,
                indexType: primitive.indexType,
                indexBuffer: indexBuffer,
                indexBufferOffset: 0
            )
        }

        encoder.setCullMode(.back)
        encoder.setDepthBias(0.0, slopeScale: 0.0, clamp: 0.0)

        if let opaqueState = depthStencilStates["opaque"] {
            encoder.setDepthStencilState(opaqueState)
        }
    }

    /// The hull starts from the same morphed positions as the surface, so
    /// mouth and eye outlines follow expressions.
    private func bindMorphedPositions(
        for item: RenderItem, morphedBuffers: [MorphKey: MTLBuffer], encoder: MTLRenderCommandEncoder
    ) {
        let key: MorphKey = (UInt64(item.meshIndex) << 32) | UInt64(item.primIdxInMesh)
        var hasMorphed: UInt32 = 0
        if let morphed = morphedBuffers[key] {
            encoder.setVertexBuffer(morphed, offset: 0, index: ResourceIndices.morphedPositionsBuffer)
            hasMorphed = 1
        } else {
            if emptyFloat3Buffer == nil {
                emptyFloat3Buffer = device.makeBuffer(
                    length: MemoryLayout<SIMD3<Float>>.stride, options: .storageModeShared)
            }
            encoder.setVertexBuffer(emptyFloat3Buffer, offset: 0, index: ResourceIndices.morphedPositionsBuffer)
        }
        encoder.setVertexBytes(
            &hasMorphed, length: MemoryLayout<UInt32>.size, index: ResourceIndices.hasMorphedPositionsFlag)
    }

    /// Forget what the item loop believes is bound; the next draw rebinds.
    func resetEncoderStateCache() {
        lastPipelineState = nil
        lastDepthStencilState = nil
        lastCullMode = nil
        lastFrontFacing = nil
        lastDepthBias = nil
        lastTextureIds.removeAll(keepingCapacity: true)
    }
}
