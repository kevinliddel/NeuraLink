//
//  ARDYPortableRandom.swift
//  NeuraLink
//
//  The browser runtime's reproducible noise source (web/src/runtime/random.ts
//  in intsuc/ardy-mini): Mulberry32 for uniforms, the Marsaglia polar method
//  for Gaussians, every written value rounded to float32. Same seed, same
//  noise, same motion as the Python driver (scripts/ardy_mini_batch.py)
//  and the fixtures it wrote. See docs/GENERATIVE_MOTION.md.
//
//  Created by Dedicatus on 29/10/2026.
//

import Foundation

struct ARDYPortableRandom: Sendable {
    private static let range = Double(UInt64(1) << 32)
    private static let epsilon = 2.220446049250313e-16

    let seed: UInt32
    private var state: UInt32
    private var spare: Double?

    init(seed: UInt32) {
        self.seed = seed
        state = seed
    }

    /// A text seed hashes with FNV-1a, as the browser does.
    init(seed text: String) {
        var hash: UInt32 = 0x811C_9DC5
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        self.init(seed: hash)
    }

    mutating func nextUInt32() -> UInt32 {
        state = state &+ 0x6D2B_79F5
        var value = state
        value = (value ^ (value >> 15)) &* (value | 1)
        value ^= value &+ ((value ^ (value >> 7)) &* (value | 61))
        return value ^ (value >> 14)
    }

    mutating func nextDouble() -> Double {
        (Double(nextUInt32()) + 1) / (Self.range + 1)
    }

    mutating func nextNormal() -> Double {
        if let cached = spare {
            spare = nil
            return cached
        }
        var x = 0.0
        var y = 0.0
        var radiusSquared = 0.0
        repeat {
            x = 2 * nextDouble() - 1
            y = 2 * nextDouble() - 1
            radiusSquared = x * x + y * y
        } while radiusSquared <= Self.epsilon || radiusSquared >= 1
        let scale = (-2 * log(radiusSquared) / radiusSquared).squareRoot()
        spare = y * scale
        return x * scale
    }

    /// Fills `target[start..<end]` with float32-rounded Gaussians.
    mutating func fillNormal(_ target: inout [Float], from start: Int, to end: Int) {
        guard start >= 0, end <= target.count, start <= end else { return }
        for index in start..<end {
            target[index] = Float(nextNormal())
        }
    }
}
