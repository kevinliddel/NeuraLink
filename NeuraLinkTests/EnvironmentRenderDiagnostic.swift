//
//  EnvironmentRenderDiagnostic.swift
//  NeuraLinkTests
//
//  Developer tool: renders an environment GLB offscreen through the real
//  EnvironmentRenderer (sun shadow pass + main pass, the catalogue's own
//  placement) and measures flicker — the share of pixels that change a lot
//  when the camera moves 3 mm, which is what z-fighting looks like. Writes a
//  picture and a flip mask per view. Set NL_ENV_DIAG_DIR to run, and
//  NL_ENV_DIAG_SCENES to "id=/path/to.glb,id2=/path2.glb".
//
//  Created by Dedicatus on 20/10/2026.
//

import CoreGraphics
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
import simd
@testable import NeuraLink

@Suite("Environment render diagnostic", .serialized)
struct EnvironmentRenderDiagnostic {

    private static let width = 390
    private static let height = 844

    @Test("Render environments and measure flicker when NL_ENV_DIAG_DIR is set")
    @MainActor
    func render() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["NL_ENV_DIAG_DIR"], !out.isEmpty,
              let device = MTLCreateSystemDefaultDevice()
        else { return }
        let outDir = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let scenes = (env["NL_ENV_DIAG_SCENES"] ?? "").split(separator: ",").compactMap { pair -> (String, URL)? in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], URL(fileURLWithPath: parts[1])) : nil
        }
        let label = env["NL_ENV_DIAG_LABEL"] ?? "run"
        var summary = ""
        for (id, url) in scenes {
            let option = EnvironmentCatalog.option(for: id)
            let renderer = EnvironmentRenderer(
                device: device, instanceConfig: option.instanceConfig,
                autoFitFootprint: option.autoFitFootprint, bakedLighting: option.bakedLighting,
                resolvesDuplicateFaces: option.resolvesDuplicateFaces)
            renderer.setup(config: RendererConfig(strict: .off))
            try await renderer.load(url: url)
            summary += "\(label) \(id): \(renderer.meshGroups.count) groups\n"
            let views: [(String, Float)] = [("front", 0), ("left", -0.45), ("right", 0.45)]
            for (name, yaw) in views {
                let eye = SIMD3<Float>(2.0 * sin(yaw), 1.25, 2.0 * cos(yaw))
                let frameA = try Self.renderFrame(renderer: renderer, device: device, eye: eye)
                let frameB = try Self.renderFrame(renderer: renderer, device: device, eye: eye + SIMD3<Float>(0.003, 0.002, 0))
                let (flipped, mask) = Self.flips(frameA, frameB)
                try Self.writePNG(frameA, to: outDir.appendingPathComponent("\(label)_\(id)_\(name).png"))
                try Self.writePNG(mask, to: outDir.appendingPathComponent("\(label)_\(id)_\(name)_flips.png"))
                summary += String(format: "  %@: %.3f%% of pixels flip on a 3 mm camera move\n", name, flipped * 100)
            }
        }
        try summary.write(to: outDir.appendingPathComponent("\(label)_summary.txt"), atomically: true, encoding: .utf8)
        #expect(!summary.isEmpty)
    }

    // MARK: - Rendering

    @MainActor
    private static func renderFrame(renderer: EnvironmentRenderer, device: MTLDevice, eye: SIMD3<Float>) throws -> [UInt8] {
        guard let queue = device.makeCommandQueue(), let cmd = queue.makeCommandBuffer() else { throw CancellationError() }
        func depthTexture(_ size: Int, usage: MTLTextureUsage) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: size, height: size, mipmapped: false)
            d.usage = usage; d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        // Sun high in the afternoon, as the sky system would place it.
        let sun = simd_normalize(SIMD3<Float>(0.45, 0.80, 0.35))
        let lightVP = TerrainRenderer.makeLightMatrix(sunDir: sun, wide: true)
        guard let wideShadow = depthTexture(TerrainRenderer.shadowMapSize, usage: [.renderTarget, .shaderRead]),
              let vrmShadow = depthTexture(4, usage: [.renderTarget, .shaderRead])
        else { throw CancellationError() }
        renderer.drawShadow(commandBuffer: cmd, shadowMap: wideShadow, lightViewProjection: lightVP, clearFirst: true)
        let clearVRM = MTLRenderPassDescriptor()
        clearVRM.depthAttachment.texture = vrmShadow
        clearVRM.depthAttachment.loadAction = .clear
        clearVRM.depthAttachment.clearDepth = 1
        clearVRM.depthAttachment.storeAction = .store
        cmd.makeRenderCommandEncoder(descriptor: clearVRM)?.endEncoding()

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        colorDesc.usage = [.renderTarget]; colorDesc.storageMode = .shared
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depthDesc.usage = [.renderTarget]; depthDesc.storageMode = .private
        guard let color = device.makeTexture(descriptor: colorDesc), let depth = device.makeTexture(descriptor: depthDesc)
        else { throw CancellationError() }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.62, green: 0.72, blue: 0.86, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare

        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear; samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge; samplerDesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc),
              let encoder = cmd.makeRenderCommandEncoder(descriptor: pass)
        else { throw CancellationError() }
        let view = OrthographicCamera.makeLookAt(eye: eye, target: SIMD3<Float>(0, 0.9, 0), up: SIMD3<Float>(0, 1, 0))
        let proj = makePerspective(fovyRadians: .pi / 3, aspectRatio: Float(width) / Float(height), nearZ: 0.1, farZ: 100)
        renderer.draw(
            encoder: encoder, viewProjection: proj * view, lightViewProjection: lightVP,
            vrmLightViewProjection: matrix_identity_float4x4, cameraPosition: eye,
            sunDirection: sun, sunHeight: sun.y, shadowSoft: 2.5,
            shadowMap: wideShadow, vrmShadowMap: vrmShadow, shadowSampler: sampler)
        encoder.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        var bgra = [UInt8](repeating: 0, count: width * height * 4)
        color.getBytes(&bgra, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        var rgba = bgra
        for i in stride(from: 0, to: rgba.count, by: 4) { rgba[i] = bgra[i + 2]; rgba[i + 2] = bgra[i] }
        return rgba
    }

    /// Share of pixels whose colour jumps by more than 20% between the frames,
    /// plus a mask painting them red over a dimmed copy of the first frame.
    private static func flips(_ a: [UInt8], _ b: [UInt8]) -> (Double, [UInt8]) {
        var mask = [UInt8](repeating: 0, count: a.count)
        var count = 0
        for i in stride(from: 0, to: a.count, by: 4) {
            let d = max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i + 1]) - Int(b[i + 1])), abs(Int(a[i + 2]) - Int(b[i + 2])))
            if d > 51 {
                count += 1
                mask[i] = 255; mask[i + 1] = 0; mask[i + 2] = 0
            } else {
                mask[i] = a[i] / 3; mask[i + 1] = a[i + 1] / 3; mask[i + 2] = a[i + 2] / 3
            }
            mask[i + 3] = 255
        }
        return (Double(count) / Double(a.count / 4), mask)
    }

    private static func writePNG(_ rgba: [UInt8], to url: URL) throws {
        let data = Data(rgba) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CancellationError() }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CancellationError() }
    }
}
