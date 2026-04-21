//
//  BirdBehavior.swift
//  NeuraLink
//
//  Created by Dedicatus on 21/04/2026.
//

import simd

/// Stateless flock logic: deterministic initial setup and per-frame kinematics.
enum BirdBehavior {

    private static let flapAmplitude: Float = 0.42
    private static let maxWingSpan: Float = 0.18

    // MARK: - Setup

    /// Creates a deterministic flock with varied orbits, sizes, and phases.
    static func makeInitialFlock(count: Int = 10) -> [BirdInstance] {
        var rng = SeededRandom(seed: 0xDEAD_BEEF)
        return (0..<count).map { i in
            let phase = Float(i) / Float(count) * 2 * .pi
            return BirdInstance(
                orbitCenterX: rng.next(-4, 4),
                orbitCenterZ: rng.next(-4, 4),
                orbitRadiusX: rng.next(14, 30),
                orbitRadiusZ: rng.next(8, 20),
                baseHeight: rng.next(9, 22),
                heightAmplitude: rng.next(0.6, 2.2),
                heightPhase: phase,
                orbitAngle: phase,
                orbitSpeed: rng.next(0.14, 0.32) * (i.isMultiple(of: 2) ? 1 : -1),
                wingPhase: phase * 1.3,
                flapFrequency: rng.next(2.2, 3.8),
                scale: rng.next(0.17, 0.26)
            )
        }
    }

    // MARK: - Per-frame update

    /// Advances each bird by `deltaTime` seconds and refreshes derived state.
    static func update(birds: inout [BirdInstance], time: Float, deltaTime: Float) {
        for i in birds.indices {
            birds[i].orbitAngle += birds[i].orbitSpeed * deltaTime
            refreshDerived(&birds[i], time: time)
        }
    }

    // MARK: - Private

    private static func refreshDerived(_ b: inout BirdInstance, time: Float) {
        let angle = b.orbitAngle
        let xPos = b.orbitCenterX + b.orbitRadiusX * cos(angle)
        let zPos = b.orbitCenterZ + b.orbitRadiusZ * sin(angle)
        let yPos = b.baseHeight + sin(time * 0.38 + b.heightPhase) * b.heightAmplitude
        b.worldPosition = SIMD3<Float>(xPos, yPos, zPos)

        // Yaw: make the bird's nose (-Z) face the direction of travel.
        // Sample one step ahead in the direction of travel.
        let eps: Float = 0.01 * (b.orbitSpeed >= 0 ? 1 : -1)
        let nxPos = b.orbitCenterX + b.orbitRadiusX * cos(angle + eps)
        let nzPos = b.orbitCenterZ + b.orbitRadiusZ * sin(angle + eps)
        let dx = nxPos - xPos
        let dz = nzPos - zPos
        let len = sqrt(dx * dx + dz * dz)
        if len > 1e-4 {
            // yaw = atan2(-dx, -dz) makes the rotated nose align with (dx, dz)
            b.yaw = atan2(-dx / len, -dz / len)
        }

        // Wing flap: sinusoidal, phased per bird
        b.wingAngle = sin(time * b.flapFrequency + b.wingPhase) * flapAmplitude
    }
}

// MARK: - Seeded RNG (Xorshift64, deterministic across runs)

private struct SeededRandom {
    var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 1 : seed
    }

    mutating func nextRaw() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func next(_ lo: Float, _ hi: Float) -> Float {
        let normalised = Float(nextRaw() & 0x00FF_FFFF) / Float(0x00FF_FFFF)
        return lo + normalised * (hi - lo)
    }
}
