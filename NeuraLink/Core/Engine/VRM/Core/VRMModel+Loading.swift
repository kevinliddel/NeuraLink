//
// VRMModel+Loading.swift
// NeuraLink
//
// Created by Dedicatus on 14/04/2026.
//

import Foundation
import Metal
import simd

extension VRMModel {

    func loadResources(
        binaryData: Data? = nil,
        context: VRMLoadingContext? = nil
    ) async throws {
        let useBufferPreloading = context?.options.optimizations.contains(.preloadBuffers) ?? false

        // === Loading Phase: Buffer Preloading ===
        var preloadedBuffers: [Int: Data]?
        if useBufferPreloading {
            await context?.updatePhase(.preloadingBuffers, progress: 0)

            let preloader = BufferPreloader(document: gltf, baseURL: baseURL)
            preloadedBuffers = await preloader.preloadAllBuffers(binaryData: binaryData)

            await context?.updatePhase(.preloadingBuffers, progress: 1.0)
        }

        let bufferLoader = BufferLoader(
            document: gltf,
            binaryData: binaryData,
            baseURL: baseURL,
            preloadedData: preloadedBuffers
        )

        // Identify which textures are used as normal maps (need linear format, not sRGB)
        var normalMapTextureIndices = Set<Int>()
        for (_, material) in (gltf.materials ?? []).enumerated() {
            if let normalTexture = material.normalTexture {
                normalMapTextureIndices.insert(normalTexture.index)
            }
        }

        // === Loading Phase: Textures ===
        let textureCount = gltf.textures?.count ?? 0
        await context?.updatePhase(.loadingTextures, totalItems: textureCount)

        if let device = device {
            let useParallelLoading =
                context?.options.optimizations.contains(.parallelTextureLoading) ?? false

            if useParallelLoading && textureCount > 1 {
                // Use parallel texture loader for better performance
                let parallelLoader = ParallelTextureLoader(
                    device: device,
                    bufferLoader: bufferLoader,
                    document: gltf,
                    baseURL: baseURL,
                    maxConcurrentLoads: min(4, textureCount)
                )

                let indices = Array(0..<textureCount)
                let loadedTextures = await parallelLoader.loadTexturesParallel(
                    indices: indices,
                    normalMapIndices: normalMapTextureIndices
                ) { completed, total in
                    Task {
                        await context?.updateProgress(
                            itemsCompleted: completed,
                            totalItems: total
                        )
                    }
                }

                // Build textures array in order
                for textureIndex in 0..<textureCount {
                    let textureName =
                        gltf.textures?[safe: textureIndex]?.name ?? "texture_\(textureIndex)"
                    if let mtlTexture = loadedTextures[textureIndex] {
                        let vrmTexture = VRMTexture(name: textureName)
                        vrmTexture.mtlTexture = mtlTexture
                        textures.append(vrmTexture)
                    } else {
                        textures.append(VRMTexture(name: textureName))
                    }
                }
            } else {
                // Sequential loading (original implementation)
                let textureLoader = TextureLoader(
                    device: device, bufferLoader: bufferLoader, document: gltf, baseURL: baseURL)
                for textureIndex in 0..<textureCount {
                    try await context?.checkCancellation()
                    await context?.updateProgress(
                        itemsCompleted: textureIndex,
                        totalItems: textureCount
                    )

                    let isNormalMap = normalMapTextureIndices.contains(textureIndex)
                    let useSRGB = !isNormalMap
                    let textureName =
                        gltf.textures?[safe: textureIndex]?.name ?? "texture_\(textureIndex)"

                    if let mtlTexture = try await textureLoader.loadTexture(
                        at: textureIndex, sRGB: useSRGB) {
                        let vrmTexture = VRMTexture(name: textureName)
                        vrmTexture.mtlTexture = mtlTexture
                        textures.append(vrmTexture)
                    } else {
                        textures.append(VRMTexture(name: textureName))
                    }
                }
            }
        } else {
            // No device, create empty texture placeholders
            for textureIndex in 0..<textureCount {
                let textureName = gltf.textures?[safe: textureIndex]?.name
                textures.append(VRMTexture(name: textureName))
            }
        }

        // === Loading Phase: Materials ===
        let materialCount = gltf.materials?.count ?? 0
        await context?.updatePhase(.loadingMaterials, totalItems: materialCount)

        let useParallelMaterials =
            context?.options.optimizations.contains(.parallelMaterialLoading) ?? false

        if useParallelMaterials && materialCount > 1 {
            // Use parallel material loading
            let parallelLoader = ParallelMaterialLoader(
                document: gltf,
                textures: textures,
                vrm0MaterialProperties: vrm0MaterialProperties,
                vrmVersion: specVersion
            )

            let indices = Array(0..<materialCount)
            let loadedMaterials = await parallelLoader.loadMaterialsParallel(
                indices: indices
            ) { completed, total in
                Task {
                    await context?.updateProgress(
                        itemsCompleted: completed,
                        totalItems: total
                    )
                }
            }

            // Build materials array in order
            for materialIndex in 0..<materialCount {
                if let material = loadedMaterials[materialIndex] {
                    materials.append(material)
                }
            }
        } else {
            // Sequential loading
            for materialIndex in 0..<materialCount {
                try await context?.checkCancellation()
                await context?.updateProgress(
                    itemsCompleted: materialIndex, totalItems: materialCount)

                if let gltfMaterial = gltf.materials?[safe: materialIndex] {
                    let vrm0Prop =
                        materialIndex < vrm0MaterialProperties.count
                        ? vrm0MaterialProperties[materialIndex] : nil
                    let material = VRMMaterial(
                        from: gltfMaterial, textures: textures, vrm0MaterialProperty: vrm0Prop,
                        vrmVersion: specVersion)
                    materials.append(material)
                }
            }
        }

        // === Loading Phase: Meshes ===
        let meshCount = gltf.meshes?.count ?? 0
        await context?.updatePhase(.loadingMeshes, totalItems: meshCount)

        let useParallelMeshLoading =
            context?.options.optimizations.contains(.parallelMeshLoading) ?? false

        if useParallelMeshLoading && meshCount > 1 {
            // Use parallel mesh loading for better performance
            let parallelLoader = ParallelMeshLoader(
                device: device,
                document: gltf,
                bufferLoader: bufferLoader
            )

            let indices = Array(0..<meshCount)
            let loadedMeshes = await parallelLoader.loadMeshesParallel(
                indices: indices
            ) { completed, total in
                Task {
                    await context?.updateProgress(
                        itemsCompleted: completed,
                        totalItems: total
                    )
                }
            }

            // Build meshes array in order
            for meshIndex in 0..<meshCount {
                if let mesh = loadedMeshes[meshIndex] {
                    meshes.append(mesh)
                }
            }
        } else {
            // Sequential loading
            for meshIndex in 0..<meshCount {
                try await context?.checkCancellation()
                await context?.updateProgress(itemsCompleted: meshIndex, totalItems: meshCount)

                if let gltfMesh = gltf.meshes?[safe: meshIndex] {
                    let mesh = try await VRMMesh.load(
                        from: gltfMesh, document: gltf, device: device, bufferLoader: bufferLoader)
                    meshes.append(mesh)
                }
            }
        }

        // === Loading Phase: Hierarchy ===
        await context?.updatePhase(.buildingHierarchy, progress: 0)
        try await context?.checkCancellation()
        buildNodeHierarchy()
        await context?.updatePhase(.buildingHierarchy, progress: 1.0)

        // === Loading Phase: Skins ===
        let skinCount = gltf.skins?.count ?? 0
        await context?.updatePhase(.loadingSkins, totalItems: skinCount)

        for skinIndex in 0..<skinCount {
            try await context?.checkCancellation()
            await context?.updateProgress(itemsCompleted: skinIndex, totalItems: skinCount)

            if let gltfSkin = gltf.skins?[skinIndex] {
                let skin = try VRMSkin(
                    from: gltfSkin, nodes: nodes, document: gltf, bufferLoader: bufferLoader)
                skins.append(skin)
            }
        }

        // IRON DOME: Sanitize joint indices
        await context?.updatePhase(.sanitizingJoints, progress: 0.5)
        sanitizeAllMeshJoints()
        await context?.updatePhase(.sanitizingJoints, progress: 1.0)
    }

