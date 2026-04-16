//
// VRMRenderer+SkinnedPipeline.swift
// NeuraLink
//
// Created by Dedicatus on 14/04/2026.
//

import Foundation
@preconcurrency import Metal
import MetalKit
import simd

// MARK: - Skinned + Sprite Pipeline Setup

extension VRMRenderer {
    func setupSkinnedPipeline() {
        do {
            let library = try VRMPipelineCache.shared.getLibrary(device: device)

            let skinnedVertexFunction = library.makeFunction(name: "skinned_mtoon_vertex")
            try strictValidator?.validateFunction(
                skinnedVertexFunction, name: "skinned_mtoon_vertex", type: "vertex")
            guard let skinnedVertexFunc = skinnedVertexFunction else {
                if config.strict == .off { return }
                throw StrictModeError.missingVertexFunction(name: "skinned_mtoon_vertex")
            }

            let fragmentFunction = library.makeFunction(name: "mtoon_fragment_v2")
            try strictValidator?.validateFunction(
                fragmentFunction, name: "mtoon_fragment_v2", type: "fragment")
            guard let fragmentFunc = fragmentFunction else {
                if config.strict == .off { return }
                throw StrictModeError.missingFragmentFunction(name: "mtoon_fragment_v2")
            }

            let vertexDescriptor = MTLVertexDescriptor()

            let posOffset = MemoryLayout<VRMVertex>.offset(of: \.position)!
            let normOffset = MemoryLayout<VRMVertex>.offset(of: \.normal)!
            let texOffset = MemoryLayout<VRMVertex>.offset(of: \.texCoord)!
            let colorOffset = MemoryLayout<VRMVertex>.offset(of: \.color)!
            let jointsOffset = MemoryLayout<VRMVertex>.offset(of: \.joints)!
            let weightsOffset = MemoryLayout<VRMVertex>.offset(of: \.weights)!
            let stride = MemoryLayout<VRMVertex>.stride

            vertexDescriptor.attributes[0].format = .float3
            vertexDescriptor.attributes[0].offset = posOffset
            vertexDescriptor.attributes[0].bufferIndex = 0
            vertexDescriptor.attributes[1].format = .float3
            vertexDescriptor.attributes[1].offset = normOffset
            vertexDescriptor.attributes[1].bufferIndex = 0
            vertexDescriptor.attributes[2].format = .float2
            vertexDescriptor.attributes[2].offset = texOffset
            vertexDescriptor.attributes[2].bufferIndex = 0
            vertexDescriptor.attributes[3].format = .float4
            vertexDescriptor.attributes[3].offset = colorOffset
            vertexDescriptor.attributes[3].bufferIndex = 0
            vertexDescriptor.attributes[4].format = .uint4
            vertexDescriptor.attributes[4].offset = jointsOffset
            vertexDescriptor.attributes[4].bufferIndex = 0
            vertexDescriptor.attributes[5].format = .float4
            vertexDescriptor.attributes[5].offset = weightsOffset
            vertexDescriptor.attributes[5].bufferIndex = 0
            vertexDescriptor.layouts[0].stride = stride

            let basePipelineDescriptor = MTLRenderPipelineDescriptor()
            basePipelineDescriptor.vertexFunction = skinnedVertexFunc
            basePipelineDescriptor.fragmentFunction = fragmentFunc
            basePipelineDescriptor.vertexDescriptor = vertexDescriptor
            basePipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
            basePipelineDescriptor.rasterSampleCount = config.sampleCount

            // SKINNED OPAQUE/MASK
            let skinnedOpaqueDescriptor =
                basePipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            skinnedOpaqueDescriptor.label = "mtoon_skinned_opaque"
            skinnedOpaqueDescriptor.colorAttachments[0]?.pixelFormat = config.colorPixelFormat
            skinnedOpaqueDescriptor.colorAttachments[0]?.isBlendingEnabled = false
            let skinnedOpaqueState = try VRMPipelineCache.shared.getPipelineState(
                device: device, descriptor: skinnedOpaqueDescriptor, key: "mtoon_skinned_opaque")
            try strictValidator?.validatePipelineState(
                skinnedOpaqueState, name: "skinned_opaque_pipeline")
            skinnedOpaquePipelineState = skinnedOpaqueState

            // SKINNED BLEND
            let skinnedBlendDescriptor =
                basePipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            skinnedBlendDescriptor.label = "mtoon_skinned_blend"
            let skinnedBlendCA = skinnedBlendDescriptor.colorAttachments[0]
            skinnedBlendCA?.pixelFormat = config.colorPixelFormat
            skinnedBlendCA?.isBlendingEnabled = true
            skinnedBlendCA?.sourceRGBBlendFactor = .sourceAlpha
            skinnedBlendCA?.destinationRGBBlendFactor = .oneMinusSourceAlpha
            skinnedBlendCA?.rgbBlendOperation = .add
            skinnedBlendCA?.sourceAlphaBlendFactor = .sourceAlpha
            skinnedBlendCA?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            skinnedBlendCA?.alphaBlendOperation = .add
            let skinnedBlendState = try VRMPipelineCache.shared.getPipelineState(
                device: device, descriptor: skinnedBlendDescriptor, key: "mtoon_skinned_blend")
            try strictValidator?.validatePipelineState(
                skinnedBlendState, name: "skinned_blend_pipeline")
            skinnedBlendPipelineState = skinnedBlendState

            // SKINNED MASK A2C
            let skinnedMaskA2CDescriptor =
                basePipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            skinnedMaskA2CDescriptor.label = "mtoon_skinned_mask_a2c"
            skinnedMaskA2CDescriptor.isAlphaToCoverageEnabled = true
            skinnedMaskA2CDescriptor.colorAttachments[0]?.pixelFormat = config.colorPixelFormat
            skinnedMaskA2CDescriptor.colorAttachments[0]?.isBlendingEnabled = false
            let skinnedMaskA2CState = try VRMPipelineCache.shared.getPipelineState(
                device: device, descriptor: skinnedMaskA2CDescriptor, key: "mtoon_skinned_mask_a2c")
            try strictValidator?.validatePipelineState(
                skinnedMaskA2CState, name: "skinned_mask_a2c_pipeline")
            skinnedMaskAlphaToCoveragePipelineState = skinnedMaskA2CState

            // SKINNED OUTLINE
            let skinnedOutlineVertexFunction = library.makeFunction(
                name: "skinned_mtoon_outline_vertex")
            let skinnedOutlineFragmentFunction = library.makeFunction(
                name: "mtoon_outline_fragment")
            if let skinnedOutlineVertexFunc = skinnedOutlineVertexFunction,
                let skinnedOutlineFragmentFunc = skinnedOutlineFragmentFunction
            {
                let skinnedOutlineDescriptor = MTLRenderPipelineDescriptor()
                skinnedOutlineDescriptor.label = "mtoon_skinned_outline"
                skinnedOutlineDescriptor.vertexFunction = skinnedOutlineVertexFunc
                skinnedOutlineDescriptor.fragmentFunction = skinnedOutlineFragmentFunc
                skinnedOutlineDescriptor.vertexDescriptor = vertexDescriptor
                skinnedOutlineDescriptor.depthAttachmentPixelFormat = .depth32Float
                skinnedOutlineDescriptor.rasterSampleCount = config.sampleCount
                skinnedOutlineDescriptor.colorAttachments[0]?.pixelFormat = config.colorPixelFormat
                skinnedOutlineDescriptor.colorAttachments[0]?.isBlendingEnabled = false
                let skinnedOutlineState = try VRMPipelineCache.shared.getPipelineState(
                    device: device, descriptor: skinnedOutlineDescriptor,
                    key: "mtoon_skinned_outline")
                mtoonSkinnedOutlinePipelineState = skinnedOutlineState
            }
        } catch {
            if config.strict == .fail {
                do {
                    try strictValidator?.handle(.pipelineCreationFailed(error.localizedDescription))
                } catch {}
            }
        }
    }

