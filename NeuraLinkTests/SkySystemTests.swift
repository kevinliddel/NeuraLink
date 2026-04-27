//
//  SkySystemTests.swift
//  NeuraLinkTests
//
//  Created by Dedicatus on 17/04/2026.
//

import Testing
import Foundation
import simd
@testable import NeuraLink

@Suite("Sky System Tests")
struct SkySystemTests {

    // MARK: - SkyTimeProvider

    @Test("Day fraction for midnight is 0")
    func testDayFractionMidnight() {
        var provider = SkyTimeProvider()
        provider.now = { makeLocalDate(hour: 0, minute: 0, second: 0) }
        #expect(provider.dayFraction() == 0.0)
    }

    @Test("Day fraction for noon is 0.5")
    func testDayFractionNoon() {
        var provider = SkyTimeProvider()
        provider.now = { makeLocalDate(hour: 12, minute: 0, second: 0) }
        #expect(abs(provider.dayFraction() - 0.5) < 1e-4)
    }

    @Test("Current hour stays in [0, 24)")
    func testCurrentHourRange() {
        var provider = SkyTimeProvider()
        provider.now = { makeLocalDate(hour: 23, minute: 59, second: 59) }
        let h = provider.currentHour()
        #expect(h >= 0 && h < 24)
    }

    // MARK: - SkyEnvironment — sun direction

    @Test("Sun is overhead at noon")
    func testSunNoon() {
        let env = SkyEnvironment.resolve(hour: 12.0)
        #expect(abs(env.sunDirection.y - 1.0) < 1e-4)
        #expect(abs(env.sunDirection.x) < 1e-4)
    }

    @Test("Sun is on the horizon at sunrise (hour 6)")
    func testSunSunrise() {
        let env = SkyEnvironment.resolve(hour: 6.0)
        #expect(abs(env.sunDirection.y) < 1e-4)
        // Sun should be in the +X (east) direction
        #expect(env.sunDirection.x > 0.99)
    }

    @Test("Sun is below horizon at midnight")
    func testSunMidnight() {
        let env = SkyEnvironment.resolve(hour: 0.0)
        #expect(env.sunDirection.y < -0.99)
    }

    @Test("Sun direction is a unit vector for all hours")
    func testSunDirectionNormalized() {
        let hours: [Float] = [0, 3, 6, 9, 12, 15, 18, 21]
        for h in hours {
            let env = SkyEnvironment.resolve(hour: h)
            let len = simd_length(env.sunDirection)
            #expect(abs(len - 1.0) < 1e-5, "Hour \(h): length \(len)")
        }
    }

    // MARK: - SkyEnvironment — lighting

    @Test("Night key light intensity is meaningful (model must be visible)")
    func testNightKeyIntensity() {
        let env = SkyEnvironment.resolve(hour: 0.0)
        // Moonlight floor ensures the model is always readable.
        #expect(env.keyLightIntensity >= 0.40)
        // But still clearly dimmer than full noon.
        #expect(env.keyLightIntensity < 0.70)
    }

    @Test("Noon has high key light intensity")
    func testNoonHighIntensity() {
        let env = SkyEnvironment.resolve(hour: 12.0)
        #expect(env.keyLightIntensity > 0.80)
    }

    @Test("Stars are visible at midnight")
    func testStarsMidnight() {
        let env = SkyEnvironment.resolve(hour: 0.0)
        #expect(env.starVisibility > 0.9)
    }

    @Test("Stars are invisible at noon")
    func testStarsNoon() {
        let env = SkyEnvironment.resolve(hour: 12.0)
        #expect(env.starVisibility < 0.01)
    }

    @Test("Cloud coverage is in [0, 1] for all hours")
    func testCloudCoverage() {
        let hours: [Float] = stride(from: 0, to: 24, by: 1).map { Float($0) }
        for h in hours {
            let env = SkyEnvironment.resolve(hour: h)
            #expect(env.cloudCoverage >= 0 && env.cloudCoverage <= 1)
        }
    }

    @Test("Hour 25 wraps to the same result as hour 1")
    func testHourWrap() {
        let e25 = SkyEnvironment.resolve(hour: 25.0)
        let e1  = SkyEnvironment.resolve(hour: 1.0)
        #expect(abs(e25.sunDirection.y - e1.sunDirection.y) < 1e-4)
        #expect(abs(e25.keyLightIntensity - e1.keyLightIntensity) < 1e-4)
    }

    // MARK: - SkyUniformsData layout

    @Test("SkyUniformsData stride is 144 bytes")
    func testUniformsLayout() {
        #expect(MemoryLayout<SkyUniformsData>.stride == 144)
    }
}

// MARK: - Helpers

// Builds a Date in the device's local timezone so Calendar.current decomposes it
// back to the same hour — timezone-independent.
private func makeLocalDate(hour: Int, minute: Int, second: Int) -> Date {
    var comps = DateComponents()
    comps.year = 2026; comps.month = 4; comps.day = 17
    comps.hour = hour; comps.minute = minute; comps.second = second
    return Calendar.current.date(from: comps) ?? Date()
}
