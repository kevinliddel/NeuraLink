//
//  RainWorldRenderer.swift
//  NeuraLink
//
//  World-space 3D rain renderer: streaks and ripples.
//

import Metal
import simd
import QuartzCore

struct Rain3DParticleGPU {
    var spawnXZ_phase_speed: SIMD4<Float> // x,z = spawn, y = phase, w = speed
    var color: SIMD4<Float>               // rgba
} // 32 bytes

struct RainWorldUniforms {
    var viewProjection: simd_float4x4 // offset   0, size 64
    var cameraPos: SIMD3<Float>       // offset  64, size 16 (Swift SIMD3 is self-padded to 16 bytes)
    var time: Float                   // offset  80, size  4  — matches Metal float3 + implicit pad
    var intensity: Float              // offset  84, size  4
    var wind: SIMD2<Float>            // offset  88, size  8

    init(viewProjection: simd_float4x4, cameraPos: SIMD3<Float>, time: Float, intensity: Float, wind: SIMD2<Float>) {
        self.viewProjection = viewProjection
        self.cameraPos = cameraPos
        self.time = time
        self.intensity = intensity
        self.wind = wind
    }
} // total 96 bytes — matches Metal struct exactly

final class RainWorldRenderer {
    
    private let device: MTLDevice
    private let simulator = RainWorldSimulator()
    
    private var streakPipeline: MTLRenderPipelineState?
    private var depthStencilState: MTLDepthStencilState?
    
    private var particleBuffer: MTLBuffer?
    private var uniformsBuffer: MTLBuffer?
    
    private var elapsedTime: Float = 0
    
    init(device: MTLDevice, config: RendererConfig) {
        self.device = device
        setupBuffers()
        setupPipelines(config: config)
        setupDepthStencil()
    }
    
    private var particlesUploaded = false

    func update(deltaTime: Float, intensity: Float, cameraPos: SIMD3<Float>, viewProjection: simd_float4x4) {
        // Use a more robust time source that is independent of deltaTime
        let time = Float(CACurrentMediaTime().truncatingRemainder(dividingBy: 10000))
        
        if !particlesUploaded {
            uploadParticles()
            particlesUploaded = true
        }
        
        updateUniforms(
            viewProjection: viewProjection,
            cameraPos: cameraPos,
            time: time,
            intensity: intensity,
            wind: SIMD2<Float>(-0.28, -0.12)
        )
    }
    
    func draw(encoder: MTLRenderCommandEncoder) {
        guard let streakPso = streakPipeline,
              let ds = depthStencilState,
              let pBuf = particleBuffer,
              let uBuf = uniformsBuffer else { return }
        
        encoder.pushDebugGroup("RainWorld")
        encoder.setDepthStencilState(ds)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(pBuf, offset: 0, index: 0)
        encoder.setVertexBuffer(uBuf, offset: 0, index: 1)
        encoder.setFragmentBuffer(uBuf, offset: 0, index: 1)
        
        encoder.setRenderPipelineState(streakPso)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: simulator.maxParticles * 6)
        
        encoder.popDebugGroup()
    }
    
    private func setupBuffers() {
        particleBuffer = device.makeBuffer(
            length: MemoryLayout<Rain3DParticleGPU>.stride * simulator.maxParticles,
            options: .storageModeShared
        )
        particleBuffer?.label = "RainWorldParticles"
        
        uniformsBuffer = device.makeBuffer(
            length: MemoryLayout<RainWorldUniforms>.stride,
            options: .storageModeShared
        )
        uniformsBuffer?.label = "RainWorldUniforms"
    }
    
    private func setupPipelines(config: RendererConfig) {
        do {
            let lib = try VRMPipelineCache.shared.getLibrary(device: device)
            
            // Streak pipeline
            if let vFn = lib.makeFunction(name: "rain_world_vertex"),
               let fFn = lib.makeFunction(name: "rain_world_fragment") {
                let desc = MTLRenderPipelineDescriptor()
                desc.label = "rain_world_streaks"
                desc.vertexFunction = vFn
                desc.fragmentFunction = fFn
                desc.colorAttachments[0].pixelFormat = config.colorPixelFormat
                desc.colorAttachments[0].isBlendingEnabled = true
                desc.colorAttachments[0].rgbBlendOperation = .add
                desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
                desc.colorAttachments[0].destinationRGBBlendFactor = .one
                desc.depthAttachmentPixelFormat = .depth32Float
                desc.rasterSampleCount = config.sampleCount
                streakPipeline = try device.makeRenderPipelineState(descriptor: desc)
            }
            
        } catch {
            print("[RainWorldRenderer] Pipeline setup failed: \(error)")
        }
    }
    
    private func setupDepthStencil() {
        let desc = MTLDepthStencilDescriptor()
        desc.depthCompareFunction = .less
        desc.isDepthWriteEnabled = false // Transparent rain doesn't write depth
        depthStencilState = device.makeDepthStencilState(descriptor: desc)
    }
    
    private func uploadParticles() {
        guard let pBuf = particleBuffer else { return }
        let ptr = pBuf.contents().bindMemory(to: Rain3DParticleGPU.self, capacity: simulator.maxParticles)
        
        for i in 0..<simulator.maxParticles {
            let p = simulator.particles[i]
            ptr[i] = Rain3DParticleGPU(
                spawnXZ_phase_speed: SIMD4<Float>(p.spawnX, p.phase, p.spawnZ, p.speed),
                color: SIMD4<Float>(0.72, 0.87, 1.0, 0.45)
            )
        }
    }
    
    private func updateUniforms(viewProjection: simd_float4x4, cameraPos: SIMD3<Float>, time: Float, intensity: Float, wind: SIMD2<Float>) {
        guard let uBuf = uniformsBuffer else { return }
        var u = RainWorldUniforms(
            viewProjection: viewProjection,
            cameraPos: cameraPos,
            time: time,
            intensity: intensity,
            wind: wind
        )
        uBuf.contents().copyMemory(from: &u, byteCount: MemoryLayout<RainWorldUniforms>.stride)
    }
}
