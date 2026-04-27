//
//  RainWorldSimulator.swift
//  NeuraLink
//
//  CPU-side 3D rain physics: falling streaks + ground ripples.
//

import Foundation
import simd

struct Rain3DParticle {
    var spawnX: Float
    var spawnZ: Float
    var phase: Float
    var speed: Float
}

final class RainWorldSimulator {
    
    let maxParticles: Int = 1500 // Balanced count
    var particles: [Rain3DParticle]
    
    init() {
        self.particles = (0..<maxParticles).map { _ in
            Rain3DParticle(
                spawnX: Float.random(in: -22...22),
                spawnZ: Float.random(in: -22...22),
                phase: Float.random(in: 0...1),
                speed: Float.random(in: 0.75...1.4)
            )
        }
    }
    
    func update(deltaTime dt: Float, intensity: Float, cameraPos: SIMD3<Float>) {
        // No per-frame work needed for procedural rain!
    }
}
