//
//  SkySnapshots.swift
//  NeuraLinkTests
//
//  Review renders, not assertions: Oz on the default terrain under the sky
//  at fixed dates and times in Antananarivo, through the app's renderer —
//  the figure, the sky toward the light (sun, or moon at night) and the sky
//  away from it, the moon close up whenever it is up, and at night the
//  celestial pole the stars turn about, at about a phone's pixel density —
//  plus the GPU time of the sky pass on its own. Every change to the sky is
//  judged on these, before and after.
//
//  NL_SKY_SNAPSHOT_DIR: output folder (unset = skip).
//  NL_SKY_DOC_DIR: writes the pictures in docs/Sky_System.md instead
//  (docs/Sky, as an absolute path).
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

    // A first-quarter evening, a full moon, a waxing gibbous.
    private static let days = ["2026-06-21", "2026-10-26", "2026-12-21"]
    private static let times = ["05:30", "06:00", "06:30", "09:00", "12:00", "16:00",
                                "17:45", "18:15", "19:00", "22:00", "02:00"]

    @Test("Writes sky renders when NL_SKY_SNAPSHOT_DIR is set")
    func render() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["NL_SKY_SNAPSHOT_DIR"], let device = MTLCreateSystemDefaultDevice() else { return }
        let dir = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zone = try #require(TimeZone(identifier: "Indian/Antananarivo"))
        let (renderer, model) = try await Self.makeRenderer(device: device)

        var report = ""
        for day in Self.days {
            for time in Self.times {
                let instant = try #require(Self.date(day, time, in: zone))
                guard let sky = Self.show(renderer, at: instant, in: zone) else { continue }
                report += Self.describe(sky, day: day, time: time)
                for shot in Self.shots(for: sky, model: model) {
                    let png = try #require(Self.render(shot, with: renderer, device: device))
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

    /// The pictures in docs/Sky_System.md, named for what they show rather
    /// than when, all over Antananarivo: a winter's day toward the sun, the
    /// moon through the lunation that starts at the June new moon, and the
    /// Southern Cross on that moonless night.
    @Test("Writes the docs figures when NL_SKY_DOC_DIR is set")
    func docFigures() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["NL_SKY_DOC_DIR"], let device = MTLCreateSystemDefaultDevice() else { return }
        let dir = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zone = try #require(TimeZone(identifier: "Indian/Antananarivo"))
        let location = SkyLocation(timeZone: zone)
        let (renderer, model) = try await Self.makeRenderer(device: device)
        let head = SIMD3<Float>(0, Self.height(of: model) * 0.85, 0)
        func write(_ name: String, at instant: Date, _ shot: (SkyEnvironment) -> Shot) throws {
            let sky = try #require(Self.show(renderer, at: instant, in: zone))
            let png = try #require(Self.render(shot(sky), with: renderer, device: device))
            try png.write(to: dir.appendingPathComponent("\(name).png"))
        }

        // The day, toward the sun (the moon at night).
        let day = [("before-dawn", "05:50"), ("sunrise", "06:30"), ("morning", "09:00"), ("noon", "12:00"),
                   ("afternoon", "15:30"), ("sunset", "17:15"), ("dusk", "17:45"), ("night", "22:00")]
        for (name, time) in day {
            let instant = try #require(Self.date("2026-06-21", time, in: zone))
            try write("day-\(name)", at: instant) { sky in
                Self.skyward(sky.sunDirection.y > -0.2 ? sky.sunDirection : sky.moonDirection, from: head)
            }
        }

        // The moon each night of the lunation at the highest it stands in a
        // dark sky (the sun 8° down), and once by day.
        let june = try #require(Self.date("2026-06-13", "00:00", in: zone))
        let newMoon = try #require(stride(from: 0.0, to: 4 * 86_400, by: 1_800)
            .map { june.addingTimeInterval($0) }
            .min { SkyBodies(at: $0, location: location).moonIllumination
                < SkyBodies(at: $1, location: location).moonIllumination })
        let phases = [("waxing-crescent", 4.0), ("first-quarter", 7.4), ("waxing-gibbous", 11), ("full", 14.8),
                      ("waning-gibbous", 18.5), ("last-quarter", 22.1), ("waning-crescent", 25.5), ("by-day", 6.5)]
        for (name, age) in phases {
            let byDay = name == "by-day"
            let centre = newMoon.addingTimeInterval(age * 86_400)
            let night = stride(from: -43_200.0, through: 43_200, by: 600)
                .map { centre.addingTimeInterval($0) }
                .map { ($0, SkyBodies(at: $0, location: location)) }
                .filter { byDay ? $0.1.sunDirection.y > sin(20 * .pi / 180) : $0.1.sunDirection.y < sin(-8 * .pi / 180) }
            let (instant, bodies) = try #require(night.max { $0.1.moonDirection.y < $1.1.moonDirection.y })
            #expect(bodies.moonDirection.y > sin(15 * .pi / 180), "\(name): the moon stands too low")
            try write("moon-\(name)", at: instant) { sky in
                Shot(name: name, eye: head, target: head + sky.moonDirection, fov: 12, showsFigure: false)
            }
        }

        // The Southern Cross and the Pointers (J2000 RA 200°, Dec −61°) high
        // in the south on the evening of that moonless night.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let evening = calendar.startOfDay(for: newMoon).addingTimeInterval(19 * 3_600)
        let (ra, dec) = (Float(200) * .pi / 180, Float(-61) * .pi / 180)
        let group = SIMD3<Float>(cos(dec) * cos(ra), cos(dec) * sin(ra), sin(dec))
        try write("stars-southern-cross", at: evening) { sky in
            Shot(name: "stars", eye: head, target: head + sky.starRotation * group, fov: 30, showsFigure: false)
        }
        renderer.clearModel()
    }

    private struct Shot {
        let name: String
        let eye: SIMD3<Float>
        let target: SIMD3<Float>
        var fov: Float = 60
        /// Off for the sky close-ups, taken from where the head is.
        var showsFigure = true
    }

    /// The figure from the front, and the sky toward and away from the light
    /// from just past the avatar, looking 20° up. "Toward" follows the sun
    /// while it is near or above the horizon (its glow), the moon after.
    private static func shots(for sky: SkyEnvironment, model: VRMModel) -> [Shot] {
        let bounds = model.calculateBoundingBox()
        let height = Self.height(of: model)
        let figure = SIMD3<Float>(0, (bounds.min.y + bounds.max.y) * 0.5, 0)
        let figureDistance = (height * 0.60) / tan(Float.pi / 6) + 0.3

        let light = sky.sunDirection.y > -0.2 ? sky.sunDirection : sky.moonDirection
        var toward = SIMD3<Float>(light.x, 0, light.z)
        toward = simd_length(toward) > 1e-3 ? simd_normalize(toward) : SIMD3<Float>(0, 0, -1)
        let head = SIMD3<Float>(0, height * 0.85, 0)
        let up = SIMD3<Float>(0, 0.36, 0)
        let ahead = head + toward * 1.5
        let behind = head - toward * 1.5
        var shots = [
            Shot(name: "figure", eye: figure + [0, 0, figureDistance], target: figure),
            Shot(name: "toward", eye: ahead, target: ahead + toward + up),
            Shot(name: "away", eye: behind, target: behind - toward + up)
        ]
        if sky.moonDirection.y > 0.05 {
            shots.append(Shot(name: "moon", eye: head, target: head + sky.moonDirection, fov: 14, showsFigure: false))
        }
        if sky.sunDirection.y < -0.2 {
            // Toward the celestial pole above the horizon, 35° up, so the
            // stars circling it (the Southern Cross, from Madagascar) show.
            let north = sky.starRotation * SIMD3<Float>(0, 0, 1)
            var pole = north.y > 0 ? north : -north
            let lowest: Float = sin(35 * .pi / 180)
            if pole.y < lowest {
                let flat = simd_normalize(SIMD2<Float>(pole.x, pole.z)) * sqrt(1 - lowest * lowest)
                pole = SIMD3<Float>(flat.x, lowest, flat.y)
            }
            shots.append(Shot(name: "pole", eye: head, target: head + pole, fov: 50, showsFigure: false))
        }
        return shots
    }

    /// The sky toward `light` from just past the avatar: 20° up, more for a
    /// high sun so it stays in view, never so much the horizon leaves it.
    private static func skyward(_ light: SIMD3<Float>, from head: SIMD3<Float>) -> Shot {
        var toward = SIMD3<Float>(light.x, 0, light.z)
        toward = simd_length(toward) > 1e-3 ? simd_normalize(toward) : SIMD3<Float>(0, 0, -1)
        let degree = Float.pi / 180
        let pitch = min(28 * degree, max(20 * degree, asin(light.y) - 22 * degree))
        let eye = head + toward * 1.5
        return Shot(name: "sky", eye: eye, target: eye + toward * cos(pitch) + [0, sin(pitch), 0], showsFigure: false)
    }

    private static func height(of model: VRMModel) -> Float {
        let bounds = model.calculateBoundingBox()
        return max(bounds.max.y - bounds.min.y, 1.0)
    }

    /// Oz on the open terrain, still, ready for the sky to be set.
    private static func makeRenderer(device: MTLDevice) async throws -> (VRMRenderer, VRMModel) {
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
        return (renderer, model)
    }

    /// Sets the sky, its lights and the terrain to `instant`.
    private static func show(_ renderer: VRMRenderer, at instant: Date, in zone: TimeZone) -> SkyEnvironment? {
        renderer.skyRenderer?.timeProvider = SkyTimeProvider(now: { instant }, timeZone: zone)
        renderer.updateSky(deltaTime: 0)
        renderer.applySkyLighting()
        renderer.updateTerrain(deltaTime: 0)
        return renderer.skyRenderer?.currentEnvironment
    }

    private static func render(_ shot: Shot, with renderer: VRMRenderer, device: MTLDevice) -> Data? {
        let up: SIMD3<Float> = abs(simd_normalize(shot.target - shot.eye).y) > 0.95 ? [0, 0, -1] : [0, 1, 0]
        renderer.viewMatrix = OrthographicCamera.makeLookAt(eye: shot.eye, target: shot.target, up: up)
        renderer.fovDegrees = shot.fov
        renderer.isModelVisible = shot.showsFigure
        renderer.projectionMatrix = renderer.makeProjectionMatrix(aspectRatio: 1)
        return VRMRenderSnapshots.render(renderer, device: device, samples: 1)
    }

    private static func describe(_ sky: SkyEnvironment, day: String, time: String) -> String {
        func angle(_ v: SIMD3<Float>) -> String {
            String(format: "elev %5.1f° az %6.1f°", asin(v.y) * 180 / .pi, atan2(v.x, v.z) * 180 / .pi)
        }
        return "\(day) \(time)  sun \(angle(sky.sunDirection))  moon \(angle(sky.moonDirection))"
            + String(format: " lit %.2f", sky.moonIllumination)
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
        sky.prepareForEncoding(viewProjection: projection * view)
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
