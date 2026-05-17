//
//  VRMRenderer+GodRays.swift
//  NeuraLink
//
//  Volumetric god rays (screen-space radial blur from the sun).
//  Reuses `ssaoDepthTexture` — populated each frame by the main forward pass
//  before this system runs.

import Foundation
import Metal
import simd

// MARK: - GPU uniform layout (must mirror GodRayUniforms in GodRayShader.metal, 96 bytes)

struct GodRayUniforms {
    var inverseProjection: simd_float4x4  // offset  0, 64 bytes
    var sunScreenUV: SIMD2<Float>         // offset 64,  8 bytes
    var sunIntensity: Float               // offset 72,  4 bytes
    var sunHeight: Float                  // offset 76,  4 bytes
    var sunColor: SIMD4<Float>            // offset 80, 16 bytes
}

// MARK: - God rays extension

extension VRMRenderer {

    // MARK: Setup

    func setupGodRays() {
        do {
            let lib = try VRMPipelineCache.shared.getLibrary(device: device)

            guard let vertFn  = lib.makeFunction(name: "godray_vertex"),
                  let maskFn  = lib.makeFunction(name: "godray_mask_fragment"),
                  let blurFn  = lib.makeFunction(name: "godray_blur_fragment"),
                  let compFn  = lib.makeFunction(name: "godray_composite_fragment")
            else {
                vrmLog("[GodRays] Shader functions not found — god rays disabled")
                return
            }

            // Pass 1: mask — sky brightness near the sun → r8Unorm at ¼ res.
            let maskDesc = MTLRenderPipelineDescriptor()
            maskDesc.label = "godray_mask"
            maskDesc.vertexFunction = vertFn
            maskDesc.fragmentFunction = maskFn
            maskDesc.rasterSampleCount = 1
            maskDesc.colorAttachments[0].pixelFormat = .r8Unorm
            maskDesc.colorAttachments[0].isBlendingEnabled = false
            godRayMaskPipeline = try VRMPipelineCache.shared.getPipelineState(
                device: device, descriptor: maskDesc, key: "godray_mask")

            // Pass 2: radial blur → same format.
            let blurDesc = MTLRenderPipelineDescriptor()
            blurDesc.label = "godray_blur"
            blurDesc.vertexFunction = vertFn
            blurDesc.fragmentFunction = blurFn
            blurDesc.rasterSampleCount = 1
            blurDesc.colorAttachments[0].pixelFormat = .r8Unorm
            blurDesc.colorAttachments[0].isBlendingEnabled = false
            godRayBlurPipeline = try VRMPipelineCache.shared.getPipelineState(
                device: device, descriptor: blurDesc, key: "godray_blur")

            // Pass 3: composite — additive blend of tinted rays onto the scene.
            let compDesc = MTLRenderPipelineDescriptor()
            compDesc.label = "godray_composite"
            compDesc.vertexFunction = vertFn
            compDesc.fragmentFunction = compFn
            compDesc.rasterSampleCount = 1
            let ca = compDesc.colorAttachments[0]!
            ca.pixelFormat = config.colorPixelFormat
            ca.isBlendingEnabled = true
            ca.rgbBlendOperation = .add
            ca.alphaBlendOperation = .add
            ca.sourceRGBBlendFactor = .sourceAlpha    // tinted × rayBrightness
            ca.destinationRGBBlendFactor = .one       // + scene colour
            ca.sourceAlphaBlendFactor = .one
            ca.destinationAlphaBlendFactor = .one
            godRayCompositePipeline = try VRMPipelineCache.shared.getPipelineState(
                device: device, descriptor: compDesc, key: "godray_composite")

            godRayUniformsBuffer = device.makeBuffer(
                length: MemoryLayout<GodRayUniforms>.stride,
                options: .storageModeShared)
            godRayUniformsBuffer?.label = "GodRayUniforms"

        } catch {
            vrmLog("[GodRays] Setup failed: \(error)")
        }
    }

    // MARK: Resize

    /// Creates or recreates the ¼-resolution mask and blur textures.
    func resizeGodRayTextures(_ size: CGSize) {
        let w = max(1, Int(size.width)  / 4)
        let h = max(1, Int(size.height) / 4)

        func tex(_ label: String) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            let t = device.makeTexture(descriptor: d)
            t?.label = label
            return t
        }

