//
//  VRMRenderer+Pipeline.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import Foundation
@preconcurrency import Metal
import MetalKit
import simd

extension VRMRenderer {
    func validateMaterialUniformAlignment() {
        // Calculate Swift struct size and stride
        let swiftSize = MemoryLayout<MToonMaterialUniforms>.size
        let swiftStride = MemoryLayout<MToonMaterialUniforms>.stride

        // Expected Metal struct size (11 blocks * 16 bytes = 176 bytes)
        let expectedMetalSize = 176  // 11 * 16

        // In strict mode, fail if sizes don't match
        if config.strict != .off {
            if swiftStride != expectedMetalSize {
                let message =
                    "MToonMaterialUniforms stride mismatch! Swift: \(swiftStride), Expected: \(expectedMetalSize)"
                if config.strict == .fail {
                    do {
                        try strictValidator?.handle(
                            .uniformLayoutMismatch(
                                swift: swiftStride, metal: expectedMetalSize,
                                type: "MToonMaterialUniforms"))
                    } catch {
                    }
                }
            }
        }
    }

    func setupTripleBuffering() {
        // Create triple-buffered uniform buffers with private storage for GPU efficiency
        let uniformSize = MemoryLayout<Uniforms>.size
        for _ in 0..<Self.maxBufferedFrames {
            if let buffer = device.makeBuffer(length: uniformSize, options: .storageModeShared) {
                buffer.label = "Uniform Buffer \(uniformsBuffers.count)"
                uniformsBuffers.append(buffer)
            }
        }

    }

    func setupCachedStates() {
        // Pre-create depth stencil states
        // Opaque/Mask state
        let opaqueDepthDescriptor = MTLDepthStencilDescriptor()
        opaqueDepthDescriptor.depthCompareFunction = .less
        opaqueDepthDescriptor.isDepthWriteEnabled = true
        if let state = device.makeDepthStencilState(descriptor: opaqueDepthDescriptor) {
            depthStencilStates["opaque"] = state
            depthStencilStates["mask"] = state  // Same as opaque
        }

        // Blend state (no depth write)
        let blendDepthDescriptor = MTLDepthStencilDescriptor()
        blendDepthDescriptor.depthCompareFunction = .lessEqual
        blendDepthDescriptor.isDepthWriteEnabled = false
        if let state = device.makeDepthStencilState(descriptor: blendDepthDescriptor) {
            depthStencilStates["blend"] = state
        }

        // Kill switch test state (always pass, no depth write)
        let alwaysDepthDescriptor = MTLDepthStencilDescriptor()
        alwaysDepthDescriptor.depthCompareFunction = .always  // Always pass depth test
        alwaysDepthDescriptor.isDepthWriteEnabled = false  // Don't write to depth buffer
        if let state = device.makeDepthStencilState(descriptor: alwaysDepthDescriptor) {
            depthStencilStates["always"] = state
        }

        // Face materials depth state - more permissive to avoid z-fighting
        let faceDepthDescriptor = MTLDepthStencilDescriptor()
        faceDepthDescriptor.depthCompareFunction = .lessEqual  // More permissive than .less
        faceDepthDescriptor.isDepthWriteEnabled = true
        if let state = device.makeDepthStencilState(descriptor: faceDepthDescriptor) {
            depthStencilStates["face"] = state
        }

        // Face overlay depth state - for materials that render on top of face skin (mouth, eyebrows)
        // Uses lessEqual (wins at equal depth) but doesn't write depth to avoid Z-fighting
        let faceOverlayDescriptor = MTLDepthStencilDescriptor()
        faceOverlayDescriptor.depthCompareFunction = .lessEqual
        faceOverlayDescriptor.isDepthWriteEnabled = false  // Don't write - prevents Z-fighting
        if let state = device.makeDepthStencilState(descriptor: faceOverlayDescriptor) {
            depthStencilStates["faceOverlay"] = state
        }

        // Pre-create sampler states
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .repeat
        samplerDescriptor.tAddressMode = .repeat
        samplerDescriptor.maxAnisotropy = 16
        if let sampler = device.makeSamplerState(descriptor: samplerDescriptor) {
            samplerStates["default"] = sampler
        }
    }

