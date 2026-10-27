//
//  VRMRenderer+AvatarShadow.swift
//  NeuraLink
//
//  Received shadows on the avatar (docs/VRM_RENDERING_PLAN.md phase 4).
//  The terrain's shadow maps span metres for the ground; a self-shadow
//  needs millimetres (hair on a forehead, a chin on a neck), so the avatar
//  gets a map of its own: 2048², a light frustum fitted around the
//  character each frame from the MToon key light (light 0) — the light the
//  toon step already uses, so a shadow never lands on a side the shading
//  calls lit. MToon multiplies its key-light step by the result
//  (three-vrm: `shading *= shadow`), which turns shadowed areas into the
//  authored shade colour.
//
//  Casters: every visible part except transparent ones. Cutout parts
//  discard their transparent texels.
//
//  Created by Dedicatus on 23/10/2026.
//

import Metal
import simd

/// Mirrors `AvatarShadowDrawUniforms` (AvatarShadowShader.metal).
struct AvatarShadowDrawUniforms {
    var lightViewProjection: simd_float4x4
    var modelMatrix: simd_float4x4
    var baseColorFactor: SIMD4<Float>
    var alphaCutoff: Float
    var alphaTest: Int32
    var skinned: Int32
    var hasMorphed: Int32
}

/// Mirrors `AvatarShadowParams` (MToonCommon.metal): what the MToon fragment
/// needs to read the self-shadow map.
struct AvatarShadowParams {
    var lightViewProjection = matrix_identity_float4x4
    /// World offset along the normal before the lookup (acne on lit faces).
    var normalOffset: Float = 0
    /// Depth bias in the map's [0, 1] depth.
    var depthBias: Float = 0
    /// One texel in shadow-map UV (PCF spacing).
    var texelSize: Float = 0
    var enabled: Int32 = 0
}

extension VRMRenderer {

    static let avatarShadowMapSize = 2_048

    /// Orthographic light matrix around a sphere (`centre`, `radius`) seen
    /// from `towardLight`.
    static func avatarShadowLightMatrix(
        centre: SIMD3<Float>, radius: Float, towardLight: SIMD3<Float>
    ) -> simd_float4x4 {
        let direction = simd_normalize(towardLight)
        let up: SIMD3<Float> = abs(direction.y) > 0.98 ? [1, 0, 0] : [0, 1, 0]
        let eye = centre + direction * (radius + 2)
        let view = OrthographicCamera.makeLookAt(eye: eye, target: centre, up: up)
        let projection = OrthographicCamera.makeOrthographic(
            left: -radius, right: radius, bottom: -radius, top: radius, near: 0.1, far: radius * 2 + 4)
        return projection * view
    }

    /// Renders the casters into the avatar shadow map and fills
    /// `avatarShadowParams` for the main pass. Before the main pass encoder.
    func encodeAvatarShadowPass(
        commandBuffer: MTLCommandBuffer, model: VRMModel, morphedBuffers: [MorphKey: MTLBuffer]
    ) {
        avatarShadowParams.enabled = 0
        guard avatarSelfShadowsEnabled, simd_reduce_max(uniforms.lightColor) > 0.001, prepareAvatarShadowResources(),
              let map = avatarShadowMap, let pipeline = avatarShadowPipeline, let white = avatarShadowWhiteTexture
        else { return }

        let bounds = model.calculateBoundingBox()
        let centre4 = vrmVersionRotation * SIMD4<Float>((bounds.min + bounds.max) * 0.5, 1)
        // Half the diagonal plus room for a pose reaching past the rest bounds.
        let radius = simd_length(bounds.max - bounds.min) * 0.5 + 0.15
        let lightMatrix = Self.avatarShadowLightMatrix(
            centre: SIMD3(centre4.x, centre4.y, centre4.z), radius: radius, towardLight: -uniforms.lightDirection)

        let pass = MTLRenderPassDescriptor()
        pass.depthAttachment.texture = map
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 1
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "AvatarShadowPass"
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(avatarShadowDepthState)
        encoder.setCullMode(.none)
        encoder.setDepthBias(0, slopeScale: 1.5, clamp: 0.002)
        if let sampler = samplerStates["default"] { encoder.setFragmentSamplerState(sampler, index: 0) }

        let items = (cacheNeedsRebuild ? nil : cachedRenderItems) ?? buildRenderItems(model: model)
        for item in items where item.alphaMode != "blend" {
            encodeAvatarShadowCaster(item, model: model, lightMatrix: lightMatrix, white: white,
                                     morphedBuffers: morphedBuffers, encoder: encoder)
        }
        encoder.endEncoding()

        let texel = 2 * radius / Float(Self.avatarShadowMapSize)
        avatarShadowParams = AvatarShadowParams(
            lightViewProjection: lightMatrix, normalOffset: texel * 1.5,
            depthBias: 0.0015, texelSize: 1 / Float(Self.avatarShadowMapSize), enabled: 1)
    }

