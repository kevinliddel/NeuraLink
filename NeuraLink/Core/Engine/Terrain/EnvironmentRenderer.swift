//
//  EnvironmentRenderer.swift
//  NeuraLink
//
//  Loads and renders a single static GLB 3D environment.
//
//  Created by Dedicatus on 08/05/2026.
//

import Foundation
import Metal
import simd

// MARK: - Vertex / uniform layouts (must mirror CityShader.metal)

struct CityVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var texCoord: SIMD2<Float>
    var color: SIMD4<Float>  // vertex color (COLOR_0), default (1,1,1,1)
}

struct CityUniforms {
    var viewProjection: simd_float4x4
    var lightViewProjection: simd_float4x4
    var sunDirection: SIMD4<Float>  // xyz = effective sun dir, w = sun height (signed)
    var cityParams: SIMD4<Float>  // x = shadowSoft
    var cameraPosition: SIMD4<Float>  // xyz = camera world position, w = 0
    var vrmLightViewProjection: simd_float4x4  // tight VRM shadow map projection
}

struct CityShadowUniforms {
    var lightViewProjection: simd_float4x4
}

// MARK: - Per-primitive container

struct CityMeshGroup {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    let indexType: MTLIndexType
    let texture: MTLTexture?  // base colour / diffuse
    let normalTexture: MTLTexture?
    let mrTexture: MTLTexture?  // metallic-roughness: g = roughness, b = metallic
    let emissiveTexture: MTLTexture?
    let baseColorFactor: SIMD4<Float>
    let emissivePacked: SIMD4<Float>  // xyz = emissiveFactor, w = alphaCutoff
    let materialParams: SIMD4<Float>  // x = metallic, y = roughness, z = normalScale
    let texFlags: SIMD4<Float>  // x = hasNormal, y = hasMR, z = hasEmissive
    let transform: simd_float4x4
    let isBlend: Bool
    /// glTF `doubleSided`; single-sided groups are culled from behind when
    /// the environment resolves duplicate faces.
    var doubleSided = true
    /// Coplanar layer (CoplanarLayering): drawn with a depth bias this many
    /// steps toward the camera so a duplicate copy never wins over it.
    var depthLayer = 0
    /// The transform mirrors the mesh, so its winding reads the other way.
    var mirrored = false
}

// MARK: - EnvironmentRenderer

final class EnvironmentRenderer: @unchecked Sendable {

    typealias InstanceConfig = (x: Float, y: Float, z: Float, rotY: Float, scale: Float)

    let device: MTLDevice
    var meshGroups: [CityMeshGroup] = []
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

    /// When set, the loaded GLB is uniformly scaled so its larger horizontal
    /// (x/z) extent equals this many world units — used to normalize models authored in the wrong units.
    /// `nil` keeps the model's native size at `instanceConfig.scale`.
    let autoFitFootprint: Float?

    /// False for GLBs whose textures are plain PBR albedo (apartment) — the shader then applies runtime diffuse lighting.
    /// True for GLBs with lighting baked into their textures (city, campus), which the shader passes through almost directly.
    let bakedLighting: Bool

    /// The GLB carries duplicate faces — a back-facing shell, coplanar copies
    /// (SketchUp exports). Honour single-sided materials and draw coplanar
    /// copies in layers (CoplanarLayering) so the detailed one always wins.
    let resolvesDuplicateFaces: Bool

    /// Uniform scale actually applied at load (auto-fit or `instanceConfig.scale`).
    /// Used to scale the distance-haze range so a scaled-up env isn't hazed out.
    /// Set by `load(url:)` in the +Load extension, so not `private(set)`.
    var appliedScale: Float = 1

    /// True once the GLB has finished loading. Used by VRMRenderer to suppress
    /// terrain rendering while the environment is active.
    var isLoaded: Bool { isReady }

    init(
        device: MTLDevice,
        instanceConfig: InstanceConfig = (x: 0, y: 0, z: 0, rotY: 0, scale: 1.0),
        autoFitFootprint: Float? = nil,
        bakedLighting: Bool = true,
        resolvesDuplicateFaces: Bool = false
    ) {
        self.device = device
        self.instanceConfig = instanceConfig
        self.autoFitFootprint = autoFitFootprint
        self.bakedLighting = bakedLighting
        self.resolvesDuplicateFaces = resolvesDuplicateFaces
    }

