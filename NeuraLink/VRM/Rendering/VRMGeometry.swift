//
//  VRMGeometry.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import Foundation
import Metal
import simd

// MARK: - VRM Mesh

public class VRMMesh {
    public let name: String?
    public var primitives: [VRMPrimitive] = []

    public init(name: String? = nil) {
        self.name = name
    }

    public static func load(
        from gltfMesh: GLTFMesh,
        document: GLTFDocument,
        device: MTLDevice?,
        bufferLoader: BufferLoader
    ) async throws -> VRMMesh {
        let mesh = VRMMesh(name: gltfMesh.name)

        for (_, gltfPrimitive) in gltfMesh.primitives.enumerated() {
            let primitive = try await VRMPrimitive.load(
                from: gltfPrimitive,
                document: document,
                device: device,
                bufferLoader: bufferLoader
            )
            mesh.primitives.append(primitive)
        }

        return mesh
    }
}

// MARK: - VRM Primitive

public class VRMPrimitive {
    public var vertexBuffer: MTLBuffer?
    public var indexBuffer: MTLBuffer?
    public var vertexCount: Int = 0
    public var indexCount: Int = 0
    public var indexType: MTLIndexType = .uint16
    public var indexBufferOffset: Int = 0  // Byte offset for index buffer from accessor
    public var primitiveType: MTLPrimitiveType = .triangle
    public var materialIndex: Int?

    // Vertex attributes
    public var hasNormals = false
    public var hasTexCoords = false
    public var hasTangents = false
    public var hasColors = false
    public var hasJoints = false
    public var hasWeights = false

    // Skinning requirements
    public var requiredPaletteSize: Int = 0  // Minimum joints needed (maxJoint + 1 from JOINTS_0 data)

    // Morph targets
    public var morphTargets: [VRMMorphTarget] = []
    public var morphPositionBuffers: [MTLBuffer] = []
    public var morphNormalBuffers: [MTLBuffer] = []
    public var morphTangentBuffers: [MTLBuffer] = []

    // SoA morph buffers for compute path
    public var morphPositionsSoA: MTLBuffer?  // Layout: [morph0[v0..vN], morph1[v0..vN], ...]
    public var morphNormalsSoA: MTLBuffer?  // Same layout for normals
    public var basePositionsBuffer: MTLBuffer?  // Base positions for compute
    public var baseNormalsBuffer: MTLBuffer?  // Base normals for compute

    public init() {}

