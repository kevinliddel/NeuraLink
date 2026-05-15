//
//  VRMGeometry+Helpers.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import Foundation
import Metal
import simd

// MARK: - Vertex Data

struct VertexData {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var texCoords: [SIMD2<Float>] = []
    var colors: [SIMD4<Float>] = []
    var tangents: [SIMD4<Float>] = []
    var joints: [SIMD4<UInt32>] = []
    var weights: [SIMD4<Float>] = []

    func interleaved() -> [VRMVertex] {
        var vertices: [VRMVertex] = []

        for i in 0..<positions.count {
            var vertex = VRMVertex()

            vertex.position = positions[i]

            if i < normals.count {
                vertex.normal = normals[i]
            }

            if i < texCoords.count {
                vertex.texCoord = texCoords[i]
            }

            if i < colors.count {
                vertex.color = colors[i]
            }

            if i < joints.count {
                vertex.joints = joints[i]
            }

            if i < weights.count {
                vertex.weights = weights[i]
            }

            vertices.append(vertex)
        }

        return vertices
    }
}

// MARK: - Vertex Structure

public struct VRMVertex {
    public var position: SIMD3<Float> = [0, 0, 0]
    public var normal: SIMD3<Float> = [0, 1, 0]
    public var texCoord: SIMD2<Float> = [0, 0]
    public var color: SIMD4<Float> = [1, 1, 1, 1]
    public var joints: SIMD4<UInt32> = [0, 0, 0, 0]
    public var weights: SIMD4<Float> = [1, 0, 0, 0]
}

// MARK: - Helper Types

enum AccessorType {
    case scalar
    case vec2
    case vec3
    case vec4
    case mat2
    case mat3
    case mat4

    var componentCount: Int {
        switch self {
        case .scalar: return 1
        case .vec2: return 2
        case .vec3: return 3
        case .vec4: return 4
        case .mat2: return 4
        case .mat3: return 9
        case .mat4: return 16
        }
    }
}

extension MTLPrimitiveType {
    init(gltfMode: Int) {
        switch gltfMode {
        case 0: self = .point
        case 1: self = .line
        case 2: self = .lineStrip
        case 3: self = .lineStrip
        case 4: self = .triangle
        case 5: self = .triangleStrip
        case 6: self = .triangleStrip
        default: self = .triangle
        }
    }
}

// MARK: - Metal Format Mapping

extension VRMPrimitive {
    static func metalVertexFormat(
        componentType: Int, accessorType: String, normalized: Bool = false
    ) -> MTLVertexFormat? {
        switch (componentType, accessorType, normalized) {
        // FLOAT (5126)
        case (5126, "SCALAR", _): return .float
        case (5126, "VEC2", _): return .float2
        case (5126, "VEC3", _): return .float3
        case (5126, "VEC4", _): return .float4

        // UNSIGNED_BYTE (5121)
        case (5121, "SCALAR", false): return .uchar
        case (5121, "SCALAR", true): return .ucharNormalized
        case (5121, "VEC2", false): return .uchar2
        case (5121, "VEC2", true): return .uchar2Normalized
        case (5121, "VEC3", false): return .uchar3
        case (5121, "VEC3", true): return .uchar3Normalized
        case (5121, "VEC4", false): return .uchar4
        case (5121, "VEC4", true): return .uchar4Normalized

        // UNSIGNED_SHORT (5123)
        case (5123, "SCALAR", false): return .ushort
        case (5123, "SCALAR", true): return .ushortNormalized
        case (5123, "VEC2", false): return .ushort2
        case (5123, "VEC2", true): return .ushort2Normalized
        case (5123, "VEC3", false): return .ushort3
        case (5123, "VEC3", true): return .ushort3Normalized
        case (5123, "VEC4", false): return .ushort4
        case (5123, "VEC4", true): return .ushort4Normalized

        // BYTE (5120)
        case (5120, "SCALAR", false): return .char
        case (5120, "SCALAR", true): return .charNormalized
        case (5120, "VEC2", false): return .char2
        case (5120, "VEC2", true): return .char2Normalized
        case (5120, "VEC3", false): return .char3
        case (5120, "VEC3", true): return .char3Normalized
        case (5120, "VEC4", false): return .char4
        case (5120, "VEC4", true): return .char4Normalized

        // SHORT (5122)
        case (5122, "SCALAR", false): return .short
        case (5122, "SCALAR", true): return .shortNormalized
        case (5122, "VEC2", false): return .short2
        case (5122, "VEC2", true): return .short2Normalized
        case (5122, "VEC3", false): return .short3
        case (5122, "VEC3", true): return .short3Normalized
        case (5122, "VEC4", false): return .short4
        case (5122, "VEC4", true): return .short4Normalized

        default:
            return nil
        }
    }

    static func bytesPerComponent(_ componentType: Int) -> Int {
        switch componentType {
        case 5120, 5121: return 1  // BYTE, UNSIGNED_BYTE
        case 5122, 5123: return 2  // SHORT, UNSIGNED_SHORT
        case 5125, 5126: return 4  // UNSIGNED_INT, FLOAT
        default: return 4
        }
    }

    static func componentCount(for type: String) -> Int {
        switch type {
        case "SCALAR": return 1
        case "VEC2": return 2
        case "VEC3": return 3
        case "VEC4": return 4
        case "MAT2": return 4
        case "MAT3": return 9
        case "MAT4": return 16
        default: return 1
        }
    }
}

// MARK: - VRM Skin

public class VRMSkin {
    public let name: String?
    public var joints: [VRMNode] = []
    public var inverseBindMatrices: [float4x4] = []
    public var skeleton: VRMNode?

    // Buffer offset management for efficient multi-skin rendering
    public var bufferByteOffset: Int = 0
    public var matrixOffset: Int = 0

    public init(
        from gltfSkin: GLTFSkin, nodes: [VRMNode], document: GLTFDocument,
        bufferLoader: BufferLoader
    ) throws {
        self.name = gltfSkin.name

        // Get joint nodes
        for jointIndex in gltfSkin.joints {
            if jointIndex < nodes.count {
                joints.append(nodes[jointIndex])
            }
        }

        // Get skeleton root
        if let skeletonIndex = gltfSkin.skeleton, skeletonIndex < nodes.count {
            skeleton = nodes[skeletonIndex]
        }

        // Load inverse bind matrices
        if let inverseBindMatricesIndex = gltfSkin.inverseBindMatrices {
            // Load actual inverse bind matrices from accessor
            do {
                inverseBindMatrices = try bufferLoader.loadAccessorAsMatrix4x4(
                    inverseBindMatricesIndex)
            } catch {
                inverseBindMatrices = Array(
                    repeating: matrix_identity_float4x4, count: joints.count)
            }
        } else {
            // Use identity matrices if not specified
            inverseBindMatrices = Array(repeating: matrix_identity_float4x4, count: joints.count)
        }
    }
}

// MARK: - VRM Texture

public class VRMTexture {
    public var mtlTexture: MTLTexture?
    public var sampler: MTLSamplerState?
    public let name: String?

    public init(name: String? = nil, mtlTexture: MTLTexture? = nil) {
        self.name = name
        self.mtlTexture = mtlTexture
    }
}

// MARK: - Matrix Extensions

extension float4x4 {
    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3.x = t.x
        columns.3.y = t.y
        columns.3.z = t.z
    }

    init(_ quaternion: simd_quatf) {
        self = simd_matrix4x4(quaternion)
    }

    init(scaling s: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.0.x = s.x
        columns.1.y = s.y
        columns.2.z = s.z
    }
}
