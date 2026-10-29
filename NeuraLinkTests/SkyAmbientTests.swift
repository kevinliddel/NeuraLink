//
//  SkyAmbientTests.swift
//  NeuraLinkTests
//
//  The sky's light as MToon's GI takes it (SkyAmbient): the L1 sums on skies
//  whose answer is known, the shaping for the avatar, and the uniforms that
//  carry it.
//
//  Created by Dedicatus on 28/10/2026.
//

import Testing
import Foundation
import simd
@testable import NeuraLink

@Suite("Sky ambient")
struct SkyAmbientTests {

    private static let up = SIMD3<Float>(0, 1, 0)
    private static let down = SIMD3<Float>(0, -1, 0)
    private static let side = SIMD3<Float>(1, 0, 0)

    /// What sky_ambient_sh returns for a sky of radiance 1 everywhere above
    /// the horizon: mean = 1/4π · 2π, along y = 1/2π · π.
    private static let whiteSky: [SIMD4<Float>] = [
        SIMD4(0.5, 0.5, 0.5, 0), .zero, SIMD4(0.5, 0.5, 0.5, 0), .zero
    ]

    @Test("A white sky over black ground: all of it from above, none from below, half from the side")
    func testWhiteSkyBlackGround() {
        let light = SkyAmbient(sky: Self.whiteSky, albedo: .zero, sunlight: .zero)
        #expect(simd_distance(light.along(Self.up), SIMD3(repeating: 1)) < 1e-5)
        #expect(simd_length(light.along(Self.down)) < 1e-5)
        #expect(simd_distance(light.along(Self.side), SIMD3(repeating: 0.5)) < 1e-5)
    }

    @Test("The ground sends back its albedo of the sky and the sun, from below")
    func testGround() {
        let light = SkyAmbient(sky: Self.whiteSky, albedo: SIMD3(repeating: 0.5), sunlight: SIMD3(repeating: 1))
        // The sky gives a level surface 1 (over π); the sun 1 more: the
        // ground, at albedo 0.5, sends back 1.
        #expect(simd_distance(light.along(Self.down), SIMD3(repeating: 1)) < 1e-5)
        #expect(simd_distance(light.along(Self.up), SIMD3(repeating: 1)) < 1e-5)
    }

    @Test("The hemisphere stand-in is the old one: 35% brighter from above, as much darker below")
    func testHemisphere() {
        let color = SIMD3<Float>(0.2, 0.3, 0.4)
        let light = SkyAmbient.hemisphere(color)
        #expect(simd_distance(light.along(Self.up), color * 1.35) < 1e-6)
        #expect(simd_distance(light.along(Self.down), color * 0.65) < 1e-6)
        #expect(light.mean == color)
    }

    @Test("Shaped for the avatar: the curve's brightness, the sky's colour, no side dark")
    func testShaped() {
        let blueAbove = SkyAmbient(
            mean: SIMD3(0.3, 0.4, 0.6), x: SIMD3(0.05, 0.02, 0), y: SIMD3(0.2, 0.4, 0.9), z: .zero)
        let curve = SIMD3<Float>(0.18, 0.18, 0.18)
        let shaped = blueAbove.shaped(toBrightness: curve)
        #expect(abs(simd_dot(shaped.mean, SkyAmbient.luma) - 0.18) < 1e-4)
        #expect(shaped.mean.z > shaped.mean.x, "keeps the sky's blue")
        for direction in [Self.up, Self.down, Self.side, -Self.side, SIMD3(0, 0, 1), SIMD3(0, 0, -1)] {
            let seen = shaped.along(direction)
            for c in 0..<3 {
                #expect(seen[c] >= shaped.mean[c] * (1 - SkyAmbient.avatarContrast) - 1e-5)
            }
        }
        // No sky light at all: the curve as a hemisphere, not a division by zero.
        let none = SkyAmbient(mean: .zero, x: .zero, y: .zero, z: .zero).shaped(toBrightness: curve)
        #expect(none.mean.x.isFinite && abs(simd_dot(none.mean, SkyAmbient.luma) - 0.18) < 1e-4)
    }

    @Test("Rain drains the colour and darkens it, as the sky's overcast does")
    func testOvercast() {
        let light = SkyAmbient.hemisphere(SIMD3(0.2, 0.3, 0.5))
        let rained = light.overcast(1)
        let spread = { (c: SIMD3<Float>) in c.max() - c.min() }
        #expect(spread(rained.mean) < spread(light.mean) * 0.4)
        #expect(simd_dot(rained.mean, SkyAmbient.luma) < simd_dot(light.mean, SkyAmbient.luma))
        #expect(light.overcast(0) == light)
    }

    @Test("The environment lights the avatar with the sky's light once there is one")
    func testEnvironment() throws {
        // 08:00 in Antananarivo: the sun low in the east, behind the camera,
        // so the rim is all the sky's.
        let instant = try #require(ISO8601DateFormatter().date(from: "2026-06-21T05:00:00Z"))
        let place = SkyLocation(latitude: -18.92, longitude: 47.52)
        let plain = SkyEnvironment.resolve(at: instant, location: place)
        #expect(plain.ambient == .hemisphere(plain.ambientColor))

        let blue = SkyAmbient(mean: SIMD3(0.3, 0.4, 0.6), x: .zero, y: SIMD3(0.2, 0.3, 0.5), z: .zero)
        let lit = SkyEnvironment.resolve(at: instant, location: place, sky: blue)
        #expect(lit.keyLight.direction.z > 0)
        #expect(abs(simd_dot(lit.ambient.mean, SkyAmbient.luma) - simd_dot(lit.ambientColor, SkyAmbient.luma)) < 1e-4)
        #expect(lit.ambient.mean.z > lit.ambient.mean.x)
        #expect(lit.rimLightColor.z > lit.rimLightColor.x, "the rim takes the sky's blue behind her")
    }

    @Test("Uniforms carry the whole ambient after the old layout, 480 bytes")
    func testUniforms() {
        #expect(MemoryLayout<Uniforms>.size == 480)
        #expect(MemoryLayout<Uniforms>.offset(of: \.ambientAlongX_packed) == 432)
        var uniforms = Uniforms()
        let standIn = SkyAmbient.hemisphere(SIMD3(repeating: 0.05))
        #expect(simd_distance(uniforms.ambient.along(Self.up), standIn.along(Self.up)) < 1e-6)
        let light = SkyAmbient(mean: SIMD3(0.1, 0.2, 0.3), x: SIMD3(0.01, 0, 0), y: SIMD3(0, 0.02, 0), z: SIMD3(0, 0, 0.03))
        uniforms.ambient = light
        #expect(uniforms.ambient == light)
    }
}
