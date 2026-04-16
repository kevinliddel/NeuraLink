//
//  VRMRestTransform.swift
//  NeuraLink
//
//  Created by Dedicatus on 14/04/2026.
//

import Foundation
import simd

// MARK: - Rest Transform

struct RestTransform {
    var rotation: simd_quatf
    var translation: SIMD3<Float>
    var scale: SIMD3<Float>

    static let identity = RestTransform(
        rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
        translation: .zero,
        scale: SIMD3<Float>(repeating: 1))

    init(rotation: simd_quatf, translation: SIMD3<Float>, scale: SIMD3<Float>) {
        self.rotation    = rotation
        self.translation = translation
        self.scale       = scale
    }

    init(node: GLTFNode) {
        if let matrix = node.matrix, matrix.count == 16 {
            let m = gltfMatrix(from: matrix)
            let (t, r, s) = decomposeMatrix(m)
            self.init(rotation: r, translation: t, scale: s)
        } else {
            let r: simd_quatf
            if let v = node.rotation, v.count == 4 {
                r = simd_normalize(simd_quatf(ix: v[0], iy: v[1], iz: v[2], r: v[3]))
            } else {
                r = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            }
            let t = node.translation.flatMap { $0.count == 3 ? SIMD3<Float>($0[0], $0[1], $0[2]) : nil } ?? .zero
            let s = node.scale.flatMap { $0.count == 3 ? SIMD3<Float>($0[0], $0[1], $0[2]) : nil } ?? SIMD3<Float>(repeating: 1)
            self.init(rotation: r, translation: t, scale: s)
        }
    }
}

// MARK: - Rest Transform Builders

func buildAnimationRestTransforms(document: GLTFDocument) -> [Int: RestTransform] {
    guard let nodes = document.nodes else { return [:] }
    return Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.offset, RestTransform(node: $0.element)) })
}

func buildModelRestTransforms(model: VRMModel?) -> [VRMHumanoidBone: RestTransform] {
    guard let model, let humanoid = model.humanoid, let gltfNodes = model.gltf.nodes else { return [:] }
    var map: [VRMHumanoidBone: RestTransform] = [:]
    for bone in VRMHumanoidBone.allCases {
        guard let idx = humanoid.getBoneNode(bone), idx < gltfNodes.count else { continue }
        map[bone] = RestTransform(node: gltfNodes[idx])
    }
    return map
}

// MARK: - Matrix Math

private func gltfMatrix(from values: [Float]) -> float4x4 {
    float4x4(
        SIMD4<Float>(values[0], values[4], values[8],  values[12]),
        SIMD4<Float>(values[1], values[5], values[9],  values[13]),
        SIMD4<Float>(values[2], values[6], values[10], values[14]),
        SIMD4<Float>(values[3], values[7], values[11], values[15]))
}

/// Decomposes a 4×4 TRS matrix into translation, rotation, and scale components.
private func decomposeMatrix(_ m: float4x4) -> (translation: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>) {
    let t = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)

    var c0 = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
    var c1 = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
    var c2 = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)

    var sx = length(c0); if sx > 1e-6 { c0 /= sx } else { sx = 1 }
    var sy = length(c1); if sy > 1e-6 { c1 /= sy } else { sy = 1 }
    var sz = length(c2); if sz > 1e-6 { c2 /= sz } else { sz = 1 }

    var rot = float3x3(columns: (c0, c1, c2))
    if simd_determinant(rot) < 0 { sx = -sx; rot.columns.0 = -rot.columns.0 }

    return (t, simd_quatf(rot), SIMD3<Float>(sx, sy, sz))
}