    /// Binds the map and its parameters for the MToon fragment (texture 8,
    /// buffer 9, sampler 1). Once per main pass, before the avatar draws.
    func bindAvatarShadow(encoder: MTLRenderCommandEncoder) {
        guard prepareAvatarShadowResources(), let map = avatarShadowMap else { return }
        var params = avatarShadowParams
        encoder.setFragmentBytes(&params, length: MemoryLayout<AvatarShadowParams>.stride, index: 9)
        encoder.setFragmentTexture(map, index: 8)
        encoder.setFragmentSamplerState(avatarShadowSampler, index: 1)
    }

    private func encodeAvatarShadowCaster(
        _ item: RenderItem, model: VRMModel, lightMatrix: simd_float4x4, white: MTLTexture,
        morphedBuffers: [MorphKey: MTLBuffer], encoder: MTLRenderCommandEncoder
    ) {
        let primitive = item.primitive
        guard let vertexBuffer = primitive.vertexBuffer, let indexBuffer = primitive.indexBuffer else { return }
        let material = primitive.materialIndex.flatMap { $0 < model.materials.count ? model.materials[$0] : nil }
        let skinIndex = item.node.skin
        let skinned = skinIndex != nil || (primitive.hasJoints && primitive.hasWeights)

        let key: MorphKey = (UInt64(item.meshIndex) << 32) | UInt64(item.primIdxInMesh)
        let morphed = morphedBuffers[key]
        var uniforms = AvatarShadowDrawUniforms(
            lightViewProjection: lightMatrix,
            modelMatrix: skinned ? vrmVersionRotation : simd_mul(vrmVersionRotation, item.node.worldMatrix),
            baseColorFactor: material?.baseColorFactor ?? [1, 1, 1, 1],
            alphaCutoff: item.alphaCutoff,
            alphaTest: item.alphaMode == "mask" ? 1 : 0,
            skinned: skinned ? 1 : 0,
            hasMorphed: morphed != nil ? 1 : 0)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<AvatarShadowDrawUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<AvatarShadowDrawUniforms>.stride, index: 1)
        encoder.setVertexBuffer(morphed ?? avatarShadowPlaceholderBuffer, offset: 0, index: ResourceIndices.morphedPositionsBuffer)
        if let skinIndex, skinIndex < model.skins.count, let joints = skinningSystem?.getJointMatricesBuffer() {
            let offset = model.skins[skinIndex].matrixOffset * MemoryLayout<float4x4>.stride
            encoder.setVertexBuffer(joints, offset: offset, index: ResourceIndices.jointMatricesBuffer)
        } else {
            encoder.setVertexBuffer(avatarShadowPlaceholderBuffer, offset: 0, index: ResourceIndices.jointMatricesBuffer)
        }
        encoder.setFragmentTexture(material?.baseColorTexture?.mtlTexture ?? white, index: 0)
        if let sampler = material?.baseColorTexture?.sampler ?? samplerStates["default"] {
            encoder.setFragmentSamplerState(sampler, index: 0)
        }
        encoder.drawIndexedPrimitives(
            type: primitive.primitiveType, indexCount: primitive.indexCount, indexType: primitive.indexType,
            indexBuffer: indexBuffer, indexBufferOffset: primitive.indexBufferOffset)
    }

    /// Creates the map, pipeline, states and placeholders on first use.
    private func prepareAvatarShadowResources() -> Bool {
        if avatarShadowMap != nil { return avatarShadowPipeline != nil }
        let size = Self.avatarShadowMapSize
        let mapDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: size, height: size, mipmapped: false)
        mapDescriptor.usage = [.renderTarget, .shaderRead]
        mapDescriptor.storageMode = .private
        avatarShadowMap = device.makeTexture(descriptor: mapDescriptor)
        avatarShadowMap?.label = "ShadowMap_Avatar"

        let whiteDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        avatarShadowWhiteTexture = device.makeTexture(descriptor: whiteDescriptor)
        let whitePixel: [UInt8] = [255, 255, 255, 255]
        avatarShadowWhiteTexture?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                                          withBytes: whitePixel, bytesPerRow: 4)
        avatarShadowPlaceholderBuffer = device.makeBuffer(length: MemoryLayout<float4x4>.stride, options: .storageModeShared)

        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .less
        depth.isDepthWriteEnabled = true
        avatarShadowDepthState = device.makeDepthStencilState(descriptor: depth)

        let sampler = MTLSamplerDescriptor()
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        sampler.sAddressMode = .clampToEdge
        sampler.tAddressMode = .clampToEdge
        sampler.compareFunction = .lessEqual
        avatarShadowSampler = device.makeSamplerState(descriptor: sampler)

        do {
            let library = try VRMPipelineCache.shared.getLibrary(device: device)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "avatar_shadow"
            descriptor.vertexFunction = library.makeFunction(name: "avatar_shadow_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "avatar_shadow_fragment")
            descriptor.vertexDescriptor = skinnedVertexDescriptor
            descriptor.depthAttachmentPixelFormat = .depth32Float
            avatarShadowPipeline = try VRMPipelineCache.shared.getPipelineState(
                device: device, descriptor: descriptor, key: "avatar_shadow")
        } catch {
            nlLog("[AvatarShadow] Pipeline creation failed: \(error)", level: .error)
        }
        return avatarShadowPipeline != nil
    }
}
