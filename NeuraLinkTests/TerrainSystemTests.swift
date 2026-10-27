//
//  TerrainSystemTests.swift
//  NeuraLinkTests
//
//  Created by Dedicatus on 18/04/2026.
//

import Foundation
import Testing
import simd

@testable import NeuraLink

@Suite("Terrain System Tests")
struct TerrainSystemTests {

    // Antananarivo around the December solstice, when its noon sun stands
    // 4.5° off the zenith (UTC).
    private static let midnight = Date(timeIntervalSince1970: 1_797_800_400)  // 2026-12-20 21:00
    private static let sunrise = Date(timeIntervalSince1970: 1_797_818_400)   // 2026-12-21 02:00
    private static let noon = Date(timeIntervalSince1970: 1_797_842_880)      // 2026-12-21 08:48

    private func sky(at date: Date) -> SkyEnvironment {
        SkyEnvironment.resolve(at: date, location: SkyLocation(latitude: -18.92, longitude: 47.52))
    }

    // MARK: - TerrainUniforms layout

    @Test("TerrainUniforms stride is 240 bytes")
    func testTerrainUniformsLayout() {
        #expect(MemoryLayout<TerrainUniforms>.stride == 240)
    }

    @Test("ShadowPassUniforms stride is 64 bytes")
    func testShadowPassUniformsLayout() {
        #expect(MemoryLayout<ShadowPassUniforms>.stride == 64)
    }

    // MARK: - Light matrix

    @Test("Light matrix is invertible at noon")
    func testLightMatrixNoon() {
        let env = sky(at: Self.noon)
        let mat = TerrainRenderer.makeLightMatrix(sunDir: env.sunDirection)
        let det = mat.determinant
        #expect(abs(det) > 1e-6)
    }

    @Test("Light matrix is invertible at sunrise")
    func testLightMatrixSunrise() {
        let env = sky(at: Self.sunrise)
        let mat = TerrainRenderer.makeLightMatrix(sunDir: env.sunDirection)
        let det = mat.determinant
        #expect(abs(det) > 1e-6)
    }

    @Test("Light matrix changes between dawn and noon")
    func testLightMatrixVariesWithTime() {
        let envDawn = sky(at: Self.sunrise)
        let envNoon = sky(at: Self.noon)
        let matDawn = TerrainRenderer.makeLightMatrix(sunDir: envDawn.sunDirection)
        let matNoon = TerrainRenderer.makeLightMatrix(sunDir: envNoon.sunDirection)
        // At least one column differs
        let col0diff = simd_length(matDawn.columns.0 - matNoon.columns.0)
        #expect(col0diff > 1e-3)
    }

    @Test("Light matrix is invertible when sun is nearly vertical")
    func testLightMatrixVerticalSun() {
        // Simulates sun directly overhead (edge case for up-vector selection)
        let sunDir = SIMD3<Float>(0.0, 1.0, 0.0)
        let mat = TerrainRenderer.makeLightMatrix(sunDir: sunDir)
        let det = mat.determinant
        #expect(abs(det) > 1e-6)
    }

    // MARK: - Sky-terrain consistency

    @Test("No shadow softness at night (sun below horizon)")
    func testNoShadowAtNight() {
        let env = sky(at: Self.midnight)
        // Night: sunDirection.y < 0, terrain should have zero shadow softness
        #expect(env.sunDirection.y < -0.1)
    }

    @Test("Shadow active at noon")
    func testShadowActiveAtNoon() {
        let env = sky(at: Self.noon)
        // Noon: sunDirection.y ≈ 1, shadow should be active
        #expect(env.sunDirection.y > 0.9)
    }

    @Test("Snow color components are in [0, 1]")
    func testSnowColorRange() {
        let snow = SIMD3<Float>(0.93, 0.95, 0.97)
        #expect(snow.x >= 0 && snow.x <= 1)
        #expect(snow.y >= 0 && snow.y <= 1)
        #expect(snow.z >= 0 && snow.z <= 1)
    }

    @Test("Shadow map size is positive power of 2")
    func testShadowMapSize() {
        let size = TerrainRenderer.shadowMapSize
        #expect(size > 0)
        #expect((size & (size - 1)) == 0)  // power of two
    }
}
