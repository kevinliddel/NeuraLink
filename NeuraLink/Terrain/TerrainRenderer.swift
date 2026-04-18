//
//  TerrainRenderer.swift
//  NeuraLink
//
//  Created by Dedicatus on 18/04/2026.
//

import Metal
import simd

// MARK: - TerrainRenderer

/// Renders a snow/dune ground plane at y = 0 and casts VRM shadows onto it via shadow mapping.
///
/// Lifecycle:
/// 1. `update(environment:)` — called on the animation tick, stores sun state.
/// 2. `drawShadowPass(commandBuffer:model:modelRotation:skinningSystem:)` — before main encoder.
/// 3. `drawTerrain(encoder:viewProjection:)` — inside main encoder, after sky, before VRM.
final class TerrainRenderer: @unchecked Sendable {

    // MARK: - Constants

    static let shadowMapSize = 1024
    /// Must match `kGridSize` in TerrainShader.metal (64 × 64 quads × 6 vertices).
    static let terrainVertices = 64 * 64 * 6

    // MARK: - State

    private let device: MTLDevice
    private var shadowMapTexture: MTLTexture?
    private var shadowDepthState: MTLDepthStencilState?
    private var terrainDepthState: MTLDepthStencilState?
    private var shadowPipeline: MTLRenderPipelineState?
    private var shadowSkinnedPipeline: MTLRenderPipelineState?
    private var terrainPipeline: MTLRenderPipelineState?
    private var terrainUniformsBuffer: MTLBuffer?
    private var shadowSamplerState: MTLSamplerState?

    private var lightViewProjection: simd_float4x4 = matrix_identity_float4x4
    private var elapsedTime: Float = 0
    private var currentEnvironment: SkyEnvironment = SkyEnvironment.resolve(hour: 12.0)

    // MARK: - Init

    init?(device: MTLDevice, config: RendererConfig) {
        self.device = device
        guard setup(config: config) else { return nil }
    }

    // MARK: - Per-frame update

    func update(environment: SkyEnvironment, deltaTime: Float) {
        currentEnvironment = environment
        elapsedTime += deltaTime
        // At night use the moon direction (opposite the sun) so shadows still render.
        let sunDir = environment.sunDirection
        // Moon is the mirror of the sun; flip below horizon so shadows always render.
        let effectiveDir = sunDir.y >= 0 ? sunDir : sunDir * -1.0
        lightViewProjection = Self.makeLightMatrix(sunDir: effectiveDir)
    }

    // MARK: - Shadow pass (before main encoder)