    public static func load(
        from gltfPrimitive: GLTFPrimitive,
        document: GLTFDocument,
        device: MTLDevice?,
        bufferLoader: BufferLoader
    ) async throws -> VRMPrimitive {
        let primitive = VRMPrimitive()
        primitive.materialIndex = gltfPrimitive.material

        // Set primitive type
        let mode = gltfPrimitive.mode ?? 4  // Default to triangles
        primitive.primitiveType = MTLPrimitiveType(gltfMode: mode)

        // UNIFIED PATH: Load all attributes into VertexData struct and interleave manually.
        // This ensures all primitives, interleaved or not, produce a vertex buffer
        // with the exact layout expected by the renderer.
        var vertexData = VertexData()

        // Load positions (required)
        if let positionAccessorIndex = gltfPrimitive.attributes["POSITION"] {
            let positions = try bufferLoader.loadAccessorAsFloat(positionAccessorIndex)
            let positionCount = (positions.count / 3) * 3
            vertexData.positions = stride(from: 0, to: positionCount, by: 3).map { i in
                SIMD3<Float>(positions[i], positions[i + 1], positions[i + 2])
            }
            primitive.vertexCount = vertexData.positions.count
        } else {
            throw VRMError.missingVertexAttribute(
                meshIndex: 0,  // We don't have meshIndex in this context, but this is a required POSITION attribute
                attributeName: "POSITION",
                filePath: bufferLoader.filePath
            )
        }

        // Load other attributes...
        if let normalAccessorIndex = gltfPrimitive.attributes["NORMAL"] {
            let normals = try bufferLoader.loadAccessorAsFloat(normalAccessorIndex)
            let normalCount = (normals.count / 3) * 3
            vertexData.normals = stride(from: 0, to: normalCount, by: 3).map { i in
                SIMD3<Float>(normals[i], normals[i + 1], normals[i + 2])
            }
            primitive.hasNormals = true
        }

        if let texCoordAccessorIndex = gltfPrimitive.attributes["TEXCOORD_0"] {
            let texCoords = try bufferLoader.loadAccessorAsFloat(texCoordAccessorIndex)
            let texCoordCount = (texCoords.count / 2) * 2
            vertexData.texCoords = stride(from: 0, to: texCoordCount, by: 2).map { i in
                SIMD2<Float>(texCoords[i], texCoords[i + 1])
            }
            primitive.hasTexCoords = true
        }

        if let colorAccessorIndex = gltfPrimitive.attributes["COLOR_0"] {
            let colors = try bufferLoader.loadAccessorAsFloat(colorAccessorIndex)
            let colorCount = (colors.count / 4) * 4
            vertexData.colors = stride(from: 0, to: colorCount, by: 4).map { i in
                SIMD4<Float>(colors[i], colors[i + 1], colors[i + 2], colors[i + 3])
            }
            primitive.hasColors = true
        }

        if let jointsAccessorIndex = gltfPrimitive.attributes["JOINTS_0"] {
            let joints = try bufferLoader.loadAccessorAsUInt32(jointsAccessorIndex)
            let jointCount = (joints.count / 4) * 4

            // SANITIZE: Clamp sentinel values (65535, -1, etc.) to prevent vertex explosion
            // VRM models typically have < 256 bones, so anything >= 256 is suspicious
            let maxValidJoint: UInt32 = 255
            var sanitizedCount = 0

            vertexData.joints = stride(from: 0, to: jointCount, by: 4).map { i in
                var j0 = joints[i]
                var j1 = joints[i + 1]
                var j2 = joints[i + 2]
                var j3 = joints[i + 3]

                // Clamp out-of-bounds indices to 0 (root bone)
                if j0 > maxValidJoint {
                    j0 = 0
                    sanitizedCount += 1
                }
                if j1 > maxValidJoint {
                    j1 = 0
                    sanitizedCount += 1
                }
                if j2 > maxValidJoint {
                    j2 = 0
                    sanitizedCount += 1
                }
                if j3 > maxValidJoint {
                    j3 = 0
                    sanitizedCount += 1
                }

                return SIMD4<UInt32>(j0, j1, j2, j3)
            }

            // Compute required palette size from SANITIZED joint indices
            let maxJoint = vertexData.joints.flatMap { [$0.x, $0.y, $0.z, $0.w] }.max() ?? 0
            primitive.requiredPaletteSize = Int(maxJoint) + 1
            primitive.hasJoints = true
        }

        if let weightsAccessorIndex = gltfPrimitive.attributes["WEIGHTS_0"] {
            let weights = try bufferLoader.loadAccessorAsFloat(weightsAccessorIndex)
            let weightCount = (weights.count / 4) * 4
            vertexData.weights = stride(from: 0, to: weightCount, by: 4).map { i in
                SIMD4<Float>(weights[i], weights[i + 1], weights[i + 2], weights[i + 3])
            }
            primitive.hasWeights = true
        }

        // Create the single, correctly formatted vertex buffer
        if let device = device {
            let vertices = vertexData.interleaved()
            if !vertices.isEmpty {
                primitive.vertexBuffer = device.makeBuffer(
                    bytes: vertices,
                    length: vertices.count * MemoryLayout<VRMVertex>.stride,
                    options: .storageModeShared
                )
            }
        }

        // Load morph targets (which depend on the vertex buffer being created)
        if let gltfTargets = gltfPrimitive.targets {
            // ... (morph target loading remains the same)
            for (targetIndex, target) in gltfTargets.enumerated() {
                var morphTarget = VRMMorphTarget(name: "target_\(targetIndex)")
                if let positionAccessor = target.position {
                    let deltaPositions = try bufferLoader.loadAccessorAsFloat(positionAccessor)
                    let deltaCount = (deltaPositions.count / 3) * 3
                    morphTarget.positionDeltas = stride(from: 0, to: deltaCount, by: 3).map { i in
                        SIMD3<Float>(
                            deltaPositions[i], deltaPositions[i + 1], deltaPositions[i + 2])
                    }
                }
                if let normalAccessor = target.normal {
                    let deltaNormals = try bufferLoader.loadAccessorAsFloat(normalAccessor)
                    let deltaCount = (deltaNormals.count / 3) * 3
                    morphTarget.normalDeltas = stride(from: 0, to: deltaCount, by: 3).map { i in
                        SIMD3<Float>(deltaNormals[i], deltaNormals[i + 1], deltaNormals[i + 2])
                    }
                }
                primitive.morphTargets.append(morphTarget)
            }
            if !primitive.morphTargets.isEmpty, let device = device {
                primitive.createMorphTargetBuffers(device: device)
            }
        }

        // Load indices (remains the same, creates a new packed buffer)
        if let indicesAccessorIndex = gltfPrimitive.indices {
            let accessor = document.accessors?[safe: indicesAccessorIndex]
            var indices = try bufferLoader.loadAccessorAsUInt32(indicesAccessorIndex)

            primitive.indexCount = indices.count
            primitive.indexBufferOffset = 0  // Always 0 for newly created buffers

            // Rebase indices to 0 if they're out of bounds (fixes wedge artifacts)
            // This handles glTF files where indices are relative to global buffer views
            if !indices.isEmpty && primitive.vertexCount > 0 {
                let maxIndex = indices.max()!
                if maxIndex >= primitive.vertexCount {
                    let minIndex = indices.min()!
                    // Rebase: subtract minIndex so indices start at 0
                    indices = indices.map { $0 - minIndex }
                    let rebasedMax = indices.max()!
                    if rebasedMax >= primitive.vertexCount {
                        fputs(
                            "⚠️ [VRMMetalKit] Index out of bounds after rebasing: maxIndex=\(rebasedMax) >= vertexCount=\(primitive.vertexCount)\n",
                            stderr)
                    }
                }
            }

            if let device = device {
                if accessor?.componentType == 5125 {  // UNSIGNED_INT
                    primitive.indexType = .uint32
                    primitive.indexBuffer = device.makeBuffer(
                        bytes: indices,
                        length: indices.count * MemoryLayout<UInt32>.stride,
                        options: .storageModeShared
                    )
                } else {  // UNSIGNED_SHORT or UNSIGNED_BYTE
                    primitive.indexType = .uint16
                    let uint16Indices = indices.map { UInt16($0) }
                    primitive.indexBuffer = device.makeBuffer(
                        bytes: uint16Indices,
                        length: uint16Indices.count * MemoryLayout<UInt16>.stride,
                        options: .storageModeShared
                    )
                }
            }
        }

        return primitive
    }