    func setupPipeline() {
        // Use MToon shader for proper VRM rendering

        do {
            // Load precompiled shader library (50-100x faster than runtime compilation)
            let library = try VRMPipelineCache.shared.getLibrary(device: device)

            // Validate vertex function
            let vertexFunction = library.makeFunction(name: "mtoon_vertex")
            try strictValidator?.validateFunction(
                vertexFunction, name: "mtoon_vertex", type: "vertex")
            guard let vertexFunc = vertexFunction else {
                if config.strict == .off {
                    return
                }
                throw StrictModeError.missingVertexFunction(name: "mtoon_vertex")
            }

            // Validate fragment function
            let fragmentFunction = library.makeFunction(name: "mtoon_fragment_v2")
            try strictValidator?.validateFunction(
                fragmentFunction, name: "mtoon_fragment_v2", type: "fragment")
            guard let fragmentFunc = fragmentFunction else {
                if config.strict == .off {
                    return
                }
                throw StrictModeError.missingFragmentFunction(name: "mtoon_fragment_v2")
            }

            // Create vertex descriptor
            let vertexDescriptor = MTLVertexDescriptor()

            // Use compiler-accurate offsets (fixes alignment padding issues)
            let posOffset = MemoryLayout<VRMVertex>.offset(of: \.position)!
            let normOffset = MemoryLayout<VRMVertex>.offset(of: \.normal)!
            let texOffset = MemoryLayout<VRMVertex>.offset(of: \.texCoord)!
            let colorOffset = MemoryLayout<VRMVertex>.offset(of: \.color)!
            let stride = MemoryLayout<VRMVertex>.stride

            // Position
            vertexDescriptor.attributes[0].format = .float3
            vertexDescriptor.attributes[0].offset = posOffset
            vertexDescriptor.attributes[0].bufferIndex = 0

            // Normal
            vertexDescriptor.attributes[1].format = .float3
            vertexDescriptor.attributes[1].offset = normOffset
            vertexDescriptor.attributes[1].bufferIndex = 0

            // TexCoord
            vertexDescriptor.attributes[2].format = .float2
            vertexDescriptor.attributes[2].offset = texOffset
            vertexDescriptor.attributes[2].bufferIndex = 0

            // Color
            vertexDescriptor.attributes[3].format = .float4
            vertexDescriptor.attributes[3].offset = colorOffset
            vertexDescriptor.attributes[3].bufferIndex = 0

            vertexDescriptor.layouts[0].stride = stride

            // Create base pipeline descriptor
            let basePipelineDescriptor = MTLRenderPipelineDescriptor()
            basePipelineDescriptor.vertexFunction = vertexFunc
            basePipelineDescriptor.fragmentFunction = fragmentFunc
            basePipelineDescriptor.vertexDescriptor = vertexDescriptor
            basePipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
            basePipelineDescriptor.rasterSampleCount = config.sampleCount

            // Create OPAQUE/MASK pipeline (no blending)
            let opaqueDescriptor = basePipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            opaqueDescriptor.label = "mtoon_opaque"  // Add label for debugging
            let opaqueColorAttachment = opaqueDescriptor.colorAttachments[0]
            opaqueColorAttachment?.pixelFormat = config.colorPixelFormat
            opaqueColorAttachment?.isBlendingEnabled = false

            // Use cached pipeline state for better performance
            let opaqueState = try VRMPipelineCache.shared.getPipelineState(
                device: device,
                descriptor: opaqueDescriptor,
                key: "mtoon_opaque"
            )
            try strictValidator?.validatePipelineState(opaqueState, name: "mtoon_opaque_pipeline")
            opaquePipelineState = opaqueState

            // Create BLEND pipeline (blending enabled)
            let blendDescriptor = basePipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            blendDescriptor.label = "mtoon_blend"  // Add label for debugging
            let blendColorAttachment = blendDescriptor.colorAttachments[0]
            blendColorAttachment?.pixelFormat = config.colorPixelFormat
            blendColorAttachment?.isBlendingEnabled = true
            blendColorAttachment?.sourceRGBBlendFactor = .sourceAlpha
            blendColorAttachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
            blendColorAttachment?.rgbBlendOperation = .add
            blendColorAttachment?.sourceAlphaBlendFactor = .sourceAlpha
            blendColorAttachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            blendColorAttachment?.alphaBlendOperation = .add

            // Use cached pipeline state for better performance
            let blendState = try VRMPipelineCache.shared.getPipelineState(
                device: device,
                descriptor: blendDescriptor,
                key: "mtoon_blend"
            )
            try strictValidator?.validatePipelineState(blendState, name: "mtoon_blend_pipeline")
            blendPipelineState = blendState

            // Create WIREFRAME pipeline (for debugging)
            let wireframeDescriptor = basePipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            wireframeDescriptor.label = "mtoon_wireframe"  // Add label for debugging
            let wireframeColorAttachment = wireframeDescriptor.colorAttachments[0]
            wireframeColorAttachment?.pixelFormat = config.colorPixelFormat
            wireframeColorAttachment?.isBlendingEnabled = false

            // Use cached pipeline state for better performance
            let wireframeState = try VRMPipelineCache.shared.getPipelineState(
                device: device,
                descriptor: wireframeDescriptor,
                key: "mtoon_wireframe"
            )
            try strictValidator?.validatePipelineState(
                wireframeState, name: "mtoon_wireframe_pipeline")
            wireframePipelineState = wireframeState

            // Create MASK with Alpha-to-Coverage pipeline (reduces edge aliasing)
            // This requires MSAA render target (sampleCount > 1)
            let maskA2CDescriptor = basePipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            maskA2CDescriptor.label = "mtoon_mask_a2c"
            maskA2CDescriptor.isAlphaToCoverageEnabled = true
            let maskA2CColorAttachment = maskA2CDescriptor.colorAttachments[0]
            maskA2CColorAttachment?.pixelFormat = config.colorPixelFormat
            maskA2CColorAttachment?.isBlendingEnabled = false

            let maskA2CState = try VRMPipelineCache.shared.getPipelineState(
                device: device,
                descriptor: maskA2CDescriptor,
                key: "mtoon_mask_a2c"
            )
            try strictValidator?.validatePipelineState(
                maskA2CState, name: "mtoon_mask_a2c_pipeline")
            maskAlphaToCoveragePipelineState = maskA2CState

            // Create MToon OUTLINE pipeline (inverted hull technique)
            let outlineVertexFunction = library.makeFunction(name: "mtoon_outline_vertex")
            let outlineFragmentFunction = library.makeFunction(name: "mtoon_outline_fragment")
            if let outlineVertexFunc = outlineVertexFunction,
                let outlineFragmentFunc = outlineFragmentFunction {
                let outlineDescriptor = MTLRenderPipelineDescriptor()
                outlineDescriptor.label = "mtoon_outline"
                outlineDescriptor.vertexFunction = outlineVertexFunc
                outlineDescriptor.fragmentFunction = outlineFragmentFunc
                outlineDescriptor.vertexDescriptor = vertexDescriptor
                outlineDescriptor.depthAttachmentPixelFormat = .depth32Float
                outlineDescriptor.rasterSampleCount = config.sampleCount

                let outlineColorAttachment = outlineDescriptor.colorAttachments[0]
                outlineColorAttachment?.pixelFormat = config.colorPixelFormat
                outlineColorAttachment?.isBlendingEnabled = false  // Outlines are opaque

                let outlineState = try VRMPipelineCache.shared.getPipelineState(
                    device: device,
                    descriptor: outlineDescriptor,
                    key: "mtoon_outline"
                )
                mtoonOutlinePipelineState = outlineState
            }

            let uniformSize = MemoryLayout<Uniforms>.size
            if config.strict != .off {
                try strictValidator?.validateUniformSize(
                    swift: uniformSize, metal: MetalSizeConstants.uniformsSize, type: "Uniforms")
                // Validate all uniform buffers
                for buffer in uniformsBuffers {
                    try strictValidator?.validateUniformBuffer(buffer, requiredSize: uniformSize)
                }
            }

        } catch {
            if config.strict == .fail {
                // In strict mode, propagate the error through validator
                do {
                    try strictValidator?.handle(.pipelineCreationFailed(error.localizedDescription))
                } catch {
                }
            }
        }
    }

}
