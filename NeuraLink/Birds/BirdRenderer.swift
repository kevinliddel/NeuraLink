//
//  BirdRenderer.swift
//  NeuraLink
//
//  Created by Dedicatus on 21/04/2026.
//

import Metal
import simd

/// Renders a flock of low-poly animated birds using a single instanced draw call.
///
/// Encode this **after** the terrain pass so birds appear above the ground,
/// and **before** the VRM model so the character renders on top.
final class BirdRenderer {

    var isEnabled: Bool = true

    // MARK: - Private state

    private let device: MTLDevice
    private var pipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var vertexBuffer: MTLBuffer?
    private var instanceBuffer: MTLBuffer?
    private var uniformBuffer: MTLBuffer?
    private var vertexCount: Int = 0

    private var birds: [BirdInstance]
    private var time: Float = 0

    // Lighting written by update() (main thread), read by encode() (render thread).
    // Follows the same threading model as SkyRenderer.currentEnvironment.
    private var cachedSunDir: SIMD3<Float>    = [0, 1, 0]
    private var cachedSunColor: SIMD3<Float>  = [1, 1, 1]
    private var cachedSunIntensity: Float     = 1
    private var cachedAmbient: SIMD3<Float>   = [0.3, 0.3, 0.3]

    // MARK: - Init

    init(device: MTLDevice, config: RendererConfig) {
        self.device = device
        self.birds = BirdBehavior.makeInitialFlock(count: 10)
        setupBuffers()
        setupPipeline(config: config)
        setupDepthState()
    }

    // MARK: - Per-frame update (main thread)

    /// Advances bird positions/wing angles and caches sky lighting for the next encode.
    func update(environment: SkyEnvironment, deltaTime: Float) {
        time += deltaTime
        BirdBehavior.update(birds: &birds, time: time, deltaTime: deltaTime)
        uploadInstances()
        cachedSunDir       = environment.keyLightDirection
        cachedSunColor     = environment.keyLightColor
        cachedSunIntensity = environment.keyLightIntensity
        cachedAmbient      = environment.ambientColor
    }

    // MARK: - Encode (render thread)

    /// Encodes the instanced bird draw call into the active render encoder.
    func encode(encoder: MTLRenderCommandEncoder, viewProjection: simd_float4x4) {
        guard isEnabled,
              let pipeline,
              let depth = depthState,
              let vb = vertexBuffer,
              let ib = instanceBuffer,
              let ub = uniformBuffer else { return }

        uploadUniforms(viewProjection: viewProjection, to: ub)

        encoder.pushDebugGroup("Birds")
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depth)
        encoder.setCullMode(.none)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setVertexBuffer(vb, offset: 0, index: 0)
        encoder.setVertexBuffer(ub, offset: 0, index: 1)
        encoder.setVertexBuffer(ib, offset: 0, index: 2)
        encoder.setFragmentBuffer(ub, offset: 0, index: 1)
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: vertexCount,
            instanceCount: birds.count
        )
        encoder.popDebugGroup()
    }

    // MARK: - Setup

    private func setupBuffers() {
        let vertices = BirdGeometry.makeVertices()
        vertexCount = vertices.count

        let vbLen = vertices.count * MemoryLayout<BirdVertexData>.stride
        vertexBuffer = device.makeBuffer(bytes: vertices, length: vbLen, options: .storageModeShared)
        vertexBuffer?.label = "BirdVertices"

        let ibLen = max(birds.count * MemoryLayout<BirdInstanceGPUData>.stride, 1)
        instanceBuffer = device.makeBuffer(length: ibLen, options: .storageModeShared)
        instanceBuffer?.label = "BirdInstances"

        uniformBuffer = device.makeBuffer(
            length: MemoryLayout<BirdUniformsData>.stride, options: .storageModeShared)
        uniformBuffer?.label = "BirdUniforms"
    }

    private func setupPipeline(config: RendererConfig) {
        do {
            let lib = try VRMPipelineCache.shared.getLibrary(device: device)
            guard let vert = lib.makeFunction(name: "bird_vertex"),
                  let frag = lib.makeFunction(name: "bird_fragment") else {
                vrmLog("[BirdRenderer] bird_vertex / bird_fragment not found in library")
                return
            }

            // Vertex descriptor matching BirdVertexData (stride 32)
            let vd = MTLVertexDescriptor()
            vd.attributes[0].format = .float3; vd.attributes[0].offset =  0; vd.attributes[0].bufferIndex = 0
            vd.attributes[1].format = .float3; vd.attributes[1].offset = 12; vd.attributes[1].bufferIndex = 0
            vd.attributes[2].format = .int;    vd.attributes[2].offset = 24; vd.attributes[2].bufferIndex = 0
            vd.layouts[0].stride = 32
            vd.layouts[0].stepFunction = .perVertex

            let desc = MTLRenderPipelineDescriptor()
            desc.label = "birds"
            desc.vertexFunction = vert
            desc.fragmentFunction = frag
            desc.vertexDescriptor = vd
            desc.colorAttachments[0].pixelFormat = config.colorPixelFormat
            desc.colorAttachments[0].isBlendingEnabled = false
            desc.depthAttachmentPixelFormat = .depth32Float
            desc.rasterSampleCount = config.sampleCount

            pipeline = try VRMPipelineCache.shared.getPipelineState(
                device: device, descriptor: desc, key: "birds")
        } catch {
            vrmLog("[BirdRenderer] Pipeline setup failed: \(error)")
        }
    }

    private func setupDepthState() {
        let desc = MTLDepthStencilDescriptor()
        desc.depthCompareFunction = .less
        desc.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: desc)
    }

    // MARK: - Buffer uploads

    private func uploadInstances() {
        guard let buf = instanceBuffer else { return }
        var gpuData = birds.map { b in
            BirdInstanceGPUData(
                positionAndYaw: SIMD4<Float>(
                    b.worldPosition.x, b.worldPosition.y, b.worldPosition.z, b.yaw),
                wingAngleAndScale: SIMD4<Float>(b.wingAngle, b.scale, 0, 0)
            )
        }
        buf.contents().copyMemory(
            from: &gpuData,
            byteCount: gpuData.count * MemoryLayout<BirdInstanceGPUData>.stride)
    }

    private func uploadUniforms(viewProjection: simd_float4x4, to buf: MTLBuffer) {
        var data = BirdUniformsData(
            viewProjection: viewProjection,
            sunDirection: SIMD4<Float>(
                cachedSunDir.x, cachedSunDir.y, cachedSunDir.z, cachedSunIntensity),
            sunColor: SIMD4<Float>(cachedSunColor.x, cachedSunColor.y, cachedSunColor.z, 0),
            ambientColor: SIMD4<Float>(cachedAmbient.x, cachedAmbient.y, cachedAmbient.z, 0)
        )
        buf.contents().copyMemory(from: &data, byteCount: MemoryLayout<BirdUniformsData>.stride)
    }
}
