//
//  RainRenderer.swift
//  NeuraLink
//
//  Rain-on-glass / camera-lens effect — Metal compute + overlay render passes.
//
//  Created by Dedicatus on 27/04/2026.
//

import Foundation
import Metal
import simd

// MARK: - GPU structures (byte layout must match RainShader.metal)

struct RainDropGPU {
    var position: SIMD2<Float>  //  8 bytes
    var radius: Float  //  4 bytes
    var alpha: Float  //  4 bytes
    var spreadX: Float  //  4 bytes
    var spreadY: Float  //  4 bytes
    var _pad: SIMD2<Float>  //  8 bytes  (total: 32 bytes)

    init(x: Float, y: Float, r: Float, alpha: Float, spreadX: Float, spreadY: Float) {
        position = SIMD2(x, y)
        radius = r
        self.alpha = alpha
        self.spreadX = spreadX
        self.spreadY = spreadY
        _pad = .zero
    }
}

struct RainUniformsGPU {
    var alphaMultiply: Float  // 4
    var alphaSubtract: Float  // 4
    var brightness: Float  // 4
    var intensity: Float  // 4
    var waterMapWidth: Float  // 4
    var waterMapHeight: Float  // 4
    // total: 24 bytes
}

// MARK: - Metal renderer

final class RainRenderer {

    static let waterMapWidth: Int = 256
    static let waterMapHeight: Int = 512

    private static let maxDropsBuffer = 260  // main drops (≤180) + droplets (≤80)

    private let device: MTLDevice

    private var computePipeline: MTLComputePipelineState?
    private var renderPipeline: MTLRenderPipelineState?
    private var waterMapTexture: MTLTexture?
    private var dropsBuffer: MTLBuffer?
    private var uniformsBuffer: MTLBuffer?

    private let simulator = RainSimulator()
    let controller = RainController()

    var intensity: Float { controller.intensity }
    var isIdle: Bool { controller.isIdle }

    init(device: MTLDevice, config: RendererConfig) {
        self.device = device
        setupTexture()
        setupBuffers()
        setupPipelines(config: config)
    }

    // MARK: - Per-frame update (main thread)

    func update(deltaTime dt: Float) {
        controller.update(deltaTime: dt)
        guard !controller.isIdle else { return }
        simulator.update(ts: min(dt * 60, 1.5), intensity: controller.intensity)
        uploadDrops()
        updateUniforms()
    }

    // MARK: - Encode: compute pass (generates water map)

