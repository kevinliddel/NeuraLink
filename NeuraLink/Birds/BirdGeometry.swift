//
//  BirdGeometry.swift
//  NeuraLink
//
//  Created by Dedicatus on 21/04/2026.
//

import simd

/// Vertex format for bird geometry uploaded to the GPU.
/// Stride = 32 bytes. Must match the MTLVertexDescriptor in BirdRenderer.
struct BirdVertexData {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var part: Int32  // 0 = body/tail, 1 = leftWing, 2 = rightWing
    var pad: Int32 = 0
}

/// Builds a low-poly bird as a flat triangle list (no index buffer).
///
/// Bird faces -Z (nose) / +Z (tail), wings along ±X.
/// Total: 14 triangles → 42 vertices.
enum BirdGeometry {

    static func makeVertices() -> [BirdVertexData] {
        var verts: [BirdVertexData] = []
        verts += makeBody()
        verts += makeWing(side: -1, part: 1)
        verts += makeWing(side: 1, part: 2)
        verts += makeTail()
        return verts
    }

    // MARK: - Body (8 triangles — diamond cross-section)

    private static func makeBody() -> [BirdVertexData] {
        let nose = SIMD3<Float>(0, 0, -0.12)
        let tail = SIMD3<Float>(0, 0, 0.10)
        let top = SIMD3<Float>(0, 0.025, 0)
        let bot = SIMD3<Float>(0, -0.018, 0)
        let left = SIMD3<Float>(-0.026, 0, 0.01)
        let right = SIMD3<Float>(0.026, 0, 0.01)

        return [
            // Front cone — nose toward -Z
            tri(nose, top, right, 0),
            tri(nose, left, top, 0),
            tri(nose, right, bot, 0),
            tri(nose, bot, left, 0),
            // Rear cone — tail toward +Z
            tri(tail, right, top, 0),
            tri(tail, top, left, 0),
            tri(tail, bot, right, 0),
            tri(tail, left, bot, 0)
        ].flatMap { $0 }
    }

    // MARK: - Wings (2 triangles each, swept-back planform)

    private static func makeWing(side: Float, part: Int32) -> [BirdVertexData] {
        let rFront = SIMD3<Float>(side * 0.03, 0, -0.01)
        let rBack = SIMD3<Float>(side * 0.03, 0, 0.04)
        let tFront = SIMD3<Float>(side * 0.18, 0, 0.00)
        let tBack = SIMD3<Float>(side * 0.15, 0, 0.06)

        if side < 0 {
            return tri(rFront, tFront, rBack, part) + tri(tFront, tBack, rBack, part)
        } else {
            return tri(rFront, rBack, tFront, part) + tri(tFront, rBack, tBack, part)
        }
    }

    // MARK: - Tail (2 triangles)

    private static func makeTail() -> [BirdVertexData] {
        let base = SIMD3<Float>(0, 0, 0.10)
        let tailLeft = SIMD3<Float>(-0.04, -0.010, 0.18)
        let tailRight = SIMD3<Float>(0.04, -0.010, 0.18)
        let tip = SIMD3<Float>(0, -0.005, 0.20)

        return tri(base, tailLeft, tip, 0) + tri(base, tip, tailRight, 0)
    }

    // MARK: - Helpers

    private static func tri(
        _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ part: Int32
    ) -> [BirdVertexData] {
        let n = simd_normalize(simd_cross(b - a, c - a))
        return [
            BirdVertexData(position: a, normal: n, part: part),
            BirdVertexData(position: b, normal: n, part: part),
            BirdVertexData(position: c, normal: n, part: part)
        ]
    }
}