    func drawShadowPass(
        commandBuffer: MTLCommandBuffer,
        model: VRMModel,
        modelRotation: simd_float4x4,
        skinningSystem: VRMSkinningSystem?
    ) {
        guard let pipeline = shadowPipeline,
            let skinnedPipeline = shadowSkinnedPipeline,
            let depthState = shadowDepthState,
            let shadowMap = shadowMapTexture
        else { return }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.depthAttachment.texture = shadowMap
        passDesc.depthAttachment.loadAction = .clear
        passDesc.depthAttachment.storeAction = .store
        passDesc.depthAttachment.clearDepth = 1.0

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            return
        }
        encoder.label = "ShadowPass"
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.back)
        encoder.setFrontFacing(.counterClockwise)

        for node in model.nodes {
            guard let meshIdx = node.mesh, meshIdx < model.meshes.count else { continue }
            let mesh = model.meshes[meshIdx]
            let isSkinned = node.skin != nil

            for primitive in mesh.primitives {
                guard let vertexBuffer = primitive.vertexBuffer else { continue }
                guard let indexBuffer = primitive.indexBuffer else { continue }

                if isSkinned {
                    encodeShadowSkinned(
                        encoder: encoder,
                        pipeline: skinnedPipeline,
                        primitive: primitive,
                        vertexBuffer: vertexBuffer,
                        indexBuffer: indexBuffer,
                        modelRotation: modelRotation,
                        node: node,
                        model: model,
                        skinningSystem: skinningSystem
                    )
                } else {
                    encodeShadowStatic(
                        encoder: encoder,
                        pipeline: pipeline,
                        primitive: primitive,
                        vertexBuffer: vertexBuffer,
                        indexBuffer: indexBuffer,
                        modelRotation: modelRotation,
                        node: node
                    )
                }
            }
        }

        encoder.endEncoding()
    }

    // MARK: - Terrain draw (inside main encoder)

    func drawTerrain(encoder: MTLRenderCommandEncoder, viewProjection: simd_float4x4) {
        guard let pipeline = terrainPipeline,
            let depthState = terrainDepthState,
            let uniforms = terrainUniformsBuffer,
            let shadowMap = shadowMapTexture,
            let sampler = shadowSamplerState
        else { return }

        let env = currentEnvironment
        let sd  = env.sunDirection
        // At night pass the moon direction (already in lightViewProjection) for shading.
        let lightDir = sd.y >= 0 ? sd : sd * -1.0
        // Moon shadows are slightly softer than sun shadows.
        let shadowSoft: Float = sd.y >= 0 ? 2.5 : 1.5

        var data = TerrainUniforms(
            viewProjection: viewProjection,
            lightViewProjection: lightViewProjection,
            sunDirection: SIMD4<Float>(lightDir.x, lightDir.y, lightDir.z, 0),
            snowColor: SIMD4<Float>(0.93, 0.95, 0.97, 1.0),
            terrainParams: SIMD4<Float>(
                0.0,       // unused
                0.22,      // duneAmp: max ~22 cm height
                shadowSoft,
                elapsedTime
            )
        )
        uniforms.contents().copyMemory(from: &data, byteCount: MemoryLayout<TerrainUniforms>.stride)

        encoder.pushDebugGroup("SnowTerrain")
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.back)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setVertexBuffer(uniforms, offset: 0, index: 0)
        encoder.setFragmentBuffer(uniforms, offset: 0, index: 0)
        encoder.setFragmentTexture(shadowMap, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: Self.terrainVertices)
        encoder.popDebugGroup()
    }

    // MARK: - Private helpers

    private func encodeShadowStatic(
        encoder: MTLRenderCommandEncoder,
        pipeline: MTLRenderPipelineState,
        primitive: VRMPrimitive,
        vertexBuffer: MTLBuffer,
        indexBuffer: MTLBuffer,
        modelRotation: simd_float4x4,
        node: VRMNode
    ) {
        encoder.setRenderPipelineState(pipeline)
        var uniforms = ShadowPassUniforms(
            lightModelViewProjection: lightViewProjection
                * simd_mul(modelRotation, node.worldMatrix)
        )
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(
            &uniforms, length: MemoryLayout<ShadowPassUniforms>.stride, index: 1)
        encoder.drawIndexedPrimitives(
            type: primitive.primitiveType,
            indexCount: primitive.indexCount,
            indexType: primitive.indexType,
            indexBuffer: indexBuffer,
            indexBufferOffset: primitive.indexBufferOffset
        )
    }

    private func encodeShadowSkinned(
        encoder: MTLRenderCommandEncoder,
        pipeline: MTLRenderPipelineState,
        primitive: VRMPrimitive,
        vertexBuffer: MTLBuffer,
        indexBuffer: MTLBuffer,
        modelRotation: simd_float4x4,
        node: VRMNode,
        model: VRMModel,
        skinningSystem: VRMSkinningSystem?
    ) {
        encoder.setRenderPipelineState(pipeline)
        var uniforms = ShadowPassUniforms(
            lightModelViewProjection: lightViewProjection * modelRotation
        )
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(
            &uniforms, length: MemoryLayout<ShadowPassUniforms>.stride, index: 1)

        if let skinIdx = node.skin,
            skinIdx < model.skins.count,
            let jointBuf = skinningSystem?.getJointMatricesBuffer()
        {
            let skin = model.skins[skinIdx]
            let offset = skinningSystem?.getBufferOffset(for: skin) ?? 0
            encoder.setVertexBuffer(jointBuf, offset: offset, index: 4)
        }

        encoder.drawIndexedPrimitives(
            type: primitive.primitiveType,
            indexCount: primitive.indexCount,
            indexType: primitive.indexType,
            indexBuffer: indexBuffer,
            indexBufferOffset: primitive.indexBufferOffset
        )
    }
}

// MARK: - Setup

extension TerrainRenderer {

    fileprivate func setup(config: RendererConfig) -> Bool {
        guard createShadowMap(),
            createDepthStates(),
            createSampler(),
            createTerrainUniformsBuffer(),
            setupShadowPipelines(config: config),
            setupTerrainPipeline(config: config)
        else { return false }
        return true
    }

    fileprivate func createShadowMap() -> Bool {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2D
        desc.width = Self.shadowMapSize
        desc.height = Self.shadowMapSize
        desc.pixelFormat = .depth32Float
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        shadowMapTexture = device.makeTexture(descriptor: desc)
        shadowMapTexture?.label = "ShadowMap"
        return shadowMapTexture != nil
    }

    fileprivate func createDepthStates() -> Bool {
        let shadowDesc = MTLDepthStencilDescriptor()
        shadowDesc.depthCompareFunction = .less
        shadowDesc.isDepthWriteEnabled = true
        shadowDepthState = device.makeDepthStencilState(descriptor: shadowDesc)

        let terrainDesc = MTLDepthStencilDescriptor()
        terrainDesc.depthCompareFunction = .less
        terrainDesc.isDepthWriteEnabled = true
        terrainDepthState = device.makeDepthStencilState(descriptor: terrainDesc)

        return shadowDepthState != nil && terrainDepthState != nil
    }

    fileprivate func createSampler() -> Bool {
        let desc = MTLSamplerDescriptor()
        desc.minFilter = .linear
        desc.magFilter = .linear
        desc.sAddressMode = .clampToEdge
        desc.tAddressMode = .clampToEdge
        // No compareFunction — shader does manual PCF comparison via sample().r
        shadowSamplerState = device.makeSamplerState(descriptor: desc)
        return shadowSamplerState != nil
    }