        godRayMaskTexture = tex("GodRay Mask")
        godRayBlurTexture = tex("GodRay Blur")
    }

    // MARK: Draw

    /// Runs the god ray chain after the main scene encoder has ended.
    /// Requires `ssaoDepthTexture` to be populated (set by the SSAO depth swap).
    func drawGodRays(
        commandBuffer: MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor
    ) {
        guard enableGodRays,
              let depthTex  = ssaoDepthTexture,
              let maskTex   = godRayMaskTexture,
              let blurTex   = godRayBlurTexture,
              let maskPSO   = godRayMaskPipeline,
              let blurPSO   = godRayBlurPipeline,
              let compPSO   = godRayCompositePipeline,
              let uniBuf    = godRayUniformsBuffer
        else { return }

        // ── Build uniforms ────────────────────────────────────────────────────────
        let env        = skyRenderer?.currentEnvironment
        let rawSun     = env?.sunDirection ?? SIMD3<Float>(0, 1, 0)
        let sunHeight  = rawSun.y
        // Keep sun above horizon for projection (mirrors the shadow-pass convention).
        let effectiveSun: SIMD3<Float> = rawSun.y >= 0 ? rawSun : rawSun * -1.0

        // Project sun to screen UV.
        let invView   = viewMatrix.inverse
        let camPos    = SIMD3<Float>(invView[3][0], invView[3][1], invView[3][2])
        let sunWorld  = SIMD4<Float>(camPos + effectiveSun * 50.0, 1.0)
        let sunClip   = projectionMatrix * (viewMatrix * sunWorld)
        let sunNDC    = SIMD2<Float>(sunClip.x, sunClip.y) / sunClip.w
        let sunUV     = sunNDC * SIMD2<Float>(0.5, -0.5) + SIMD2<Float>(0.5, 0.5)

        // Sun color from sky palette, dimmed at night.
        let rawColor  = env?.keyLightColor ?? SIMD3<Float>(1, 0.95, 0.8)
        let intensity = (env?.keyLightIntensity ?? 1.0) * max(0, sunHeight + 0.1)
        let sunColor  = SIMD4<Float>(rawColor * min(intensity, 1.5), 0)

        var u = GodRayUniforms(
            inverseProjection: projectionMatrix.inverse,
            sunScreenUV: sunUV,
            sunIntensity: 1.0,
            sunHeight: sunHeight,
            sunColor: sunColor
        )
        uniBuf.contents().copyMemory(from: &u, byteCount: MemoryLayout<GodRayUniforms>.stride)

        // ── Pass 1: mask (¼ resolution) ───────────────────────────────────────────
        let maskPass = MTLRenderPassDescriptor()
        maskPass.colorAttachments[0].texture     = maskTex
        maskPass.colorAttachments[0].loadAction  = .dontCare
        maskPass.colorAttachments[0].storeAction = .store

        guard let maskEnc = commandBuffer.makeRenderCommandEncoder(descriptor: maskPass) else { return }
        maskEnc.label = "GodRay Mask"
        maskEnc.setRenderPipelineState(maskPSO)
        maskEnc.setFragmentTexture(depthTex, index: 0)
        maskEnc.setFragmentBuffer(uniBuf, offset: 0, index: 0)
        maskEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        maskEnc.endEncoding()

        // ── Pass 2: radial blur (¼ resolution) ────────────────────────────────────
        let blurPass = MTLRenderPassDescriptor()
        blurPass.colorAttachments[0].texture     = blurTex
        blurPass.colorAttachments[0].loadAction  = .dontCare
        blurPass.colorAttachments[0].storeAction = .store

        guard let blurEnc = commandBuffer.makeRenderCommandEncoder(descriptor: blurPass) else { return }
        blurEnc.label = "GodRay Blur"
        blurEnc.setRenderPipelineState(blurPSO)
        blurEnc.setFragmentTexture(maskTex, index: 0)
        blurEnc.setFragmentBuffer(uniBuf, offset: 0, index: 0)
        blurEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        blurEnc.endEncoding()

        // ── Pass 3: composite into drawable ───────────────────────────────────────
        let target = renderPassDescriptor.colorAttachments[0].resolveTexture
                  ?? renderPassDescriptor.colorAttachments[0].texture
        guard let target else { return }

        let compPass = MTLRenderPassDescriptor()
        compPass.colorAttachments[0].texture     = target
        compPass.colorAttachments[0].loadAction  = .load
        compPass.colorAttachments[0].storeAction = .store

        guard let compEnc = commandBuffer.makeRenderCommandEncoder(descriptor: compPass) else { return }
        compEnc.label = "GodRay Composite"
        compEnc.setRenderPipelineState(compPSO)
        compEnc.setFragmentTexture(blurTex, index: 0)
        compEnc.setFragmentBuffer(uniBuf, offset: 0, index: 0)
        compEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        compEnc.endEncoding()
    }
}
