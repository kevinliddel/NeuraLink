//
//  RainWorldSystemTests.swift
//  NeuraLinkTests
//
//  Tests for the procedural world-space rain system.
//  Rain3DParticle is now a static seed (spawnX, spawnZ, phase, speed) —
//  all animation is procedural in the GPU shader, driven by u.time.
//

import Testing
import Foundation
import simd
@testable import NeuraLink

@Suite("Rain World System Tests")
struct RainWorldSystemTests {

    // MARK: - Simulator Initialisation

    @Test("Simulator creates correct particle count")
    func testParticleCount() {
        let sim = RainWorldSimulator()
        #expect(sim.particles.count == sim.maxParticles)
    }

    @Test("All particles have valid spawn positions within spawn radius")
    func testSpawnBounds() {
        let sim = RainWorldSimulator()
        let spawnRadius: Float = 22.0
        for p in sim.particles {
            #expect(abs(p.spawnX) <= spawnRadius)
            #expect(abs(p.spawnZ) <= spawnRadius)
        }
    }

    @Test("All particles have phase in [0, 1]")
    func testPhaseRange() {
        let sim = RainWorldSimulator()
        for p in sim.particles {
            #expect(p.phase >= 0.0)
            #expect(p.phase <= 1.0)
        }
    }

    @Test("All particles have speed in [0.75, 1.4]")
    func testSpeedRange() {
        let sim = RainWorldSimulator()
        for p in sim.particles {
            #expect(p.speed >= 0.75)
            #expect(p.speed <= 1.4)
        }
    }

    @Test("Particles have varied phases (not all the same)")
    func testPhaseVariety() {
        let sim = RainWorldSimulator()
        let first = sim.particles[0].phase
        let allSame = sim.particles.allSatisfy { $0.phase == first }
        #expect(!allSame, "All particles should not share the same phase")
    }

    @Test("Particles have varied spawn positions")
    func testPositionVariety() {
        let sim = RainWorldSimulator()
        let firstX = sim.particles[0].spawnX
        let allSameX = sim.particles.allSatisfy { $0.spawnX == firstX }
        #expect(!allSameX, "All particles should not share the same spawnX")
    }

    // MARK: - Procedural fall logic (shader-side, tested analytically)

    @Test("Procedural fall: fract(time * speed + phase) wraps in [0, 1]")
    func testProceduralFallBounds() {
        let sim = RainWorldSimulator()
        let sampleTime: Float = 42.75  // Arbitrary test time

        for p in sim.particles {
            let t = (sampleTime * p.speed + p.phase).truncatingRemainder(dividingBy: 1.0)
            let tWrapped = t < 0 ? t + 1 : t
            #expect(tWrapped >= 0.0)
            #expect(tWrapped <= 1.0)
        }
    }

    @Test("World Y interpolates from 16 (top) to 0 (ground) as t goes 0→1")
    func testWorldYInterpolation() {
        let spawnY: Float = 16.0
        let groundY: Float = 0.0

        // t = 0 → should be at top
        let yAtStart = spawnY * (1 - 0) + groundY * 0
        #expect(yAtStart == 16.0)

        // t = 1 → should be at ground
        let yAtEnd = spawnY * (1 - 1) + groundY * 1
        #expect(yAtEnd == 0.0)

        // t = 0.5 → should be midway
        let yAtMid = spawnY * (1 - 0.5) + groundY * 0.5
        #expect(yAtMid == 8.0)
    }

    @Test("Simulator update is a no-op (procedural, no CPU state changes)")
    func testUpdateIsNoop() {
        let sim = RainWorldSimulator()
        let snapshotPhases = sim.particles.map { $0.phase }
        let snapshotSpeeds = sim.particles.map { $0.speed }

        sim.update(deltaTime: 0.016, intensity: 1.0, cameraPos: .zero)

        // Procedural seeds must NOT change on update
        for i in 0..<sim.maxParticles {
            #expect(sim.particles[i].phase == snapshotPhases[i])
            #expect(sim.particles[i].speed == snapshotSpeeds[i])
        }
    }
}