    // Create GPU buffers for morph targets
    public func createMorphTargetBuffers(device: MTLDevice) {
        morphPositionBuffers.removeAll()
        morphNormalBuffers.removeAll()
        morphTangentBuffers.removeAll()

        for target in morphTargets {
            // Create position delta buffer
            if let positionDeltas = target.positionDeltas {
                let bufferSize = positionDeltas.count * MemoryLayout<SIMD3<Float>>.stride
                if let buffer = device.makeBuffer(
                    bytes: positionDeltas, length: bufferSize, options: .storageModeShared)
                {
                    morphPositionBuffers.append(buffer)
                }
            }

            // Create normal delta buffer
            if let normalDeltas = target.normalDeltas {
                let bufferSize = normalDeltas.count * MemoryLayout<SIMD3<Float>>.stride
                if let buffer = device.makeBuffer(
                    bytes: normalDeltas, length: bufferSize, options: .storageModeShared)
                {
                    morphNormalBuffers.append(buffer)
                }
            }

            // Create tangent delta buffer
            if let tangentDeltas = target.tangentDeltas {
                let bufferSize = tangentDeltas.count * MemoryLayout<SIMD3<Float>>.stride
                if let buffer = device.makeBuffer(
                    bytes: tangentDeltas, length: bufferSize, options: .storageModeShared)
                {
                    morphTangentBuffers.append(buffer)
                }
            }
        }

        // Create SoA buffers for compute path if we have morph targets
        createSoAMorphBuffers(device: device)
    }

