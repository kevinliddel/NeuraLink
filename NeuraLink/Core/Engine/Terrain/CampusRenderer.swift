//
//  CampusRenderer.swift
//  NeuraLink
//
//  Created by Dedicatus on 10/05/2026.
//
//  Loads and renders a single static GLB campus environment (campus.glb).

import Foundation
import Metal
import simd

// MARK: - Vertex / uniform layouts (must mirror CampusShader.metal)

struct CampusVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var texCoord: SIMD2<Float>
    var color: SIMD4<Float>  // vertex color (COLOR_0), default (1,1,1,1)
}

struct CampusUniforms {
    var viewProjection: simd_float4x4
    var lightViewProjection: simd_float4x4
    var sunDirection: SIMD4<Float>  // xyz = effective sun dir, w = sun height (signed)
    var campusParams: SIMD4<Float>  // x = shadowSoft
    var cameraPosition: SIMD4<Float>  // xyz = camera world position, w = 0
    var vrmLightViewProjection: simd_float4x4  // tight VRM shadow map projection
}

struct CampusShadowUniforms {
    var lightViewProjection: simd_float4x4
}

// MARK: - Per-primitive container

struct CampusMeshGroup {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    let indexType: MTLIndexType
    let texture: MTLTexture?
    let baseColorFactor: SIMD4<Float>
    let emissivePacked: SIMD4<Float>  // xyz = emissiveFactor, w = alphaCutoff
    let materialParams: SIMD4<Float>  // x = metallic, y = roughness
    let transform: simd_float4x4
    let isBlend: Bool
}

// MARK: - CampusRenderer

final class CampusRenderer: @unchecked Sendable {

    typealias InstanceConfig = (x: Float, y: Float, z: Float, rotY: Float, scale: Float)

    let device: MTLDevice
    var meshGroups: [CampusMeshGroup] = []
    var fallbackTexture: MTLTexture?

    var mainPipeline: MTLRenderPipelineState?
    var blendPipeline: MTLRenderPipelineState?
    var shadowPipeline: MTLRenderPipelineState?
    var depthState: MTLDepthStencilState?
    var blendDepthState: MTLDepthStencilState?
    var uniformsBuffer: MTLBuffer?
    var shadowUniformsBuffer: MTLBuffer?

    var isReady = false
    let instanceConfig: InstanceConfig

    /// True once the GLB has finished loading. Used by VRMRenderer to suppress
    /// terrain rendering while the campus environment is active.
    var isLoaded: Bool { isReady }

    init(
        device: MTLDevice, instanceConfig: InstanceConfig = (x: 0, y: 0, z: 0, rotY: 0, scale: 1.0)
    ) {
        self.device = device
        self.instanceConfig = instanceConfig
    }

    // MARK: - Shadow pass

    func drawShadow(
        commandBuffer: MTLCommandBuffer,
        shadowMap: MTLTexture,
        lightViewProjection: simd_float4x4,
        clearFirst: Bool
    ) {
        guard isReady, let pipeline = shadowPipeline,
            let ds = depthState, let shadowBuf = shadowUniformsBuffer
        else { return }

        var su = CampusShadowUniforms(lightViewProjection: lightViewProjection)
        shadowBuf.contents().copyMemory(
            from: &su, byteCount: MemoryLayout<CampusShadowUniforms>.stride)

        let passDesc = MTLRenderPassDescriptor()
        passDesc.depthAttachment.texture = shadowMap
        passDesc.depthAttachment.loadAction = clearFirst ? .clear : .load
        passDesc.depthAttachment.storeAction = .store
        passDesc.depthAttachment.clearDepth = 1.0

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            return
        }
        encoder.label = "CampusShadowPass"
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(ds)
        encoder.setCullMode(.none)
        encoder.setDepthBias(0.0, slopeScale: 2.0, clamp: 0.005)
        encoder.setVertexBuffer(shadowBuf, offset: 0, index: 1)

        for group in meshGroups where !group.isBlend {
            var transform = group.transform
            encoder.setVertexBuffer(group.vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&transform, length: MemoryLayout<simd_float4x4>.stride, index: 2)
            encoder.drawIndexedPrimitives(
                type: .triangle, indexCount: group.indexCount,
                indexType: group.indexType, indexBuffer: group.indexBuffer,
                indexBufferOffset: 0)
        }
        encoder.endEncoding()
    }

    // MARK: - Main draw

    func draw(
        encoder: MTLRenderCommandEncoder,
        viewProjection: simd_float4x4,
        lightViewProjection: simd_float4x4,
        vrmLightViewProjection: simd_float4x4,
        cameraPosition: SIMD3<Float>,
        sunDirection: SIMD3<Float>,
        sunHeight: Float,
        shadowSoft: Float,
        shadowMap: MTLTexture,
        vrmShadowMap: MTLTexture,
        shadowSampler: MTLSamplerState
    ) {
        guard isReady, let pipeline = mainPipeline,
            let ds = depthState, let uniBuf = uniformsBuffer
        else { return }

        var u = CampusUniforms(
            viewProjection: viewProjection,
            lightViewProjection: lightViewProjection,
            sunDirection: SIMD4<Float>(sunDirection.x, sunDirection.y, sunDirection.z, sunHeight),
            campusParams: SIMD4<Float>(shadowSoft, 0, 0, 0),
            cameraPosition: SIMD4<Float>(cameraPosition.x, cameraPosition.y, cameraPosition.z, 0),
            vrmLightViewProjection: vrmLightViewProjection
        )
        uniBuf.contents().copyMemory(from: &u, byteCount: MemoryLayout<CampusUniforms>.stride)

        encoder.pushDebugGroup("Campus")
        encoder.setCullMode(.none)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setVertexBuffer(uniBuf, offset: 0, index: 1)
        encoder.setFragmentBuffer(uniBuf, offset: 0, index: 1)
        encoder.setFragmentTexture(shadowMap, index: 1)
        encoder.setFragmentTexture(vrmShadowMap, index: 2)
        encoder.setFragmentSamplerState(shadowSampler, index: 0)

        func drawGroup(_ group: CampusMeshGroup) {
            var transform = group.transform
            var baseColor = group.baseColorFactor
            var emissivePacked = group.emissivePacked
            var matParams = group.materialParams
            encoder.setVertexBuffer(group.vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&transform, length: MemoryLayout<simd_float4x4>.stride, index: 2)
            encoder.setFragmentBytes(&baseColor, length: MemoryLayout<SIMD4<Float>>.size, index: 2)
            encoder.setFragmentBytes(
                &emissivePacked, length: MemoryLayout<SIMD4<Float>>.size, index: 3)
            encoder.setFragmentBytes(&matParams, length: MemoryLayout<SIMD4<Float>>.size, index: 4)
            encoder.setFragmentTexture(group.texture ?? fallbackTexture, index: 0)
            encoder.drawIndexedPrimitives(
                type: .triangle, indexCount: group.indexCount,
                indexType: group.indexType, indexBuffer: group.indexBuffer,
                indexBufferOffset: 0)
        }

        // Pass 1: opaque geometry (depth write on)
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(ds)
        for group in meshGroups where !group.isBlend { drawGroup(group) }

        // Pass 2: transparent geometry (depth test on, depth write off, blending enabled)
        if let blendPSO = blendPipeline, let blendDS = blendDepthState {
            encoder.setRenderPipelineState(blendPSO)
            encoder.setDepthStencilState(blendDS)
            for group in meshGroups where group.isBlend { drawGroup(group) }
        }

        encoder.popDebugGroup()
    }
}