    /// "Iron Dome" joint sanitization - ensures all mesh joint indices are within valid bounds.
    ///
    /// This is called after skins are loaded, when we know the actual bone count for each skin.
    /// It iterates through all node->mesh->skin associations and sanitizes any out-of-bounds
    /// joint indices, preventing vertex explosions from sentinel values (65535) or
    /// indices that exceed the skeleton size.
    func sanitizeAllMeshJoints() {
        guard !skins.isEmpty else { return }

        // Iterate through nodes that have both mesh and skin
        for node in nodes {
            guard let meshIndex = node.mesh,
                meshIndex < meshes.count,
                let skinIndex = node.skin,
                skinIndex < skins.count
            else {
                continue
            }

            let mesh = meshes[meshIndex]
            let skin = skins[skinIndex]
            let maxJointIndex = skin.joints.count - 1

            guard maxJointIndex >= 0 else { continue }

            // Sanitize each primitive in the mesh
            for primitive in mesh.primitives {
                _ = primitive.sanitizeJoints(maxJointIndex: maxJointIndex)
            }
        }
    }

    func buildNodeHierarchy() {
        guard let gltfNodes = gltf.nodes else { return }

        // Create all nodes
        for (index, gltfNode) in gltfNodes.enumerated() {
            let node = VRMNode(index: index, gltfNode: gltfNode)
            nodes.append(node)
        }

        // Build parent-child relationships with validation
        for (index, gltfNode) in gltfNodes.enumerated() {
            if let childIndices = gltfNode.children {
                for childIndex in childIndices {
                    if childIndex < nodes.count {
                        let childNode = nodes[childIndex]

                        // Validation: Prevent multiple parents (graph cycles/dag)
                        if childNode.parent != nil {
                            continue
                        }

                        // Validation: Prevent duplicate children
                        if nodes[index].children.contains(where: { $0 === childNode }) {
                            continue
                        }

                        childNode.parent = nodes[index]
                        nodes[index].children.append(childNode)
                    }
                }
            }
        }

        // Calculate initial transforms
        for node in nodes {
            node.updateWorldTransform()
        }

        // PERFORMANCE: Build normalized name lookup table for fast animation lookups
        buildNodeLookupTable()
    }

    func buildNodeLookupTable() {
        nodeLookupTable.removeAll()
        for node in nodes {
            guard let name = node.name else { continue }

            // Normalize name the same way AnimationPlayer does
            let normalizedName = name.lowercased()
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: ".", with: "")

            nodeLookupTable[normalizedName] = node
        }
    }
}
