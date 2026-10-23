//
//  VRMRenderSnapshots.swift
//  NeuraLinkTests
//
//  Review renders, not assertions: the three bundled characters (Oz and
//  Ekaterina are VRM 0.x, Sonya 1.0), plus any imported ones, drawn through
//  the app's renderer with a fixed light rig and camera — face, mouth open,
//  smiling (eyes closed), three-quarter and full figure — and written as
//  PNGs for side-by-side comparison of a rendering change.
//
//  Self-contained on purpose (only APIs older than the change it reviews), so
//  the same file can render the "before" from the previous commit.
//
//  NL_RENDER_SNAPSHOT_DIR: output folder (unset = skip).
//  NL_RENDER_SNAPSHOT_SAMPLES: MSAA samples (default 1).
//  NL_RENDER_SNAPSHOT_EXTRA: more .vrm paths, colon-separated.
//  NL_RENDER_SNAPSHOT_SPRINGS=1: spring bones on, settled for a second of
//  frames before the shots (files get a "_springs" suffix).
//
//  Created by Dedicatus on 22/10/2026.
//

import Foundation
import Metal
import Testing
import UIKit
@testable import NeuraLink

@MainActor
@Suite("VRM render snapshots", .serialized)
struct VRMRenderSnapshots {

    private static let size = 768

    @Test("Writes character renders when NL_RENDER_SNAPSHOT_DIR is set")
    func characters() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["NL_RENDER_SNAPSHOT_DIR"], let device = MTLCreateSystemDefaultDevice() else { return }
        let samples = Int(env["NL_RENDER_SNAPSHOT_SAMPLES"] ?? "") ?? 1
        let dir = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let renderer = VRMRenderer(device: device, config: RendererConfig(strict: .off, sampleCount: samples))
        renderer.skyRenderer = nil
        renderer.terrainRenderer = nil
        renderer.environmentRenderer = nil
        let springs = env["NL_RENDER_SNAPSHOT_SPRINGS"] == "1"
        renderer.enableSpringBone = false
        renderer.materialTimeOverride = 0
        renderer.setLight(0, direction: [0.25, -0.35, -0.90], color: [1.00, 0.99, 0.97], intensity: 0.95)
        renderer.setLight(1, direction: [-0.45, -0.15, -0.85], color: [0.88, 0.90, 0.96], intensity: 0.55)
        renderer.setLight(2, direction: [0.0, 0.75, -0.65], color: [0.95, 0.95, 1.00], intensity: 0.45)
        renderer.setAmbientColor(SIMD3<Float>(repeating: 0.42))

        var urls = try ["Oz", "Sonya", "Ekaterina"].map {
            try #require(Bundle.main.url(forResource: $0, withExtension: "vrm"))
        }
        urls += (env["NL_RENDER_SNAPSHOT_EXTRA"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }

        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            let model = try await VRMModel.load(from: url, device: device)
            model.updateNodeTransforms()
            renderer.loadModel(model)
            renderer.isModelVisible = true
            renderer.lookAtController?.enabled = false
            if springs {
                renderer.enableSpringBone = true
                for _ in 0..<60 { _ = Self.render(renderer, device: device, samples: samples) }
            }
            for shot in Self.shots(for: model) {
                if let expression = shot.expression { renderer.expressionController?.setExpressionWeight(expression, weight: 1) }
                defer { if let expression = shot.expression { renderer.expressionController?.setExpressionWeight(expression, weight: 0) } }
                renderer.viewMatrix = OrthographicCamera.makeLookAt(eye: shot.eye, target: shot.target, up: [0, 1, 0])
                renderer.projectionMatrix = renderer.makeProjectionMatrix(aspectRatio: 1)
                let png = try #require(Self.render(renderer, device: device, samples: samples))
                try png.write(to: dir.appendingPathComponent("\(name)_\(shot.name)\(springs ? "_springs" : "").png"))
            }
            renderer.clearModel()
        }
    }

    private struct Shot {
        let name: String
        let eye: SIMD3<Float>
        let target: SIMD3<Float>
        var expression: VRMExpressionPreset?
    }

    private static func shots(for model: VRMModel) -> [Shot] {
        let bounds = model.calculateBoundingBox()
        let height = max(bounds.max.y - bounds.min.y, 1.0)
        var head = SIMD3<Float>(0, height * 0.9, 0)
        if let index = model.humanoid?.getBoneNode(.head), index < model.nodes.count {
            let point = model.nodes[index].worldPosition
            head = model.isVRM0 ? SIMD3<Float>(-point.x, point.y, -point.z) : point
        }
        let face = head + SIMD3<Float>(0, height * 0.02, 0)
        let faceDistance = height * 0.30
        let angle: Float = 0.6
        let figure = SIMD3<Float>(0, (bounds.min.y + bounds.max.y) * 0.5, 0)
        let figureDistance = (height * 0.60) / tan(Float.pi / 6) + 0.3
        return [
            Shot(name: "face", eye: face + [0, 0, faceDistance], target: face),
            // Where mouth and eye layers meet: teeth and tongue, closed lids.
            Shot(name: "mouthOpen", eye: face + [0, 0, faceDistance], target: face, expression: .aa),
            Shot(name: "smile", eye: face + [0, 0, faceDistance], target: face, expression: .happy),
            Shot(name: "threeQuarter", eye: face + [sin(angle), 0, cos(angle)] * (faceDistance * 1.6), target: face),
            Shot(name: "figure", eye: figure + [0, 0, figureDistance], target: figure)
        ]
    }

    private static func render(_ renderer: VRMRenderer, device: MTLDevice, samples: Int) -> Data? {
        func target(_ format: MTLPixelFormat, multisample: Bool, storage: MTLStorageMode) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = multisample ? .type2DMultisample : .type2D
            descriptor.pixelFormat = format
            descriptor.width = size
            descriptor.height = size
            descriptor.sampleCount = multisample ? samples : 1
            descriptor.storageMode = storage
            descriptor.usage = [.renderTarget, .shaderRead]
            return device.makeTexture(descriptor: descriptor)
        }
        let format = renderer.config.colorPixelFormat
        guard let color = target(format, multisample: false, storage: .private),
              let readback = target(format, multisample: false, storage: .shared),
              let depth = target(.depth32Float, multisample: samples > 1, storage: .private),
              let commandBuffer = renderer.commandQueue.makeCommandBuffer()
        else { return nil }
        let pass = MTLRenderPassDescriptor()
        if samples > 1 {
            pass.colorAttachments[0].texture = target(format, multisample: true, storage: .private)
            pass.colorAttachments[0].resolveTexture = color
            pass.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            pass.colorAttachments[0].texture = color
            pass.colorAttachments[0].storeAction = .store
        }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.55, green: 0.60, blue: 0.66, alpha: 1)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        renderer.drawOffscreenHeadless(to: color, depth: depth, commandBuffer: commandBuffer, renderPassDescriptor: pass)
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: color, to: readback)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return FrameImageConverter.image(from: readback, scale: 1)?.pngData()
    }
}
