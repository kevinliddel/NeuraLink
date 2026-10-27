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
    private(set) var currentEnvironment: SkyEnvironment

    /// Rain intensity [0,1] set by RainRenderer each frame.
    /// Boosts cloud coverage, suppresses stars, and darkens the sky palette.
    var rainIntensity: Float = 0

    // MARK: - Private

    private let device: MTLDevice
    private var pipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var uniformBuffer: MTLBuffer?

    /// The bright-star catalogue, drawn as sprites over the sky.
    private var starPipeline: MTLRenderPipelineState?
    private var starBuffer: MTLBuffer?
    private var starCount = 0
    /// This frame's camera, for the sprites; nil when they are not drawn
    /// (daylight, or an orthographic camera, which has no sky to place
    /// them in).
    private var starViewProjection: simd_float4x4?

    /// The sky's clock and place. Internal so tests can pin a date;
    /// launch-time overrides come from `SkyTimeProvider.fromEnvironment`.
    var timeProvider: SkyTimeProvider

    /// Angular radius of the drawn moon. Stylised: about five times the real
    /// 0.26°, which reads at phone size.
    static let moonAngularRadius: Float = 0.0447
    private var cloudTime: Float = 0

    // MARK: - Init

    init(device: MTLDevice, config: RendererConfig) {
        self.device = device
        let clock = SkyTimeProvider.fromEnvironment()
        timeProvider = clock
        currentEnvironment = SkyEnvironment.resolve(at: clock.now(), location: clock.location)
        nlLog("[Sky] drawn for \(clock.timeZone.identifier): "
            + "\(clock.location.latitude)°, \(clock.location.longitude)°", level: .info)
        uniformBuffer = device.makeBuffer(
            length: MemoryLayout<SkyUniformsData>.stride,
            options: .storageModeShared
        )
        uniformBuffer?.label = "SkyUniforms"
        if let stars = SkyStarCatalogue.makeBuffer(device: device) {
            (starBuffer, starCount) = (stars.buffer, stars.count)
        }
        setupPipeline(config: config)
        setupDepthState()
    }

    // MARK: - Per-frame update (main thread)

    /// Advances cloud time and re-derives the environment from the clock and place.
    /// Call this once per frame before `prepareForEncoding`.
    func update(deltaTime: Float) {
        cloudTime += deltaTime
        currentEnvironment = SkyEnvironment.resolve(at: timeProvider.now(), location: timeProvider.location)
    }

    // MARK: - Render thread

    /// Assembles the GPU uniform buffer using the latest environment + camera matrices.
    /// Must be called from the render thread immediately before `encode`.
    func prepareForEncoding(viewProjection: simd_float4x4) {
        let env = currentEnvironment
        let sd  = env.sunDirection
        let md  = env.moonDirection
        let ri  = rainIntensity

        // Rain overrides: denser clouds, no stars, slightly darker sky.
        let cloudCoverage  = env.cloudCoverage  + (0.92 - env.cloudCoverage)  * ri
        let starVisibility = env.starVisibility * max(0, 1.0 - ri * 0.95)
        let darkFactor     = 1.0 - ri * 0.28
        let rainTint       = SIMD3<Float>(0.62, 0.67, 0.72)  // cool overcast grey
        let skyLow  = (env.skyColorLow  * (1 - ri * 0.55) + rainTint * (ri * 0.55)) * darkFactor
        let skyHigh = (env.skyColorHigh * (1 - ri * 0.65) + rainTint * (ri * 0.65)) * darkFactor

        // A perspective camera sends a direction (w = 0) somewhere on
        // screen; an orthographic one sends every direction to w = 0.
        let perspective = simd_length(SIMD3<Float>(
            viewProjection.columns.0.w, viewProjection.columns.1.w, viewProjection.columns.2.w)) > 1e-4
        starViewProjection = starVisibility > 0.001 && perspective ? viewProjection : nil

        var data = SkyUniformsData(
            invViewProjection: viewProjection.inverse,
            sunDirectionAndIntensity: SIMD4<Float>(sd.x, sd.y, sd.z, env.keyLight.intensity * darkFactor),
            sunColorAndSize: SIMD4<Float>(
                env.sunColor.x, env.sunColor.y, env.sunColor.z,
                300.0  // disc exponent — tight sun disc
            ),
            skyColorLow: SIMD4<Float>(skyLow.x, skyLow.y, skyLow.z, 0),
            skyColorHigh: SIMD4<Float>(skyHigh.x, skyHigh.y, skyHigh.z, 0),
            cloudParams: SIMD4<Float>(cloudTime, env.cloudSpeed, cloudCoverage, starVisibility),
            moonDirectionAndPhase: SIMD4<Float>(md.x, md.y, md.z, env.moonIllumination),
            bodyParams: SIMD4<Float>(Self.moonAngularRadius, env.turbidity, env.moonBrightness, 0),
            starRotation: env.starRotation
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
        if let starPipeline, let starBuffer, var viewProjection = starViewProjection {
            // Added on top, each star a small quad facing the camera.
            encoder.setRenderPipelineState(starPipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            encoder.setVertexBuffer(starBuffer, offset: 0, index: 1)
            encoder.setVertexBytes(&viewProjection, length: MemoryLayout<simd_float4x4>.stride, index: 2)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: starCount)
        }
        encoder.popDebugGroup()
    }

    // MARK: - Setup

    private func setupPipeline(config: RendererConfig) {
        do {
            let lib = try VRMPipelineCache.shared.getLibrary(device: device)
            guard let vertFn = lib.makeFunction(name: "sky_vertex"),
                  let fragFn = lib.makeFunction(name: "sky_fragment") else {
                nlLog("[SkyRenderer] sky_vertex / sky_fragment not found in library")
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

            guard let starVertex = lib.makeFunction(name: "sky_star_vertex"),
                  let starFragment = lib.makeFunction(name: "sky_star_fragment") else {
                nlLog("[SkyRenderer] sky_star_vertex / sky_star_fragment not found in library")
                return
            }
            desc.label = "skyStars"
            desc.vertexFunction = starVertex
            desc.fragmentFunction = starFragment
            let blend = desc.colorAttachments[0]!
            blend.isBlendingEnabled = true
            blend.rgbBlendOperation = .add
            blend.sourceRGBBlendFactor = .one
            blend.destinationRGBBlendFactor = .one
            blend.alphaBlendOperation = .add
            blend.sourceAlphaBlendFactor = .zero
            blend.destinationAlphaBlendFactor = .one
            starPipeline = try VRMPipelineCache.shared.getPipelineState(
                device: device, descriptor: desc, key: "skyStars")
        } catch {
            nlLog("[SkyRenderer] Pipeline setup failed: \(error)")
        }
    }

    private func setupDepthState() {
        let desc = MTLDepthStencilDescriptor()
        desc.depthCompareFunction = .always
        desc.isDepthWriteEnabled  = false
        depthState = device.makeDepthStencilState(descriptor: desc)
    }
}
