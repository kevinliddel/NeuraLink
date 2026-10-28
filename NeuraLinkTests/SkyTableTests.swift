//
//  SkyTableTests.swift
//  NeuraLinkTests
//
//  The sky's GPU tables, built on the device and read back: the sky view
//  (with the haze in front of the clouds in its alpha) and the clouds'
//  noise.
//
//  Created by Dedicatus on 28/10/2026.
//

import Testing
import Foundation
import Metal
import simd
@testable import NeuraLink

@MainActor
@Suite("Sky GPU tables")
struct SkyTableTests {

    /// The real tables, built on the GPU and read back.
    @Test("The sky-view table: blue overhead at noon, red toward a setting sun, twilight still lit, haze before the clouds")
    func testSkyViewTable() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let sky = SkyRenderer(device: device, config: RendererConfig(strict: .off, sampleCount: 1))
        let queue = try #require(device.makeCommandQueue())
        var haze: (SIMD3<Float>) -> Float = { _ in .nan }
        func table(at iso: String) throws -> (SkyEnvironment, (SIMD3<Float>) -> SIMD3<Float>) {
            let instant = try utc(iso)
            sky.timeProvider = SkyTimeProvider(now: { instant }, timeZone: TimeZone(identifier: "Indian/Antananarivo")!)
            sky.update(deltaTime: 0)
            let buffer = try #require(queue.makeCommandBuffer())
            sky.encodeAtmosphere(commandBuffer: buffer)
            let texture = try #require(sky.skyViewTable)
            let bytesPerRow = texture.width * 8
            let readback = try #require(device.makeBuffer(length: bytesPerRow * texture.height, options: .storageModeShared))
            let blit = try #require(buffer.makeBlitCommandEncoder())
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                      sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                      to: readback, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
                      destinationBytesPerImage: bytesPerRow * texture.height)
            blit.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
            // Reads through `readback`, so the closures below keep it alive.
            let texels = { (i: Int) -> Float in
                Float(readback.contents().assumingMemoryBound(to: Float16.self)[i])
            }
            let (width, height) = (texture.width, texture.height)
            // skyViewUV in SkyAtmosphereCommon.metal, to the nearest texel.
            let texel = { (d: SIMD3<Float>) -> Int in
                let elevation = asin(min(1, max(-1, d.y)))
                let s = (elevation < 0 ? -1 : 1) * (abs(elevation) / (.pi / 2)).squareRoot()
                let u = atan2(d.z, d.x) / (2 * .pi) + 0.5
                let x = min(width - 1, max(0, Int(u * Float(width))))
                let y = min(height - 1, max(0, Int((s * 0.5 + 0.5) * Float(height))))
                return (y * width + x) * 4
            }
            haze = { texels(texel($0) + 3) }
            return (sky.currentEnvironment, { d in
                let i = texel(d)
                return SIMD3<Float>(texels(i), texels(i + 1), texels(i + 2))
            })
        }
        func flat(_ d: SIMD3<Float>, up degrees: Float) -> SIMD3<Float> {
            let h = simd_normalize(SIMD3<Float>(d.x, 0, d.z))
            let e = degrees * .pi / 180
            return SIMD3<Float>(h.x * cos(e), sin(e), h.z * cos(e))
        }
        let luma = SIMD3<Float>(0.2126, 0.7152, 0.0722)

        let (noon, noonSky) = try table(at: "2026-06-21T09:00:00Z")
        let zenith = noonSky([0, 1, 0])
        #expect(zenith.z > zenith.x * 1.5, "noon zenith \(zenith)")
        #expect(simd_dot(noonSky(flat(-noon.sunDirection, up: 3)), luma) > simd_dot(zenith, luma))

        // Antananarivo, 21 June 17:15: the sun 1° up, straight ahead-ish.
        let (dusk, duskSky) = try table(at: "2026-06-21T14:15:00Z")
        #expect(dusk.sunDirection.y > 0 && dusk.sunDirection.y < 0.05)
        let sunward = duskSky(flat(dusk.sunDirection, up: 2)), opposite = duskSky(flat(-dusk.sunDirection, up: 2))
        #expect(sunward.x / sunward.z > opposite.x / opposite.z * 2, "\(sunward) vs \(opposite)")

        // 17:47: the sun 6° down. The zenith still lit, not night.
        let (twilight, twilightSky) = try table(at: "2026-06-21T14:47:00Z")
        #expect(twilight.sunDirection.y < -0.09 && twilight.sunDirection.y > -0.12)
        let twilightZenith = simd_dot(twilightSky([0, 1, 0]), luma)
        #expect(twilightZenith > 0.01, "twilight zenith \(twilightZenith)")
        for value in [zenith, sunward, opposite, twilightSky([0, 1, 0])] { #expect(value.x.isFinite && value.min() >= 0) }

        // Alpha: how much of the low clouds shows through the air before
        // them. Nearly all overhead, less and less toward the horizon,
        // none where the ground is in the way.
        let overhead = haze([0, 1, 0]), high = haze(flat([1, 0, 0], up: 30))
        let low = haze(flat([1, 0, 0], up: 3)), horizon = haze(flat([1, 0, 0], up: 0.5))
        #expect(overhead > 0.97, "overhead \(overhead)")
        #expect(overhead >= high && high > low && low > horizon, "\(overhead) \(high) \(low) \(horizon)")
        #expect(horizon < 0.5 && horizon > 0, "horizon \(horizon)")
        #expect(haze(flat([1, 0, 0], up: -10)) == 0)
    }

    /// The clouds' noise, baked on the GPU and read back.
    @Test("The cloud noise tiles without a seam and spreads about its middle")
    func testCloudNoise() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let sky = SkyRenderer(device: device, config: RendererConfig(strict: .off, sampleCount: 1))
        let queue = try #require(device.makeCommandQueue())
        let buffer = try #require(queue.makeCommandBuffer())
        sky.encodeAtmosphere(commandBuffer: buffer)
        let noise = try #require(sky.cloudNoise)
        let (width, height) = (noise.width, noise.height)
        let bytesPerRow = width * 2
        let readback = try #require(device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared))
        let blit = try #require(buffer.makeBlitCommandEncoder())
        blit.copy(from: noise, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: readback, destinationOffset: 0, destinationBytesPerRow: bytesPerRow,
                  destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        let texels = readback.contents().bindMemory(to: Float16.self, capacity: width * height)
        let value = { (x: Int, y: Int) in Float(texels[y * width + x]) }

        let values = (0..<height).flatMap { y in (0..<width).map { value($0, y) } }
        let mean = values.reduce(0, +) / Float(values.count)
        #expect(values.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(abs(mean - 0.484) < 0.05, "mean \(mean)")
        #expect((values.max() ?? 0) - (values.min() ?? 0) > 0.5)

        // Across each edge the noise steps no more than between neighbours inside.
        func step(_ pairs: [(Float, Float)]) -> Float { pairs.map { abs($0 - $1) }.reduce(0, +) / Float(pairs.count) }
        let inside = step((0..<height).map { (value(127, $0), value(128, $0)) })
        let acrossX = step((0..<height).map { (value(width - 1, $0), value(0, $0)) })
        let acrossY = step((0..<width).map { (value($0, height - 1), value($0, 0)) })
        #expect(acrossX < inside * 1.5 && acrossY < inside * 1.5, "edges \(acrossX) \(acrossY), inside \(inside)")
    }
}

private func utc(_ iso: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: iso))
}
