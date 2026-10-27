//
//  SkySnapshots.swift
//  NeuraLinkTests
//
//  Review renders, not assertions: Oz on the default terrain under the sky
//  at fixed dates and times in Antananarivo, through the app's renderer —
//  the figure, the sky toward the light (sun, or moon at night) and the sky
//  away from it — plus the GPU time of the sky pass on its own. Every change
//  to the sky is judged on these, before and after.
//
//  NL_SKY_SNAPSHOT_DIR: output folder (unset = skip).
//
//  Created by Dedicatus on 27/10/2026.
//

import Foundation
import Metal
import Testing
import UIKit
import simd
@testable import NeuraLink

@MainActor
@Suite("Sky snapshots", .serialized)
struct SkySnapshots {

    private static let days = ["2026-06-21", "2026-12-21"]
    private static let times = ["05:30", "06:00", "06:30", "09:00", "12:00", "16:00",
                                "17:45", "18:15", "19:00", "22:00", "02:00"]

    @Test("Writes sky renders when NL_SKY_SNAPSHOT_DIR is set")
    func render() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["NL_SKY_SNAPSHOT_DIR"], let device = MTLCreateSystemDefaultDevice() else { return }
        let dir = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zone = try #require(TimeZone(identifier: "Indian/Antananarivo"))

        let renderer = VRMRenderer(device: device, config: RendererConfig(strict: .off, sampleCount: 1))
        // Outdoors: the open terrain under the sky, not whichever 3D
        // environment the simulator last downloaded (an interior hides it).
        renderer.environmentRenderer = nil
        renderer.enableSpringBone = false
        renderer.materialTimeOverride = 0
        let url = try #require(Bundle.main.url(forResource: "Oz", withExtension: "vrm"))
        let model = try await VRMModel.load(from: url, device: device)
        model.updateNodeTransforms()
        renderer.loadModel(model)
        renderer.isModelVisible = true
        renderer.lookAtController?.enabled = false

        var report = ""
        for day in Self.days {
            for time in Self.times {
                let instant = try #require(Self.date(day, time, in: zone))
                renderer.skyRenderer?.timeProvider = SkyTimeProvider(now: { instant }, timeZone: zone)
                renderer.updateSky(deltaTime: 0)
                renderer.applySkyLighting()
                renderer.updateTerrain(deltaTime: 0)
                guard let sky = renderer.skyRenderer?.currentEnvironment else { continue }
                report += Self.describe(sky, day: day, time: time)
                for shot in Self.shots(for: sky, model: model) {
                    renderer.viewMatrix = OrthographicCamera.makeLookAt(eye: shot.eye, target: shot.target, up: [0, 1, 0])
                    renderer.projectionMatrix = renderer.makeProjectionMatrix(aspectRatio: 1)
                    let png = try #require(VRMRenderSnapshots.render(renderer, device: device, samples: 1))
                    let stamp = time.replacingOccurrences(of: ":", with: "")
                    try png.write(to: dir.appendingPathComponent("\(day)_\(stamp)_\(shot.name).png"))
                }
            }
        }
        if let sky = renderer.skyRenderer {
            let ms = Self.skyPassMilliseconds(sky, device: device, format: renderer.config.colorPixelFormat)
            report += "\nsky pass alone, 1170×2532: \(ms) ms GPU\n"
        }
        try report.write(to: dir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        renderer.clearModel()
    }

    private struct Shot {
        let name: String
        let eye: SIMD3<Float>
        let target: SIMD3<Float>
    }

    /// The figure from the front, and the sky toward and away from the light
    /// from just past the avatar, looking 20° up. "Toward" follows the sun
    /// while it is near or above the horizon (its glow), the moon after.
    private static func shots(for sky: SkyEnvironment, model: VRMModel) -> [Shot] {
        let bounds = model.calculateBoundingBox()
        let height = max(bounds.max.y - bounds.min.y, 1.0)
        let figure = SIMD3<Float>(0, (bounds.min.y + bounds.max.y) * 0.5, 0)
        let figureDistance = (height * 0.60) / tan(Float.pi / 6) + 0.3

        let light = sky.sunDirection.y > -0.2 ? sky.sunDirection : sky.moonDirection
        var toward = SIMD3<Float>(light.x, 0, light.z)
        toward = simd_length(toward) > 1e-3 ? simd_normalize(toward) : SIMD3<Float>(0, 0, -1)
        let head = SIMD3<Float>(0, height * 0.85, 0)
        let up = SIMD3<Float>(0, 0.36, 0)
        let ahead = head + toward * 1.5
        let behind = head - toward * 1.5
        return [
            Shot(name: "figure", eye: figure + [0, 0, figureDistance], target: figure),
            Shot(name: "toward", eye: ahead, target: ahead + toward + up),
            Shot(name: "away", eye: behind, target: behind - toward + up)
        ]
    }

    private static func describe(_ sky: SkyEnvironment, day: String, time: String) -> String {
        func angle(_ v: SIMD3<Float>) -> String {
            String(format: "elev %5.1f° az %6.1f°", asin(v.y) * 180 / .pi, atan2(v.x, v.z) * 180 / .pi)
        }
        return "\(day) \(time)  sun \(angle(sky.sunDirection))  moon \(angle(sky.moonDirection))"
            + "  key \(angle(sky.keyLight.direction)) ×\(String(format: "%.2f", sky.keyLight.intensity))\n"
    }

    private static func date(_ day: String, _ time: String, in zone: TimeZone) -> Date? {
        let d = day.split(separator: "-").compactMap { Int($0) }
        let t = time.split(separator: ":").compactMap { Int($0) }
        guard d.count == 3, t.count == 2 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: d[0], month: d[1], day: d[2], hour: t[0], minute: t[1]))
    }

    /// Median GPU time of the sky pass alone at a phone's full resolution.
    private static func skyPassMilliseconds(_ sky: SkyRenderer, device: MTLDevice, format: MTLPixelFormat) -> String {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: 1170, height: 2532, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: 1170, height: 2532, mipmapped: false)
        depthDescriptor.usage = [.renderTarget]
        depthDescriptor.storageMode = .private
        guard let color = device.makeTexture(descriptor: descriptor),
            let depth = device.makeTexture(descriptor: depthDescriptor),
            let queue = device.makeCommandQueue()
        else { return "n/a" }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        let projection = simd_float4x4(perspectiveFovY: Float.pi / 3, aspect: 1170 / 2532, near: 0.1, far: 100)
        let view = OrthographicCamera.makeLookAt(eye: [0, 1.5, 3], target: [0, 2.5, -3], up: [0, 1, 0])
        sky.prepareForEncoding(invViewProjection: simd_inverse(projection * view))
        var samples: [Double] = []
        for _ in 0..<40 {
            guard let buffer = queue.makeCommandBuffer(),
                let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return "n/a" }
            sky.encode(encoder: encoder)
            encoder.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
            samples.append((buffer.gpuEndTime - buffer.gpuStartTime) * 1000)
        }
        let sorted = samples.dropFirst(5).sorted()
        return sorted.isEmpty ? "n/a" : String(format: "%.3f", sorted[sorted.count / 2])
    }
}

private extension simd_float4x4 {
    init(perspectiveFovY fovY: Float, aspect: Float, near: Float, far: Float) {
        let y = 1 / tan(fovY / 2)
        let x = y / aspect
        let z = far / (near - far)
        self.init(columns: (
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0)))
    }
}
