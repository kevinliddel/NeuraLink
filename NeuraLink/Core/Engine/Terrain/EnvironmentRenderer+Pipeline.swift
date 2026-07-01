//
//  EnvironmentRenderer+Pipeline.swift
//  NeuraLink
//
//  Metal pipeline, depth-state, uniform-buffer and fallback-texture setup for
//  the environment renderer. Split out of EnvironmentRenderer+Load.swift to
//  keep each file within the SwiftLint length limit.
//
//  Created by Dedicatus on 01/07/2026.
//

import Foundation
import Metal
import simd

extension EnvironmentRenderer {

    // MARK: - Setup

    func setup(config: RendererConfig) {
        setupDepthState()
        setupPipelines(config: config)
        setupUniformBuffers()
        setupFallbackTexture()
    }

    private func setupDepthState() {
        let desc = MTLDepthStencilDescriptor()
        desc.depthCompareFunction = .less
        desc.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: desc)

        // Blend pass: depth test enabled, depth write disabled so transparent
        // surfaces don't occlude geometry behind them.
        let blendDesc = MTLDepthStencilDescriptor()
        blendDesc.depthCompareFunction = .less
        blendDesc.isDepthWriteEnabled = false
        blendDepthState = device.makeDepthStencilState(descriptor: blendDesc)
    }

    private func setupPipelines(config: RendererConfig) {
        guard let lib = try? VRMPipelineCache.shared.getLibrary(device: device),
            let shadowVert = lib.makeFunction(name: "city_shadow_vertex"),
            let mainVert = lib.makeFunction(name: "city_vertex"),
            let mainFrag = lib.makeFunction(name: "city_fragment")
        else {
            nlLog("[EnvironmentRenderer] Shader functions not found")
            return
        }

        let posOff = MemoryLayout<CityVertex>.offset(of: \.position)!
        let norOff = MemoryLayout<CityVertex>.offset(of: \.normal)!
        let texOff = MemoryLayout<CityVertex>.offset(of: \.texCoord)!
        let colorOff = MemoryLayout<CityVertex>.offset(of: \.color)!
        let stride = MemoryLayout<CityVertex>.stride

        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3
        vd.attributes[0].offset = posOff
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float3
        vd.attributes[1].offset = norOff
        vd.attributes[1].bufferIndex = 0
        vd.attributes[2].format = .float2
        vd.attributes[2].offset = texOff
        vd.attributes[2].bufferIndex = 0
        vd.attributes[3].format = .float4
        vd.attributes[3].offset = colorOff
        vd.attributes[3].bufferIndex = 0
        vd.layouts[0].stride = stride

        let shadowVD = MTLVertexDescriptor()
        shadowVD.attributes[0].format = .float3
        shadowVD.attributes[0].offset = posOff
        shadowVD.attributes[0].bufferIndex = 0
        shadowVD.layouts[0].stride = stride

        let shadowDesc = MTLRenderPipelineDescriptor()
        shadowDesc.label = "city_shadow"
        shadowDesc.vertexFunction = shadowVert
        shadowDesc.vertexDescriptor = shadowVD
        shadowDesc.depthAttachmentPixelFormat = .depth32Float

        let mainDesc = MTLRenderPipelineDescriptor()
        mainDesc.label = "city_main"
        mainDesc.vertexFunction = mainVert
        mainDesc.fragmentFunction = mainFrag
        mainDesc.vertexDescriptor = vd
        mainDesc.colorAttachments[0].pixelFormat = config.colorPixelFormat
        mainDesc.colorAttachments[0].isBlendingEnabled = false
        mainDesc.depthAttachmentPixelFormat = .depth32Float
        mainDesc.rasterSampleCount = config.sampleCount

        let blendDesc = MTLRenderPipelineDescriptor()
        blendDesc.label = "city_blend"
        blendDesc.vertexFunction = mainVert
        blendDesc.fragmentFunction = mainFrag
        blendDesc.vertexDescriptor = vd
        blendDesc.colorAttachments[0].pixelFormat = config.colorPixelFormat
        blendDesc.colorAttachments[0].isBlendingEnabled = true
        blendDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        blendDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        blendDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        blendDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        blendDesc.depthAttachmentPixelFormat = .depth32Float
        blendDesc.rasterSampleCount = config.sampleCount

        do {
            shadowPipeline = try VRMPipelineCache.shared.getPipelineState(
                device: device, descriptor: shadowDesc, key: "city_shadow_v2")
            mainPipeline = try VRMPipelineCache.shared.getPipelineState(
                device: device, descriptor: mainDesc, key: "city_main_v3")
            blendPipeline = try VRMPipelineCache.shared.getPipelineState(
                device: device, descriptor: blendDesc, key: "city_blend_v1")
        } catch {
            nlLog("[EnvironmentRenderer] Pipeline creation failed: \(error)")
        }
    }

    private func setupUniformBuffers() {
        uniformsBuffer = device.makeBuffer(
            length: MemoryLayout<CityUniforms>.stride, options: .storageModeShared)
        uniformsBuffer?.label = "CityUniforms"
        shadowUniformsBuffer = device.makeBuffer(
            length: MemoryLayout<CityShadowUniforms>.stride, options: .storageModeShared)
        shadowUniformsBuffer?.label = "CityShadowUniforms"
    }

    private func setupFallbackTexture() {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        var pixel: UInt32 = 0xFFFF_FFFF
        tex.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
        fallbackTexture = tex
    }
}
