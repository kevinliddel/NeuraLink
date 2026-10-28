//
//  SkyRenderer.swift
//  NeuraLink
//
//  Created by Dedicatus on 17/04/2026.
//

import Metal
import simd

/// Renders the sky backdrop via a fullscreen triangle: the atmosphere from
/// its lookup tables (`encodeAtmosphere`, before the render pass), then the
/// sun, moon, clouds and stars. Encode this **before** any VRM draw calls so
/// the sky renders behind the model.
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

    // The atmosphere's lookup tables (SkyAtmosphere.metal): transmittance
    // and multiple scattering once, the sky view whenever a light moves.
    private var transmittancePipeline: MTLComputePipelineState?
    private var multipleScatteringPipeline: MTLComputePipelineState?
    private var skyViewPipeline: MTLComputePipelineState?
    private var transmittanceTable: MTLTexture?
    private var multipleScatteringTable: MTLTexture?
    /// The sky seen from the ground, as the fragment shader reads it.
    private(set) var skyViewTable: MTLTexture?
    private var atmosphereReady = false
    /// What the sky view was last lit with; nil until it has been.
    private(set) var skyViewLight: SkyViewParams?

    /// The noon sky's brightness as shown: the sun's light in the sky-view
    /// table at the reference exposure (`SkyAtmosphere.exposure` = 1).
    static let sunSkyLight: Float = 32
    /// A full moon's light on the sky, against the same scale: a faint blue
    /// sky around and above it, over the night's glow.
    static let moonSkyLight: Float = 1.2
    /// The sky view is lit again once a light has moved this far: 0.1°,
    /// about every 25 s.
    static let skyViewRefreshCosine: Float = cos(0.1 * .pi / 180)

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
        setupAtmosphere()
    }

    // MARK: - Per-frame update (main thread)

    /// Advances cloud time and re-derives the environment from the clock and place.
    /// Call this once per frame before `prepareForEncoding`.
    func update(deltaTime: Float) {
        cloudTime += deltaTime
        currentEnvironment = SkyEnvironment.resolve(at: timeProvider.now(), location: timeProvider.location)
    }

    // MARK: - Atmosphere (before the render pass)

    /// Builds the atmosphere's fixed tables the first time, and lights the
    /// sky view again when the sun or the moon has moved enough. Encode
    /// before the render pass that draws the sky.
    func encodeAtmosphere(commandBuffer: MTLCommandBuffer) {
        guard isEnabled, let transmittancePipeline, let multipleScatteringPipeline, let skyViewPipeline,
              let transmittanceTable, let multipleScatteringTable, let skyViewTable
        else { return }
        if !atmosphereReady {
            dispatch(transmittancePipeline, into: transmittanceTable, reading: [],
                     label: "SkyTransmittance", commandBuffer: commandBuffer)
            dispatch(multipleScatteringPipeline, into: multipleScatteringTable, reading: [transmittanceTable],
                     label: "SkyMultipleScattering", commandBuffer: commandBuffer)
            atmosphereReady = true
        }
        let env = currentEnvironment
        let moonLight = Self.moonSkyLight * env.moonBrightness
        if let last = skyViewLight,
           simd_dot(SIMD3<Float>(last.sun.x, last.sun.y, last.sun.z), env.sunDirection) > Self.skyViewRefreshCosine,
           simd_dot(SIMD3<Float>(last.moon.x, last.moon.y, last.moon.z), env.moonDirection) > Self.skyViewRefreshCosine,
           abs(last.moon.w - moonLight) < 0.01 {
            return
        }
        let sunElevation = asin(min(1, max(-1, env.sunDirection.y)))
        let light = SkyViewParams(
            sun: SIMD4<Float>(env.sunDirection, Self.sunSkyLight * SkyAtmosphere.exposure(sunElevation: sunElevation)),
            moon: SIMD4<Float>(env.moonDirection, moonLight))
        dispatch(skyViewPipeline, into: skyViewTable, reading: [transmittanceTable, multipleScatteringTable],
                 view: light, label: "SkyView", commandBuffer: commandBuffer)
        skyViewLight = light
    }

    private func dispatch(
        _ pipeline: MTLComputePipelineState, into table: MTLTexture, reading inputs: [MTLTexture],
        view: SkyViewParams? = nil, label: String, commandBuffer: MTLCommandBuffer
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = label
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(table, index: 0)
        for (index, input) in inputs.enumerated() { encoder.setTexture(input, index: index + 1) }
        var params = SkyAtmosphere.gpuParams
        encoder.setBytes(&params, length: MemoryLayout<SkyAtmosphereParams>.stride, index: 0)
        if var view { encoder.setBytes(&view, length: MemoryLayout<SkyViewParams>.stride, index: 1) }
        let group = MTLSize(width: 8, height: 8, depth: 1)
        encoder.dispatchThreadgroups(
            MTLSize(width: (table.width + 7) / 8, height: (table.height + 7) / 8, depth: 1),
            threadsPerThreadgroup: group)
        encoder.endEncoding()
    }

    // MARK: - Render thread

    /// Assembles the GPU uniform buffer using the latest environment + camera matrices.
    /// Must be called from the render thread immediately before `encode`.
    func prepareForEncoding(viewProjection: simd_float4x4) {
        let env = currentEnvironment
        let sd  = env.sunDirection
        let md  = env.moonDirection
        let ri  = rainIntensity

        // Rain overrides: denser clouds, no stars, a drained, darker sky (the
        // shader's skyOvercast).
        let cloudCoverage  = env.cloudCoverage  + (0.92 - env.cloudCoverage)  * ri
        let starVisibility = env.starVisibility * max(0, 1.0 - ri * 0.95)
        let darkFactor     = 1.0 - ri * 0.28

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
            nightGlowLow: SIMD4<Float>(env.nightGlowLow, ri),
            nightGlowHigh: SIMD4<Float>(env.nightGlowHigh, 0),
            cloudParams: SIMD4<Float>(cloudTime, env.cloudSpeed, cloudCoverage, starVisibility),
            moonDirectionAndPhase: SIMD4<Float>(md.x, md.y, md.z, env.moonIllumination),
            bodyParams: SIMD4<Float>(Self.moonAngularRadius, 0, env.moonBrightness, 0),
            starRotation: env.starRotation
        )
        uniformBuffer?.contents().copyMemory(
            from: &data, byteCount: MemoryLayout<SkyUniformsData>.stride)
    }

    /// Encodes the sky fullscreen draw into the active render encoder.
    func encode(encoder: MTLRenderCommandEncoder) {
        // Nothing to draw until the sky view has been lit once.
        guard isEnabled, let pipeline, let buf = uniformBuffer, skyViewLight != nil, let skyViewTable
        else { return }
        encoder.pushDebugGroup("SkyBackground")
        encoder.setRenderPipelineState(pipeline)
        if let depth = depthState { encoder.setDepthStencilState(depth) }
        encoder.setCullMode(.none)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setFragmentBuffer(buf, offset: 0, index: 0)
        encoder.setFragmentTexture(skyViewTable, index: 0)
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

    private func setupAtmosphere() {
        func table(_ width: Int, _ height: Int, _ label: String) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            let texture = device.makeTexture(descriptor: descriptor)
            texture?.label = label
            return texture
        }
        transmittanceTable = table(256, 64, "SkyTransmittance")
        multipleScatteringTable = table(32, 32, "SkyMultipleScattering")
        skyViewTable = table(192, 108, "SkyView")
        do {
            let lib = try VRMPipelineCache.shared.getLibrary(device: device)
            guard let transmittance = lib.makeFunction(name: "sky_transmittance_lut"),
                  let multiple = lib.makeFunction(name: "sky_multiscattering_lut"),
                  let view = lib.makeFunction(name: "sky_view_lut") else {
                nlLog("[SkyRenderer] atmosphere kernels not found in library", level: .error)
                return
            }
            transmittancePipeline = try device.makeComputePipelineState(function: transmittance)
            multipleScatteringPipeline = try device.makeComputePipelineState(function: multiple)
            skyViewPipeline = try device.makeComputePipelineState(function: view)
        } catch {
            nlLog("[SkyRenderer] atmosphere pipeline setup failed: \(error)", level: .error)
        }
    }

    private func setupDepthState() {
        let desc = MTLDepthStencilDescriptor()
        desc.depthCompareFunction = .always
        desc.isDepthWriteEnabled  = false
        depthState = device.makeDepthStencilState(descriptor: desc)
    }
}
