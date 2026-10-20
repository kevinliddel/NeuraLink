//
//  CoplanarLayering.swift
//  NeuraLink
//
//  Some exports (SketchUp through Sketchfab, notably) carry two copies of
//  the same surface — a plain shell under the textured detail, laid in the
//  exact same plane. Drawn as-is, the two trade places pixel by pixel as the
//  camera moves (z-fighting): the pool's marble floor striped with the white
//  shell, the modern apartment's rooms flickering black. This finds, at load,
//  every pair of mesh groups that share an axis-aligned plane facing the
//  same way over an overlapping area, and gives the later group a layer above
//  the earlier one; the draw pass turns layers into a small depth bias, so
//  the later — detailed — copy always wins.
//
//  Only axis-aligned faces are compared: floors, walls and ceilings are where
//  duplicate shells live, and it keeps the pass linear in triangle count.
//  Framework-free and unit-tested.
//
//  Created by Dedicatus on 20/10/2026.
//

import Foundation
import simd

/// One axis-aligned plane a group draws on, with the rectangle it covers.
nonisolated struct CoplanarFace: Equatable, Sendable {
    /// 0 = x, 1 = y, 2 = z — the axis the plane is perpendicular to.
    let axis: Int
    /// +1 when the face points along the axis, −1 against it.
    let facing: Int
    let coord: Float
    var minU: Float
    var minV: Float
    var maxU: Float
    var maxV: Float
}

nonisolated enum CoplanarLayering {

    /// A face counts as axis-aligned when its normal is within ~2.5° of an axis.
    static let alignment: Float = 0.999

    /// The axis-aligned faces of one primitive, in the space `transform`
    /// maps to, merged per exact plane.
    static func faces(positions: [Float], indices: [UInt32], transform: simd_float4x4) -> [CoplanarFace] {
        let vertexCount = positions.count / 3
        var world = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        for i in 0..<vertexCount {
            let p = transform * SIMD4<Float>(positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2], 1)
            world[i] = SIMD3<Float>(p.x, p.y, p.z)
        }
        struct Key: Hashable { let axis: Int; let facing: Int; let coord: UInt32 }
        var merged: [Key: CoplanarFace] = [:]
        var t = 0
        while t + 2 < indices.count {
            defer { t += 3 }
            let i0 = Int(indices[t]), i1 = Int(indices[t + 1]), i2 = Int(indices[t + 2])
            guard i0 < vertexCount, i1 < vertexCount, i2 < vertexCount else { continue }
            let a = world[i0], b = world[i1], c = world[i2]
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            guard length > 1e-12 else { continue }
            let normal = cross / length
            let magnitudes = simd_abs(normal)
            let axis = magnitudes.x >= magnitudes.y ? (magnitudes.x >= magnitudes.z ? 0 : 2) : (magnitudes.y >= magnitudes.z ? 1 : 2)
            guard magnitudes[axis] >= alignment else { continue }
            let u = (axis + 1) % 3, v = (axis + 2) % 3
            let coord = (a[axis] + b[axis] + c[axis]) / 3
            let key = Key(axis: axis, facing: normal[axis] > 0 ? 1 : -1, coord: coord.bitPattern)
            let minU = min(a[u], b[u], c[u]), maxU = max(a[u], b[u], c[u])
            let minV = min(a[v], b[v], c[v]), maxV = max(a[v], b[v], c[v])
            if var face = merged[key] {
                face.minU = min(face.minU, minU); face.maxU = max(face.maxU, maxU)
                face.minV = min(face.minV, minV); face.maxV = max(face.maxV, maxV)
                merged[key] = face
            } else {
                merged[key] = CoplanarFace(
                    axis: axis, facing: key.facing, coord: coord, minU: minU, minV: minV, maxU: maxU, maxV: maxV)
            }
        }
        return Array(merged.values)
    }

    /// The layer of every group, in group order: 0 unless it shares a plane
    /// (within `tolerance`, same facing, overlapping area) with an earlier
    /// group, and then one above the highest such group.
    static func layers(faces: [[CoplanarFace]], tolerance: Float) -> [Int] {
        struct Entry { let group: Int; let face: CoplanarFace }
        var entries: [Entry] = []
        for (group, list) in faces.enumerated() {
            for face in list { entries.append(Entry(group: group, face: face)) }
        }
        entries.sort {
            ($0.face.axis, $0.face.facing, $0.face.coord) < ($1.face.axis, $1.face.facing, $1.face.coord)
        }
        var below = [Set<Int>](repeating: [], count: faces.count)
        for i in entries.indices {
            let a = entries[i].face
            var j = i + 1
            while j < entries.count {
                let b = entries[j].face
                guard b.axis == a.axis, b.facing == a.facing, b.coord - a.coord <= tolerance else { break }
                let ga = entries[i].group, gb = entries[j].group
                if ga != gb,
                   min(a.maxU, b.maxU) - max(a.minU, b.minU) > tolerance,
                   min(a.maxV, b.maxV) - max(a.minV, b.minV) > tolerance {
                    below[max(ga, gb)].insert(min(ga, gb))
                }
                j += 1
            }
        }
        var layers = [Int](repeating: 0, count: faces.count)
        for group in layers.indices {
            layers[group] = below[group].map { layers[$0] + 1 }.max() ?? 0
        }
        return layers
    }
}