    // MARK: - Sprite Rendering Pipeline Setup

    func setupSpritePipeline() {
        do {
            let library = try VRMPipelineCache.shared.getLibrary(device: device)

            guard let vertexFunction = library.makeFunction(name: "sprite_vertex"),
                let fragmentFunction = library.makeFunction(name: "sprite_fragment")
            else { return }

            let vertexDescriptor = MTLVertexDescriptor()
            vertexDescriptor.attributes[0].format = .float2
            vertexDescriptor.attributes[0].offset = 0
            vertexDescriptor.attributes[0].bufferIndex = 0
            vertexDescriptor.attributes[1].format = .float2
            vertexDescriptor.attributes[1].offset = MemoryLayout<Float>.stride * 2
            vertexDescriptor.attributes[1].bufferIndex = 0
            vertexDescriptor.layouts[0].stride = MemoryLayout<Float>.stride * 4
            vertexDescriptor.layouts[0].stepRate = 1
            vertexDescriptor.layouts[0].stepFunction = .perVertex

            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.label = "Sprite Pipeline"
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.vertexDescriptor = vertexDescriptor
            pipelineDescriptor.rasterSampleCount = config.sampleCount
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
            pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor =
                .oneMinusSourceAlpha
            pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
            pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

            spritePipelineState = try VRMPipelineCache.shared.getPipelineState(
                device: device, descriptor: pipelineDescriptor, key: "sprite")

            if let buffers = SpriteQuadMesh.createBuffers(device: device) {
                spriteVertexBuffer = buffers.vertexBuffer
                spriteIndexBuffer = buffers.indexBuffer
            }
        } catch {
            if config.strict == .fail {
                do {
                    try strictValidator?.handle(.pipelineCreationFailed(error.localizedDescription))
                } catch {}
            }
        }
    }
}