    fileprivate func createTerrainUniformsBuffer() -> Bool {
        terrainUniformsBuffer = device.makeBuffer(
            length: MemoryLayout<TerrainUniforms>.stride, options: .storageModeShared)
        terrainUniformsBuffer?.label = "TerrainUniforms"
        return terrainUniformsBuffer != nil
    }

    fileprivate func setupShadowPipelines(config: RendererConfig) -> Bool {
        do {
            let lib = try VRMPipelineCache.shared.getLibrary(device: device)
            guard let vertFn = lib.makeFunction(name: "shadow_vertex"),
                let skinnedFn = lib.makeFunction(name: "shadow_skinned_vertex")
            else {
                vrmLog("[TerrainRenderer] shadow_vertex / shadow_skinned_vertex not found")
                return false
            }

            let posOffset = MemoryLayout<VRMVertex>.offset(of: \.position)!
            let jntOffset = MemoryLayout<VRMVertex>.offset(of: \.joints)!
            let wgtOffset = MemoryLayout<VRMVertex>.offset(of: \.weights)!
            let stride = MemoryLayout<VRMVertex>.stride

            // Non-skinned: position only
            let staticVD = MTLVertexDescriptor()
            staticVD.attributes[0].format = .float3
            staticVD.attributes[0].offset = posOffset
            staticVD.attributes[0].bufferIndex = 0
            staticVD.layouts[0].stride = stride

            // Skinned: position + joints + weights
            let skinnedVD = MTLVertexDescriptor()
            skinnedVD.attributes[0].format = .float3
            skinnedVD.attributes[0].offset = posOffset
            skinnedVD.attributes[0].bufferIndex = 0
            skinnedVD.attributes[4].format = .uint4
            skinnedVD.attributes[4].offset = jntOffset
            skinnedVD.attributes[4].bufferIndex = 0
            skinnedVD.attributes[5].format = .float4
            skinnedVD.attributes[5].offset = wgtOffset
            skinnedVD.attributes[5].bufferIndex = 0
            skinnedVD.layouts[0].stride = stride

            let staticDesc = MTLRenderPipelineDescriptor()
            staticDesc.label = "shadow"
            staticDesc.vertexFunction = vertFn
            staticDesc.vertexDescriptor = staticVD
            staticDesc.depthAttachmentPixelFormat = .depth32Float

            let skinnedDesc = MTLRenderPipelineDescriptor()
            skinnedDesc.label = "shadow_skinned"
            skinnedDesc.vertexFunction = skinnedFn
            skinnedDesc.vertexDescriptor = skinnedVD
            skinnedDesc.depthAttachmentPixelFormat = .depth32Float

            shadowPipeline = try VRMPipelineCache.shared.getPipelineState(
                device: device, descriptor: staticDesc, key: "shadow")
            shadowSkinnedPipeline = try VRMPipelineCache.shared.getPipelineState(
                device: device, descriptor: skinnedDesc, key: "shadow_skinned")
        } catch {
            vrmLog("[TerrainRenderer] Shadow pipeline setup failed: \(error)")
            return false
        }
        return true
    }

    fileprivate func setupTerrainPipeline(config: RendererConfig) -> Bool {
        do {
            let lib = try VRMPipelineCache.shared.getLibrary(device: device)
            guard let vertFn = lib.makeFunction(name: "terrain_vertex"),
                let fragFn = lib.makeFunction(name: "terrain_fragment")
            else {
                vrmLog("[TerrainRenderer] terrain_vertex / terrain_fragment not found")
                return false
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "terrain"
            desc.vertexFunction = vertFn
            desc.fragmentFunction = fragFn
            desc.colorAttachments[0].pixelFormat = config.colorPixelFormat
            desc.colorAttachments[0].isBlendingEnabled = false
            desc.depthAttachmentPixelFormat = .depth32Float
            desc.rasterSampleCount = config.sampleCount

            terrainPipeline = try VRMPipelineCache.shared.getPipelineState(
                device: device, descriptor: desc, key: "terrain")
        } catch {
            vrmLog("[TerrainRenderer] Terrain pipeline setup failed: \(error)")
            return false
        }
        return true
    }
}

// MARK: - Light matrix

extension TerrainRenderer {

    static func makeLightMatrix(sunDir: SIMD3<Float>) -> simd_float4x4 {
        // Place the light eye far along the sun direction from scene centre
        let centre = SIMD3<Float>(0, 1.0, 0)
        let eyePos = centre + sunDir * 18.0

        // Up vector: use world Y unless sun is nearly vertical
        let up: SIMD3<Float> = abs(sunDir.y) > 0.98 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)

        let view = OrthographicCamera.makeLookAt(eye: eyePos, target: centre, up: up)

        // Generous ortho box: covers full VRM + shadow on ground
        let proj = OrthographicCamera.makeOrthographic(
            left: -4, right: 4, bottom: -3, top: 7, near: 0.1, far: 36
        )
        return proj * view
    }
}