    /// Create Structure-of-Arrays morph buffers for efficient GPU compute
    private func createSoAMorphBuffers(device: MTLDevice) {
        guard !morphTargets.isEmpty, vertexCount > 0 else { return }

        // Create base position buffer from vertex data
        if let vertexBuffer = vertexBuffer {
            // Extract positions from interleaved vertex buffer
            let vertexPointer = vertexBuffer.contents().bindMemory(
                to: VRMVertex.self, capacity: vertexCount)

            // Create base positions buffer
            let basePositionsSize = vertexCount * MemoryLayout<SIMD3<Float>>.stride
            basePositionsBuffer = device.makeBuffer(
                length: basePositionsSize, options: .storageModeShared)

            if let baseBuffer = basePositionsBuffer {
                let basePointer = baseBuffer.contents().bindMemory(
                    to: SIMD3<Float>.self, capacity: vertexCount)
                for i in 0..<vertexCount {
                    basePointer[i] = vertexPointer[i].position
                }
            }

            // Create base normals buffer if we have normals
            if hasNormals {
                let baseNormalsSize = vertexCount * MemoryLayout<SIMD3<Float>>.stride
                baseNormalsBuffer = device.makeBuffer(
                    length: baseNormalsSize, options: .storageModeShared)

                if let normalsBuffer = baseNormalsBuffer {
                    let normalsPointer = normalsBuffer.contents().bindMemory(
                        to: SIMD3<Float>.self, capacity: vertexCount)
                    for i in 0..<vertexCount {
                        normalsPointer[i] = vertexPointer[i].normal
                    }
                }
            }
        }

        // Create SoA morph deltas buffer
        let morphCount = morphTargets.count
        let totalDeltasSize = morphCount * vertexCount * MemoryLayout<SIMD3<Float>>.stride

        // Position deltas SoA
        morphPositionsSoA = device.makeBuffer(length: totalDeltasSize, options: .storageModeShared)
        if let soaBuffer = morphPositionsSoA {
            let soaPointer = soaBuffer.contents().bindMemory(
                to: SIMD3<Float>.self, capacity: morphCount * vertexCount)

            // Copy morph deltas in SoA layout
            for (morphIdx, morphTarget) in morphTargets.enumerated() {
                let baseOffset = morphIdx * vertexCount
                if let deltas = morphTarget.positionDeltas {
                    let deltaCount = min(deltas.count, vertexCount)
                    for vertexIdx in 0..<deltaCount {
                        soaPointer[baseOffset + vertexIdx] = deltas[vertexIdx]
                    }
                    // Fill remaining with zeros if deltas are shorter than vertexCount
                    for vertexIdx in deltaCount..<vertexCount {
                        soaPointer[baseOffset + vertexIdx] = SIMD3<Float>(0, 0, 0)
                    }
                } else {
                    // Fill with zeros if no deltas
                    for vertexIdx in 0..<vertexCount {
                        soaPointer[baseOffset + vertexIdx] = SIMD3<Float>(0, 0, 0)
                    }
                }
            }
        }

        // Normal deltas SoA (if we have normals)
        if hasNormals {
            morphNormalsSoA = device.makeBuffer(
                length: totalDeltasSize, options: .storageModeShared)
            if let soaBuffer = morphNormalsSoA {
                let soaPointer = soaBuffer.contents().bindMemory(
                    to: SIMD3<Float>.self, capacity: morphCount * vertexCount)

                for (morphIdx, morphTarget) in morphTargets.enumerated() {
                    let baseOffset = morphIdx * vertexCount
                    if let deltas = morphTarget.normalDeltas {
                        let deltaCount = min(deltas.count, vertexCount)
                        for vertexIdx in 0..<deltaCount {
                            soaPointer[baseOffset + vertexIdx] = deltas[vertexIdx]
                        }
                        // Fill remaining with zeros if deltas are shorter than vertexCount
                        for vertexIdx in deltaCount..<vertexCount {
                            soaPointer[baseOffset + vertexIdx] = SIMD3<Float>(0, 0, 0)
                        }
                    } else {
                        for vertexIdx in 0..<vertexCount {
                            soaPointer[baseOffset + vertexIdx] = SIMD3<Float>(0, 0, 0)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Iron Dome Sanitization

    /// Sanitizes joint indices to prevent vertex explosions from out-of-bounds bone references.
    ///
    /// This is the "Iron Dome" sanitizer that catches:
    /// - **Sentinel values**: 65535 (0xFFFF) used by some exporters to mean "no bone"
    /// - **Out-of-bounds indices**: Joint indices >= actual bone count
    ///
    /// Both cases are remapped to joint 0 (root bone) with their weight zeroed out.
    ///
    /// - Parameter maxJointIndex: The maximum valid joint index (skin.joints.count - 1)
    /// - Returns: Number of joints that were sanitized
    @discardableResult
    public func sanitizeJoints(maxJointIndex: Int) -> Int {
        guard hasJoints, let vertexBuffer = vertexBuffer, vertexCount > 0 else {
            return 0
        }

        let maxValid = UInt32(maxJointIndex)
        var sanitizedCount = 0

        // Get mutable access to vertex buffer
        let vertexPointer = vertexBuffer.contents().bindMemory(
            to: VRMVertex.self, capacity: vertexCount)

        for i in 0..<vertexCount {
            var vertex = vertexPointer[i]
            var modified = false

            // Check and sanitize each joint index
            // If index is out of bounds or sentinel (65535), remap to joint 0 and zero the weight
            if vertex.joints.x > maxValid || vertex.joints.x == 65535 {
                vertex.joints.x = 0
                vertex.weights.x = 0
                modified = true
                sanitizedCount += 1
            }
            if vertex.joints.y > maxValid || vertex.joints.y == 65535 {
                vertex.joints.y = 0
                vertex.weights.y = 0
                modified = true
                sanitizedCount += 1
            }
            if vertex.joints.z > maxValid || vertex.joints.z == 65535 {
                vertex.joints.z = 0
                vertex.weights.z = 0
                modified = true
                sanitizedCount += 1
            }
            if vertex.joints.w > maxValid || vertex.joints.w == 65535 {
                vertex.joints.w = 0
                vertex.weights.w = 0
                modified = true
                sanitizedCount += 1
            }

            // Renormalize weights if any were zeroed
            if modified {
                let weightSum =
                    vertex.weights.x + vertex.weights.y + vertex.weights.z + vertex.weights.w
                if weightSum > 0.0001 {
                    vertex.weights = vertex.weights / weightSum
                } else {
                    // All weights zeroed - set to 100% root bone
                    vertex.weights = SIMD4<Float>(1, 0, 0, 0)
                }
                vertexPointer[i] = vertex
            }
        }

        // Update requiredPaletteSize after sanitization
        if sanitizedCount > 0 {
            var newMaxJoint: UInt32 = 0
            for i in 0..<vertexCount {
                let joints = vertexPointer[i].joints
                newMaxJoint = max(newMaxJoint, joints.x, joints.y, joints.z, joints.w)
            }
            requiredPaletteSize = Int(newMaxJoint) + 1
        }

        return sanitizedCount
    }
}
