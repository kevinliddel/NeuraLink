//
//  PropMeshBuilder.swift
//  NeuraLink
//
//  Procedural rigid-prop geometry (the keepsake table and what stands on
//  it) in the renderer's own vertex layout: boxes, cylinders and single
//  faces with flat normals and a texture rectangle per face, in metres,
//  wound counter-clockwise as glTF has it. Everything a VRMPrimitive
//  needs and nothing a file would add.
//
//  Created by Dedicatus on 05/11/2026.
//

import Foundation
import Metal
import simd

nonisolated struct PropMeshBuilder {

    /// A rectangle of texture space (v = 0 at the top, as glTF samples).
    struct UVRect: Equatable {
        var u0: Float
        var v0: Float
        var u1: Float
        var v1: Float

        static let full = UVRect(u0: 0, v0: 0, u1: 1, v1: 1)

        /// One cell of a grid atlas (row 0 at the top).
        static func cell(_ column: Int, _ row: Int, columns: Int, rows: Int) -> UVRect {
            let width = 1 / Float(columns), height = 1 / Float(rows)
            return UVRect(
                u0: Float(column) * width, v0: Float(row) * height,
                u1: Float(column + 1) * width, v1: Float(row + 1) * height)
        }

        /// The middle of the picture at `aspect` (width / height): a
        /// picture wider than the opening loses its sides, a taller one
        /// its top and bottom.
        static func centred(pictureAspect: Float, opening aspect: Float) -> UVRect {
            guard pictureAspect > 0, aspect > 0 else { return .full }
            if pictureAspect > aspect {
                let keep = aspect / pictureAspect
                return UVRect(u0: (1 - keep) / 2, v0: 0, u1: (1 + keep) / 2, v1: 1)
            }
            let keep = pictureAspect / aspect
            return UVRect(u0: 0, v0: (1 - keep) / 2, u1: 1, v1: (1 + keep) / 2)
        }
    }

    enum BoxFace: CaseIterable { case front, back, right, left, top, bottom }

    private(set) var vertices: [VRMVertex] = []
    private(set) var indices: [UInt32] = []
    private(set) var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    private(set) var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

    var isEmpty: Bool { indices.isEmpty }
    var triangleCount: Int { indices.count / 3 }
    var extent: SIMD3<Float> { isEmpty ? .zero : high - low }

    /// One flat face, `centre` ± `right` ± `up` (half-extent vectors), lit
    /// along `right × up`; `uv` spans it with the picture's top at `+up`.
    mutating func addFace(centre: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>, uv: UVRect = .full) {
        let normal = simd_normalize(simd_cross(right, up))
        let bottomLeft: SIMD3<Float> = centre - right - up
        let bottomRight: SIMD3<Float> = centre + right - up
        let topRight: SIMD3<Float> = centre + right + up
        let topLeft: SIMD3<Float> = centre - right + up
        let corners: [SIMD3<Float>] = [bottomLeft, bottomRight, topRight, topLeft]
        let texCoords: [SIMD2<Float>] = [tex(uv.u0, uv.v1), tex(uv.u1, uv.v1), tex(uv.u1, uv.v0), tex(uv.u0, uv.v0)]
        let base = UInt32(vertices.count)
        for (position, texCoord) in zip(corners, texCoords) {
            var vertex = VRMVertex()
            vertex.position = position
            vertex.normal = normal
            vertex.texCoord = texCoord
            vertices.append(vertex)
            include(position)
        }
        indices += [base, base + 1, base + 2, base, base + 2, base + 3]
    }

    /// An axis-aligned box about `centre`. Faces not in `faces` are left
    /// open; a face without an entry in `uv` takes the whole texture.
    mutating func addBox(
        centre: SIMD3<Float>, size: SIMD3<Float>, faces: Set<BoxFace> = Set(BoxFace.allCases), uv: [BoxFace: UVRect] = [:]
    ) {
        let half = size * 0.5
        let x = SIMD3<Float>(half.x, 0, 0), y = SIMD3<Float>(0, half.y, 0), z = SIMD3<Float>(0, 0, half.z)
        for face in BoxFace.allCases where faces.contains(face) {
            let rect = uv[face] ?? .full
            switch face {
            case .front: addFace(centre: centre + z, right: x, up: y, uv: rect)
            case .back: addFace(centre: centre - z, right: -x, up: y, uv: rect)
            case .right: addFace(centre: centre + x, right: -z, up: y, uv: rect)
            case .left: addFace(centre: centre - x, right: z, up: y, uv: rect)
            case .top: addFace(centre: centre + y, right: x, up: -z, uv: rect)
            case .bottom: addFace(centre: centre - y, right: x, up: z, uv: rect)
            }
        }
    }

    /// A cylinder along Y (a cone when the radii differ) about `axis`
    /// (x, z), smooth-shaded sides and flat caps.
    mutating func addCylinder(
        axis: SIMD2<Float> = .zero, bottom: Float, top: Float, bottomRadius: Float, topRadius: Float,
        segments: Int = 24, caps: Bool = true, sideUV: UVRect = .full
    ) {
        let count = max(3, segments)
        let height = top - bottom
        func ring(_ step: Int, radius: Float, y: Float) -> SIMD3<Float> {
            let angle = 2 * Float.pi * Float(step) / Float(count)
            return SIMD3<Float>(axis.x + radius * cos(angle), y, axis.y + radius * sin(angle))
        }
        func sideNormal(_ step: Int) -> SIMD3<Float> {
            let angle = 2 * Float.pi * Float(step) / Float(count)
            return simd_normalize(SIMD3<Float>(height * cos(angle), bottomRadius - topRadius, height * sin(angle)))
        }
        for step in 0..<count {
            // Ordered so the geometric normal points out of the side.
            let corners = [
                ring(step + 1, radius: bottomRadius, y: bottom), ring(step, radius: bottomRadius, y: bottom),
                ring(step, radius: topRadius, y: top), ring(step + 1, radius: topRadius, y: top)
            ]
            let normals = [sideNormal(step + 1), sideNormal(step), sideNormal(step), sideNormal(step + 1)]
            let span = sideUV.u1 - sideUV.u0
            let u0 = sideUV.u0 + span * Float(step) / Float(count)
            let u1 = sideUV.u0 + span * Float(step + 1) / Float(count)
            let texCoords: [SIMD2<Float>] = [tex(u1, sideUV.v1), tex(u0, sideUV.v1), tex(u0, sideUV.v0), tex(u1, sideUV.v0)]
            let base = UInt32(vertices.count)
            for index in 0..<4 {
                var vertex = VRMVertex()
                vertex.position = corners[index]
                vertex.normal = normals[index]
                vertex.texCoord = texCoords[index]
                vertices.append(vertex)
                include(corners[index])
            }
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        guard caps else { return }
        addCap(y: top, radius: topRadius, axis: axis, segments: count, facingUp: true)
        addCap(y: bottom, radius: bottomRadius, axis: axis, segments: count, facingUp: false)
    }

    /// A flat disc fan at `y`, lit along ±Y.
    private mutating func addCap(y: Float, radius: Float, axis: SIMD2<Float>, segments: Int, facingUp: Bool) {
        let normal = SIMD3<Float>(0, facingUp ? 1 : -1, 0)
        let base = UInt32(vertices.count)
        var centre = VRMVertex()
        centre.position = SIMD3<Float>(axis.x, y, axis.y)
        centre.normal = normal
        centre.texCoord = SIMD2<Float>(0.5, 0.5)
        vertices.append(centre)
        include(centre.position)
        for step in 0..<segments {
            let angle = 2 * Float.pi * Float(step) / Float(segments)
            var vertex = VRMVertex()
            vertex.position = SIMD3<Float>(axis.x + radius * cos(angle), y, axis.y + radius * sin(angle))
            vertex.normal = normal
            vertex.texCoord = SIMD2<Float>(0.5 + 0.5 * cos(angle), 0.5 + 0.5 * sin(angle))
            vertices.append(vertex)
            include(vertex.position)
        }
        for step in 0..<segments {
            let current = base + 1 + UInt32(step)
            let next = base + 1 + UInt32((step + 1) % segments)
            // Going round in +angle faces −Y; the top cap goes the other way.
            indices += facingUp ? [base, next, current] : [base, current, next]
        }
    }

    /// The geometry as one primitive with `materialIndex`, or nil when
    /// empty or when the device has no memory for it.
    func makePrimitive(device: MTLDevice, materialIndex: Int) -> VRMPrimitive? {
        guard !vertices.isEmpty, !indices.isEmpty else { return nil }
        let primitive = VRMPrimitive()
        primitive.materialIndex = materialIndex
        primitive.vertexCount = vertices.count
        primitive.indexCount = indices.count
        primitive.hasNormals = true
        primitive.hasTexCoords = true
        primitive.vertexBuffer = device.makeBuffer(
            bytes: vertices, length: vertices.count * MemoryLayout<VRMVertex>.stride, options: .storageModeShared)
        if vertices.count < Int(UInt16.max) {
            let shorts = indices.map { UInt16($0) }
            primitive.indexType = .uint16
            primitive.indexBuffer = device.makeBuffer(
                bytes: shorts, length: shorts.count * MemoryLayout<UInt16>.stride, options: .storageModeShared)
        } else {
            primitive.indexType = .uint32
            primitive.indexBuffer = device.makeBuffer(
                bytes: indices, length: indices.count * MemoryLayout<UInt32>.stride, options: .storageModeShared)
        }
        guard primitive.vertexBuffer != nil, primitive.indexBuffer != nil else { return nil }
        return primitive
    }

    private mutating func include(_ position: SIMD3<Float>) {
        low = simd_min(low, position)
        high = simd_max(high, position)
    }

    private func tex(_ u: Float, _ v: Float) -> SIMD2<Float> {
        SIMD2<Float>(u, v)
    }
}
