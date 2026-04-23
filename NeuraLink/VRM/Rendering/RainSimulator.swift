//
//  RainSimulator.swift
//  NeuraLink
//
//  CPU-side drop physics: main drops (moving) + small static spray droplets.

import Foundation

struct RainDrop {
    var x, y, r: Float
    var spreadX: Float = 0
    var spreadY: Float = 0
    var alpha: Float = 1.0
    var momentum: Float = 0
    var momentumX: Float = 0
    var lastSpawn: Float = 0
    var nextSpawn: Float = 0
    var shrink: Float = 0
    var isNew: Bool  = true
    var killed: Bool  = false
}

final class RainSimulator {

    // Accessible by tests
    let minR: Float = 0.013
    let maxR: Float = 0.048

    let maxDrops: Int   = 180
    private let rainChance: Float = 0.08
    private let rainLimit: Int   = 2
    private let trailRate: Float = 1.0
    private let trailScaleMin: Float = 0.20
    private let trailScaleMax: Float = 0.45
    private let collisionRadius: Float = 0.45
    private let momentumScale: Float = 0.0012
    private let spawnYMin: Float = -0.05
    private let spawnYMax: Float =  0.90

    private let dropletsRate: Float = 15.0   // spawns per second
    private let dropletMinR: Float = 0.001
    private let dropletMaxR: Float = 0.003
    private let dropletAlphaDecay: Float = 0.05
    let maxDroplets: Int   = 80

    private(set) var drops: [RainDrop] = []
    private(set) var droplets: [RainDrop] = []
    private var dropletsCounter: Float = 0

    func update(ts: Float, intensity: Float) {
        updateDroplets(ts: ts, intensity: intensity)
        updateMainDrops(ts: ts, intensity: intensity)
    }

    // MARK: - Droplets

    private func updateDroplets(ts: Float, intensity: Float) {
        guard intensity > 0 else { droplets.removeAll(); return }

        for i in (0..<droplets.count).reversed() {
            droplets[i].alpha -= dropletAlphaDecay * ts
            if droplets[i].alpha <= 0 { droplets.remove(at: i) }
        }

        dropletsCounter += dropletsRate * ts
        if dropletsCounter >= 1 {
            dropletsCounter = 0
            if droplets.count < maxDroplets {
                let r = lerp(dropletMinR, dropletMaxR, Float.random(in: 0...1))
                droplets.append(RainDrop(
                    x: Float.random(in: 0...1),
                    y: Float.random(in: 0...1),
                    r: r,
                    alpha: 1.0
                ))
            }
        }
    }

    private func clearDroplets(x: Float, y: Float, r: Float) {
        droplets.removeAll { d in
            let dx = d.x - x, dy = d.y - y
            return (dx * dx + dy * dy).squareRoot() < r
        }
    }

    // MARK: - Main drops

    private func updateMainDrops(ts: Float, intensity: Float) {
        var next: [RainDrop] = []
        next.reserveCapacity(maxDrops)

        let lim = Float(rainLimit) * ts
        var spawned = 0
        while Float.random(in: 0...1) < rainChance * ts * intensity && Float(spawned) < lim {
            spawned += 1
            let r = lerp(minR, maxR, pow(Float.random(in: 0...1), 3))
            let dr = maxR - minR
            next.append(RainDrop(
                x: Float.random(in: 0...1),
                y: Float.random(in: spawnYMin...spawnYMax),
                r: r,
                spreadX: 1.5,
                spreadY: 1.5,
                momentum: 1 + (r - minR) / dr * 2.0 + Float.random(in: 0...1)
            ))
        }

        drops.sort { $0.y * 10000 + $0.x < $1.y * 10000 + $1.x }

        let dr = maxR - minR
        for i in 0..<drops.count {
            var drop = drops[i]
            if drop.killed { continue }

            if Float.random(in: 0...1) < (drop.r - minR) * (0.1 / dr) * ts {
                drop.momentum += Float.random(in: 0...(drop.r / maxR * 4))
            }
            if drop.r <= minR && Float.random(in: 0...1) < 0.05 * ts {
                drop.shrink += 0.001
            }
            drop.r -= drop.shrink * ts
            if drop.r <= 0 { drop.killed = true; continue }

            if intensity > 0 {
                drop.lastSpawn += drop.momentum * ts * trailRate
                if drop.lastSpawn > drop.nextSpawn, next.count + 1 <= maxDrops {
                    let trailR = drop.r * lerp(trailScaleMin, trailScaleMax, Float.random(in: 0...1))
                    next.append(RainDrop(
                        x: drop.x + Float.random(in: -drop.r...drop.r) * 0.1,
                        y: drop.y - drop.r * 0.01,
                        r: trailR,
                        spreadY: drop.momentum * 0.1
                    ))
                    drop.r *= pow(0.97, ts)
                    drop.lastSpawn = 0
                    drop.nextSpawn = lerp(minR, maxR, Float.random(in: 0...1))
                        - drop.momentum * 2 * trailRate
                        + (maxR - drop.r)
                }
            }

            drop.spreadX *= pow(0.4, ts)
            drop.spreadY *= pow(0.7, ts)

            let moved = drop.momentum > 0
            if moved {
                drop.y += drop.momentum * momentumScale * ts
                drop.x += drop.momentumX * momentumScale * ts
                if drop.y > 1.0 + drop.r { drop.killed = true }
            }

            if (moved || drop.isNew) && !drop.killed {
                for j in (i + 1)..<min(i + 70, drops.count) {
                    let d2 = drops[j]
                    if d2.killed || drop.r <= d2.r { continue }
                    let dx = d2.x - drop.x, dy = d2.y - drop.y
                    let dist = (dx * dx + dy * dy).squareRoot()
                    let colR = (drop.r + d2.r) * (collisionRadius + drop.momentum * 0.01 * ts)
                    if dist < colR {
                        let a1 = Float.pi * drop.r * drop.r
                        let a2 = Float.pi * d2.r * d2.r
                        let tr = min(((a1 + a2 * 0.8) / Float.pi).squareRoot(), maxR)
                        drop.r = tr
                        drop.momentumX += dx * 0.1
                        drop.spreadX = 0; drop.spreadY = 0
                        drops[j].killed = true
                        drop.momentum = max(d2.momentum, min(40, drop.momentum + tr * 0.05 + 1))
                        clearDroplets(x: drop.x, y: drop.y, r: drop.r * 0.28)
                    }
                }
            }

            drop.isNew = false
            drop.momentum = max(0, drop.momentum - max(1, minR * 0.5 - drop.momentum) * 0.1 * ts)
            drop.momentumX *= pow(0.7, ts)

            if !drop.killed { next.append(drop) }
        }
        drops = next
    }

    private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + t * (b - a) }
}
