//
//  SkyRenderer.swift
//  NeuraLink
//
//  Created by Dedicatus on 17/04/2026.
//

import Metal
import simd

/// Renders a physically-inspired, time-of-day sky backdrop via a fullscreen triangle.
/// Encode this **before** any VRM draw calls so the sky renders behind the model.
final class SkyRenderer {

    // MARK: - Public state

    var isEnabled: Bool = true

    /// Most-recently computed environment (main thread).
    /// Read by the render thread to assemble GPU uniforms.
    private(set) var currentEnvironment: SkyEnvironment =
        SkyEnvironment.resolve(hour: 12.0)

    /// Rain intensity [0,1] set by RainRenderer each frame.
    /// Boosts cloud coverage, suppresses stars, and darkens the sky palette.
    var rainIntensity: Float = 0

    // MARK: - Private

    private let device: MTLDevice
    private var pipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var uniformBuffer: MTLBuffer?

    private var timeProvider = SkyTimeProvider()
    private var cloudTime: Float = 0

    // MARK: - Init

    init(device: MTLDevice, config: RendererConfig) {
        self.device = device
        uniformBuffer = device.makeBuffer(
            length: MemoryLayout<SkyUniformsData>.stride,
            options: .storageModeShared
        )
        uniformBuffer?.label = "SkyUniforms"
        setupPipeline(config: config)
        setupDepthState()
    }

    // MARK: - Per-frame update (main thread)

    /// Advances cloud time and re-derives the environment from the current local clock.
    /// Call this once per frame before `prepareForEncoding`.
    func update(deltaTime: Float) {
        cloudTime += deltaTime
        currentEnvironment = SkyEnvironment.resolve(hour: timeProvider.currentHour())
    }

    // MARK: - Render thread

    /// Assembles the GPU uniform buffer using the latest environment + camera matrices.
    /// Must be called from the render thread immediately before `encode`.
    func prepareForEncoding(invViewProjection: simd_float4x4) {
        let env = currentEnvironment
        let sd  = env.sunDirection
        let ri  = rainIntensity

        // Rain overrides: denser clouds, no stars, slightly darker sky.
        let cloudCoverage  = env.cloudCoverage  + (0.92 - env.cloudCoverage)  * ri
        let starVisibility = env.starVisibility * max(0, 1.0 - ri * 0.95)
        let darkFactor     = 1.0 - ri * 0.28
        let rainTint       = SIMD3<Float>(0.62, 0.67, 0.72)  // cool overcast grey
        let skyLow  = (env.skyColorLow  * (1 - ri * 0.55) + rainTint * (ri * 0.55)) * darkFactor
        let skyHigh = (env.skyColorHigh * (1 - ri * 0.65) + rainTint * (ri * 0.65)) * darkFactor

        var data = SkyUniformsData(
            invViewProjection: invViewProjection,
            sunDirectionAndIntensity: SIMD4<Float>(sd.x, sd.y, sd.z, env.keyLightIntensity * darkFactor),
            sunColorAndSize: SIMD4<Float>(
                env.keyLightColor.x, env.keyLightColor.y, env.keyLightColor.z,
                300.0  // disc exponent — tight sun disc
            ),
            skyColorLow:  SIMD4<Float>(skyLow.x,  skyLow.y,  skyLow.z,  0),
            skyColorHigh: SIMD4<Float>(skyHigh.x, skyHigh.y, skyHigh.z, 0),
            cloudParams: SIMD4<Float>(cloudTime, env.cloudSpeed, cloudCoverage, starVisibility)
        )
        uniformBuffer?.contents().copyMemory(
            from: &data, byteCount: MemoryLayout<SkyUniformsData>.stride)
    }

    /// Encodes the sky fullscreen draw into the active render encoder.
    func encode(encoder: MTLRenderCommandEncoder) {
        guard isEnabled, let pipeline, let buf = uniformBuffer else { return }
        encoder.pushDebugGroup("SkyBackground")
        encoder.setRenderPipelineState(pipeline)
        if let depth = depthState { encoder.setDepthStencilState(depth) }
        encoder.setCullMode(.none)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setFragmentBuffer(buf, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.popDebugGroup()
    }

    // MARK: - Setup

    private func setupPipeline(config: RendererConfig) {
        do {
            let lib = try VRMPipelineCache.shared.getLibrary(device: device)
            guard let vertFn = lib.makeFunction(name: "sky_vertex"),
                  let fragFn = lib.makeFunction(name: "sky_fragment") else {
                vrmLog("[SkyRenderer] sky_vertex / sky_fragment not found in library")
                return
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "sky"
            desc.vertexFunction = vertFn
            desc.fragmentFunction = fragFn
            desc.colorAttachments[0].pixelFormat = config.colorPixelFormat
            desc.colorAttachments[0].isBlendingEnabled = false
            desc.depthAttachmentPixelFormat = .depth32Float
            desc.rasterSampleCount = config.sampleCount
            pipeline = try VRMPipelineCache.shared.getPipelineState(
                device: device, descriptor: desc, key: "sky")
        } catch {
            vrmLog("[SkyRenderer] Pipeline setup failed: \(error)")
        }
    }

    private func setupDepthState() {
        let desc = MTLDepthStencilDescriptor()
        desc.depthCompareFunction = .always
        desc.isDepthWriteEnabled  = false
        depthState = device.makeDepthStencilState(descriptor: desc)
    }
}