    func encodeWaterMap(commandBuffer: MTLCommandBuffer) {
        guard !controller.isIdle,
            let pipeline = computePipeline,
            let tex = waterMapTexture
        else { return }

        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.pushDebugGroup("RainWaterMap")
        enc.setComputePipelineState(pipeline)
        enc.setTexture(tex, index: 0)
        enc.setBuffer(dropsBuffer, offset: 0, index: 0)
        let totalDrops =
            min(simulator.drops.count, simulator.maxDrops)
            + min(simulator.droplets.count, simulator.maxDroplets)
        var count = UInt32(min(totalDrops, Self.maxDropsBuffer))
        enc.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 1)

        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(
            width: (Self.waterMapWidth + 15) / 16,
            height: (Self.waterMapHeight + 15) / 16,
            depth: 1
        )
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.popDebugGroup()
        enc.endEncoding()
    }

    // MARK: - Encode: overlay render pass

    func encodeOverlay(commandBuffer: MTLCommandBuffer, targetTexture: MTLTexture) {
        guard !controller.isIdle,
            let pipeline = renderPipeline,
            let tex = waterMapTexture,
            let uBuf = uniformsBuffer
        else { return }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = targetTexture
        passDesc.colorAttachments[0].loadAction = .load
        passDesc.colorAttachments[0].storeAction = .store

        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }
        enc.pushDebugGroup("RainOverlay")
        enc.setRenderPipelineState(pipeline)
        enc.setCullMode(.none)
        enc.setFragmentTexture(tex, index: 0)
        enc.setFragmentBuffer(uBuf, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.popDebugGroup()
        enc.endEncoding()
    }

    // MARK: - Private setup

    private func setupTexture() {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: Self.waterMapWidth,
            height: Self.waterMapHeight,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        waterMapTexture = device.makeTexture(descriptor: desc)
        waterMapTexture?.label = "RainWaterMap"
    }

    private func setupBuffers() {
        dropsBuffer = device.makeBuffer(
            length: MemoryLayout<RainDropGPU>.stride * Self.maxDropsBuffer,
            options: .storageModeShared
        )
        dropsBuffer?.label = "RainDrops"

        uniformsBuffer = device.makeBuffer(
            length: MemoryLayout<RainUniformsGPU>.stride,
            options: .storageModeShared
        )
        uniformsBuffer?.label = "RainUniforms"
    }

    private func setupPipelines(config: RendererConfig) {
        do {
            let lib = try VRMPipelineCache.shared.getLibrary(device: device)

            guard let computeFn = lib.makeFunction(name: "rain_watermap") else {
                vrmLog("[RainRenderer] rain_watermap not found")
                return
            }
            computePipeline = try device.makeComputePipelineState(function: computeFn)

            guard let vertFn = lib.makeFunction(name: "rain_vertex"),
                let fragFn = lib.makeFunction(name: "rain_fragment")
            else {
                vrmLog("[RainRenderer] rain_vertex / rain_fragment not found")
                return
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "rain_overlay"
            desc.vertexFunction = vertFn
            desc.fragmentFunction = fragFn
            desc.rasterSampleCount = 1
            let ca = desc.colorAttachments[0]!
            ca.pixelFormat = .bgra8Unorm
            ca.isBlendingEnabled = true
            ca.rgbBlendOperation = .add
            ca.alphaBlendOperation = .add
            ca.sourceRGBBlendFactor = .sourceAlpha
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.sourceAlphaBlendFactor = .one
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha

            renderPipeline = try VRMPipelineCache.shared.getPipelineState(
                device: device, descriptor: desc, key: "rain_overlay")
        } catch {
            vrmLog("[RainRenderer] Pipeline setup failed: \(error)")
        }
    }

    private func uploadDrops() {
        guard let buf = dropsBuffer else { return }
        let ptr = buf.contents().bindMemory(to: RainDropGPU.self, capacity: Self.maxDropsBuffer)

        let mainDrops = simulator.drops.prefix(simulator.maxDrops)
        let remaining = Self.maxDropsBuffer - mainDrops.count
        let droplets = simulator.droplets.prefix(remaining)

        var idx = 0
        for d in mainDrops {
            ptr[idx] = RainDropGPU(
                x: d.x, y: d.y, r: d.r,
                alpha: d.alpha, spreadX: d.spreadX, spreadY: d.spreadY)
            idx += 1
        }
        for d in droplets {
            ptr[idx] = RainDropGPU(
                x: d.x, y: d.y, r: d.r,
                alpha: d.alpha, spreadX: d.spreadX, spreadY: d.spreadY)
            idx += 1
        }
        // Zero-fill remaining slots so the shader ignores them
        while idx < Self.maxDropsBuffer {
            ptr[idx] = RainDropGPU(x: 0, y: 0, r: 0, alpha: 0, spreadX: 0, spreadY: 0)
            idx += 1
        }
    }

    private func updateUniforms() {
        guard let buf = uniformsBuffer else { return }
        var u = RainUniformsGPU(
            alphaMultiply: 16.0,
            alphaSubtract: 4.0,
            brightness: 1.04,
            intensity: controller.intensity,
            waterMapWidth: Float(Self.waterMapWidth),
            waterMapHeight: Float(Self.waterMapHeight)
        )
        buf.contents().copyMemory(from: &u, byteCount: MemoryLayout<RainUniformsGPU>.stride)
    }
}