    /// Depth bias per coplanar layer: a few units of constant bias plus a
    /// slope term, which is what keeps a floor seen at a grazing angle from
    /// fighting. Small enough that nothing a few millimetres in front shows
    /// through.
    static let layerDepthBias: Float = -4
    static let layerSlopeBias: Float = -2

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

        var su = CityShadowUniforms(lightViewProjection: lightViewProjection)
        shadowBuf.contents().copyMemory(
            from: &su, byteCount: MemoryLayout<CityShadowUniforms>.stride)

        let passDesc = MTLRenderPassDescriptor()
        passDesc.depthAttachment.texture = shadowMap
        passDesc.depthAttachment.loadAction = clearFirst ? .clear : .load
        passDesc.depthAttachment.storeAction = .store
        passDesc.depthAttachment.clearDepth = 1.0

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            return
        }
        encoder.label = "CityShadowPass"
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(ds)
        encoder.setCullMode(.none)
        encoder.setDepthBias(0.0, slopeScale: 2.0, clamp: 0.005)
        encoder.setVertexBuffer(shadowBuf, offset: 0, index: 1)

        for group in meshGroups {
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

        var u = CityUniforms(
            viewProjection: viewProjection,
            lightViewProjection: lightViewProjection,
            sunDirection: SIMD4<Float>(sunDirection.x, sunDirection.y, sunDirection.z, sunHeight),
            // x = shadowSoft, y/z = distance-haze start/end (scaled with the
            // model so a large auto-fit env isn't hazed out — but never below
            // 80–160 m: a scene shrunk into metres from inches or millimetres
            // would otherwise be hazed from a couple of metres, or from the
            // avatar's feet), w = lighting mode (0 = baked, 1 = runtime-lit).
            cityParams: SIMD4<Float>(
                shadowSoft, 80 * max(appliedScale, 1), 160 * max(appliedScale, 1), bakedLighting ? 0 : 1),
            cameraPosition: SIMD4<Float>(cameraPosition.x, cameraPosition.y, cameraPosition.z, 0),
            vrmLightViewProjection: vrmLightViewProjection
        )
        uniBuf.contents().copyMemory(from: &u, byteCount: MemoryLayout<CityUniforms>.stride)

        encoder.pushDebugGroup("City")
        encoder.setCullMode(.none)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setVertexBuffer(uniBuf, offset: 0, index: 1)
        encoder.setFragmentBuffer(uniBuf, offset: 0, index: 1)
        encoder.setFragmentTexture(shadowMap, index: 1)
        encoder.setFragmentTexture(vrmShadowMap, index: 2)
        encoder.setFragmentSamplerState(shadowSampler, index: 0)

        let resolves = resolvesDuplicateFaces
        func drawGroup(_ group: CityMeshGroup) {
            if resolves {
                encoder.setCullMode(group.doubleSided ? .none : .back)
                encoder.setFrontFacing(group.mirrored ? .clockwise : .counterClockwise)
                let layer = Float(group.depthLayer)
                encoder.setDepthBias(Self.layerDepthBias * layer, slopeScale: Self.layerSlopeBias * layer, clamp: 0)
            }
            var transform = group.transform
            var baseColor = group.baseColorFactor
            var emissivePacked = group.emissivePacked
            var matParams = group.materialParams
            var texFlags = group.texFlags
            encoder.setVertexBuffer(group.vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&transform, length: MemoryLayout<simd_float4x4>.stride, index: 2)
            encoder.setFragmentBytes(&baseColor, length: MemoryLayout<SIMD4<Float>>.size, index: 2)
            encoder.setFragmentBytes(
                &emissivePacked, length: MemoryLayout<SIMD4<Float>>.size, index: 3)
            encoder.setFragmentBytes(&matParams, length: MemoryLayout<SIMD4<Float>>.size, index: 4)
            encoder.setFragmentBytes(&texFlags, length: MemoryLayout<SIMD4<Float>>.size, index: 5)
            encoder.setFragmentTexture(group.texture ?? fallbackTexture, index: 0)
            encoder.setFragmentTexture(group.normalTexture ?? fallbackTexture, index: 3)
            encoder.setFragmentTexture(group.mrTexture ?? fallbackTexture, index: 4)
            encoder.setFragmentTexture(group.emissiveTexture ?? fallbackTexture, index: 5)
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
        if resolves {
            encoder.setCullMode(.none)
            encoder.setFrontFacing(.counterClockwise)
            encoder.setDepthBias(0, slopeScale: 0, clamp: 0)
        }

        encoder.popDebugGroup()
    }
}
