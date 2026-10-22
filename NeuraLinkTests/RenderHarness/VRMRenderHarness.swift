//
//  VRMRenderHarness.swift
//  NeuraLinkTests
//
//  Renders a model through the app's own VRMRenderer into an offscreen
//  texture and reads the pixels back, the way VRMPartThumbnailRenderer
//  does for catalogue tiles: no sky, no ground, spring bones and look-at
//  off, a fixed light rig. Render probes assert properties of the result
//  (an edge has intermediate coverage, a fringe isn't dark); character
//  snapshots write the image out for side-by-side review.
//
//  Created by Dedicatus on 22/10/2026.
//

import Foundation
import Metal
import simd
@testable import NeuraLink

/// Read-back pixels: sRGB-encoded BGRA8 as the drawable stores them, row 0
/// at the top.
struct RenderedImage {
    let width: Int
    let height: Int
    let bgra: [UInt8]

    /// sRGB-encoded colour (0…1) and alpha at a pixel.
    func pixel(_ x: Int, _ y: Int) -> SIMD4<Float> {
        let index = (y * width + x) * 4
        return SIMD4(Float(bgra[index + 2]), Float(bgra[index + 1]), Float(bgra[index]), Float(bgra[index + 3])) / 255
    }

    /// The row through the middle, left to right.
    func row(_ y: Int) -> [SIMD4<Float>] { (0..<width).map { pixel($0, y) } }

    func png() -> Data {
        var rgba = [UInt8](repeating: 0, count: bgra.count)
        for index in stride(from: 0, to: bgra.count, by: 4) {
            rgba[index] = bgra[index + 2]
            rgba[index + 1] = bgra[index + 1]
            rgba[index + 2] = bgra[index]
            rgba[index + 3] = bgra[index + 3]
        }
        return TestPNG.encode(width: width, height: height, rgba: rgba)
    }
}

@MainActor
final class VRMRenderHarness {
    let device: MTLDevice
    let renderer: VRMRenderer
    let size: Int

    init?(size: Int = 128, sampleCount: Int = 1) {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.device = device
        self.size = size
        renderer = VRMRenderer(device: device, config: RendererConfig(strict: .off, sampleCount: sampleCount))
        renderer.skyRenderer = nil
        renderer.terrainRenderer = nil
        renderer.environmentRenderer = nil
        renderer.enableSpringBone = false
        // One white key light from the camera side and no ambient, so a
        // surface facing the camera renders exactly its base colour.
        renderer.setLight(0, direction: SIMD3<Float>(0, 0, -1), color: SIMD3<Float>(1, 1, 1), intensity: 1)
        renderer.setLight(1, direction: SIMD3<Float>(0, -1, 0), color: SIMD3<Float>(1, 1, 1), intensity: 0)
        renderer.setLight(2, direction: SIMD3<Float>(0, -1, 0), color: SIMD3<Float>(1, 1, 1), intensity: 0)
        renderer.setAmbientColor(.zero)
    }

    /// Loads a synthetic VRM through the real loader.
    func load(_ synthetic: SyntheticVRM) async throws -> VRMModel {
        try await VRMModel.load(from: synthetic.glb(), filePath: "probe.vrm", device: device)
    }

    /// Renders `model` seen from `eye` towards `target`; tilting `up` rolls
    /// the image. `clear` is the background (straight RGBA).
    func render(
        _ model: VRMModel, eye: SIMD3<Float> = [0, 1, 1.6], target: SIMD3<Float> = [0, 1, 0],
        up: SIMD3<Float> = [0, 1, 0], clear: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    ) -> RenderedImage? {
        defer { renderer.clearModel() }
        model.updateNodeTransforms()
        renderer.loadModel(model)
        renderer.isModelVisible = true
        renderer.enableSpringBone = false
        renderer.lookAtController?.enabled = false
        renderer.viewMatrix = OrthographicCamera.makeLookAt(eye: eye, target: target, up: simd_normalize(up))
        renderer.projectionMatrix = renderer.makeProjectionMatrix(aspectRatio: 1)

        guard let color = texture(storage: .private, usage: [.renderTarget, .shaderRead]),
              let readback = texture(storage: .shared, usage: [.shaderRead]),
              let descriptor = passDescriptor(color: color, clear: clear),
              let depth = descriptor.depthAttachment.texture,
              let commandBuffer = renderer.commandQueue.makeCommandBuffer()
        else { return nil }
        renderer.drawOffscreenHeadless(to: color, depth: depth, commandBuffer: commandBuffer, renderPassDescriptor: descriptor)
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: color, to: readback)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        readback.getBytes(&bytes, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        return RenderedImage(width: size, height: size, bgra: bytes)
    }

    private func texture(storage: MTLStorageMode, usage: MTLTextureUsage) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: renderer.config.colorPixelFormat, width: size, height: size, mipmapped: false)
        descriptor.storageMode = storage
        descriptor.usage = usage
        return device.makeTexture(descriptor: descriptor)
    }

    private func passDescriptor(color: MTLTexture, clear: MTLClearColor) -> MTLRenderPassDescriptor? {
        // MSAA through the scene's own helper, so the probe covers it.
        if renderer.usesMultisampling {
            return renderer.multisamplePassDescriptor(resolvingInto: color, clearColor: clear)
        }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = color
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = clear
        let depth = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: size, height: size, mipmapped: false)
        depth.storageMode = .private
        depth.usage = [.renderTarget]
        guard let depthTexture = device.makeTexture(descriptor: depth) else { return nil }
        descriptor.depthAttachment.texture = depthTexture
        descriptor.depthAttachment.loadAction = .clear
        descriptor.depthAttachment.storeAction = .dontCare
        descriptor.depthAttachment.clearDepth = 1
        return descriptor
    }
}
