//
//  VRMRenderItemBuilder.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import Foundation
import Metal

struct RenderItem {
    let node: VRMNode
    let mesh: VRMMesh
    let primitive: VRMPrimitive
    let alphaMode: String
    let materialName: String
    let meshIndex: Int
    var effectiveAlphaMode: String
    var effectiveDoubleSided: Bool
    var effectiveAlphaCutoff: Float
    var faceCategory: String?
    let materialNameLower: String
    let nodeNameLower: String
    let meshNameLower: String
    let isFaceMaterial: Bool
    let isEyeMaterial: Bool
    var renderOrder: Int
    // VRM material renderQueue for primary sorting (computed from base + offset)
    // OPAQUE base=2000, MASK base=2450, BLEND base=3000
    let materialRenderQueue: Int
    // Whether this material should write to depth buffer (from VRM transparentWithZWrite)
    let depthWriteEnabled: Bool
    // Render queue offset for fine-grained sorting within a category
    let renderQueueOffset: Int
    // Scene graph order for stable tie-breaking in sort (global across all meshes)
    let primitiveIndex: Int
    // Per-mesh primitive index for morph buffer lookup (matches compute pass key)
    let primIdxInMesh: Int
}

final class VRMRenderItemBuilder {
    struct Result {
        let items: [RenderItem]
        let totalMeshesWithNodes: Int
    }

    private var cachedRenderItems: [RenderItem]?
    private var cachedTotalMeshes: Int = 0
    private var cacheInvalidated = true

    func invalidateCache() {
        cacheInvalidated = true
    }

    func buildItems(model: VRMModel, frameCounter: Int) -> Result {
        if let cached = cachedRenderItems, !cacheInvalidated {
            if frameCounter % 300 == 0 {
                vrmLog("[RenderItemBuilder] Using cached render items (")
            }
            return Result(items: cached, totalMeshesWithNodes: cachedTotalMeshes)
        }

        if frameCounter % 60 == 0 {
            vrmLog("[RenderItemBuilder] Rebuilding render items...")
        }

        var totalMeshes = 0
        let estimatedPrimCount = model.meshes.reduce(0) { $0 + $1.primitives.count }
        var allItems: [RenderItem] = []
        allItems.reserveCapacity(estimatedPrimCount)

        var opaqueCount = 0
        var maskCount = 0
        var blendCount = 0
        var faceSkinCount = 0
        var faceEyebrowCount = 0
        var faceEyelineCount = 0
        var faceEyeCount = 0
        var faceHighlightCount = 0
        var globalPrimitiveIndex = 0

        for (nodeIndex, node) in model.nodes.enumerated() {
            if frameCounter <= 2 {
                vrmLog(
                    "[NODE SCAN] Node \(nodeIndex) '\(node.name ?? "unnamed")': mesh=\(node.mesh ?? -1)"
                )
            }

            guard let meshIndex = node.mesh,
                meshIndex < model.meshes.count
            else {
                continue
            }

            let mesh = model.meshes[meshIndex]
            if frameCounter <= 2 {
                vrmLog(
                    "[DRAW LIST] Node[\(nodeIndex)] '\(node.name ?? "?")' → mesh[\(meshIndex)] '\(mesh.name ?? "?")' skin=\(node.skin ?? -1)"
                )
            }
            totalMeshes += 1

            for (primIdxInMesh, primitive) in mesh.primitives.enumerated() {
                // Get material reference for property-based detection
                let material: VRMMaterial? = primitive.materialIndex.flatMap { idx in
                    idx < model.materials.count ? model.materials[idx] : nil
                }

                let alpha = material?.alphaMode.lowercased() ?? "opaque"
                let materialName = material?.name ?? "unnamed"

                let nodeName = node.name ?? "unnamed"
                let meshName = mesh.name ?? "unnamed_mesh"
                let materialLower = materialName.lowercased()
                let nodeLower = nodeName.lowercased()
                let meshLower = meshName.lowercased()

                let nodeIsFace = nodeLower.contains("face") || nodeLower.contains("eye")
                let meshIsFace = meshLower.contains("face") || meshLower.contains("eye")
                let materialIsFace = materialLower.contains("face") || materialLower.contains("eye")

                if nodeIsFace || meshIsFace || materialIsFace {
                    logFaceCandidate(
                        nodeName: nodeName, meshName: meshName, materialName: materialName,
                        alpha: alpha, primitive: primitive, material: material)
                }

                // Property-based detection using VRM material properties
                let isTransparentWithZWrite = material?.isTransparentWithZWrite ?? false
                let materialRenderQueueOffset = material?.renderQueueOffset ?? 0
                let depthWriteEnabled = material?.zWriteEnabled ?? true

                var faceCategory: String?
                var renderOrder = 0

                // PRIORITY 1: Property-based transparentWithZWrite detection (most reliable)
                if isTransparentWithZWrite {
                    faceCategory = "transparentZWrite"
                    // TransparentZWrite: 10 + offset (renders before regular transparent at 19+)
                    renderOrder = 10 + materialRenderQueueOffset
                }
                // PRIORITY 2: Name-based body material detection
                else if materialLower.contains("body_skin")
                    || (materialLower.contains("body") && !materialLower.contains("face")) {
                    faceCategory = "body"
                    renderOrder = 0  // Render first
                }
                // PRIORITY 3: Name-based face material detection
                else if materialLower.contains("face_skin") || materialLower.contains("facebase")
                    || (materialLower.contains("face") && materialLower.contains("skin")) {
                    faceCategory = "skin"
                    renderOrder = 1
                    faceSkinCount += 1
                } else if materialLower.contains("eyebrow") || materialLower.contains("brow") {
                    faceCategory = "eyebrow"
                    renderOrder = 2
                    faceEyebrowCount += 1
                } else if materialLower.contains("eyeline") || materialLower.contains("eyeliner") {
                    faceCategory = "eyeline"
                    renderOrder = 3
                    faceEyelineCount += 1
                } else if materialLower.contains("eyelash") || materialLower.contains("lash") {
                    faceCategory = "eyelash"
                    renderOrder = 3  // Same as eyeline, render after eyebrows
                    faceEyelineCount += 1  // Reuse counter
                } else if materialLower.contains("highlight")
                    || materialLower.contains("catchlight") {
                    faceCategory = "highlight"
                    renderOrder = 6
                    faceHighlightCount += 1
                } else if materialLower.contains("eye") {
                    faceCategory = "eye"
                    renderOrder = 5
                    faceEyeCount += 1
                } else if materialLower.contains("mouth") || materialLower.contains("lip") {
                    // Mouth/lip materials on face mesh - render AFTER base face skin
                    faceCategory = "faceOverlay"
                    renderOrder = 2  // After base skin (1), same as eyebrow
                    faceSkinCount += 1
                } else if materialLower.contains("face") {
                    // Catch-all for any other face-related materials ( FaceMouth, FaceBase, etc.)
                    // These should be treated as skin layer to prevent Z-fighting
                    faceCategory = "skin"
                    renderOrder = 1
                    faceSkinCount += 1
                }
                // PRIORITY 4: Name-based clothing detection (fallback)
                else if materialLower.contains("cloth") || materialLower.contains("tops")
                    || materialLower.contains("bottoms") || materialLower.contains("skirt")
                    || materialLower.contains("shorts") || materialLower.contains("pants") {
                    faceCategory = "clothing"
                    renderOrder = 8
                }
                // PRIORITY 5: Alpha mode based ordering
                else {
                    switch alpha {
                    case "opaque":
                        renderOrder = 0
                        opaqueCount += 1
                    case "mask":
                        renderOrder = 4
                        maskCount += 1
                    case "blend":
                        // Regular transparent: 19 + offset (renders last)
                        renderOrder = 19 + materialRenderQueueOffset
                        blendCount += 1
                    default:
                        renderOrder = 19 + materialRenderQueueOffset
                        blendCount += 1
                    }
                }

                var effectiveDoubleSided =
                    primitive.materialIndex.flatMap { idx in
                        idx < model.materials.count ? model.materials[idx].doubleSided : nil
                    } ?? false
                if faceCategory != nil {
                    effectiveDoubleSided = true
                }

                var effectiveAlphaMode = alpha
                var effectiveAlphaCutoff =
                    primitive.materialIndex.flatMap { idx in
                        idx < model.materials.count ? model.materials[idx].alphaCutoff : nil
                    } ?? 0.5
                if effectiveAlphaMode == "opaque"
                    && (faceCategory == "eyebrow" || faceCategory == "eyelash") {
                    vrmLog(
                        "[FACE FIX] Forcing \(faceCategory!) material '\(materialName)' to MASK mode"
                    )
                    effectiveAlphaMode = "mask"
                    effectiveAlphaCutoff = 0.35
                }
                if faceCategory == "highlight" {
                    effectiveAlphaMode = "blend"
                }

                let isFaceMaterial = faceCategory != nil
                let isEyeMaterial = faceCategory == "eye" || faceCategory == "highlight"

                // Get renderQueue from VRM material (for sorting face/transparent materials)
                let materialRenderQueue =
                    primitive.materialIndex.flatMap { idx in
                        idx < model.materials.count ? model.materials[idx].renderQueue : 2000
                    } ?? 2000

                let item = RenderItem(
                    node: node,
                    mesh: mesh,
                    primitive: primitive,
                    alphaMode: alpha,
                    materialName: materialName,
                    meshIndex: meshIndex,
                    effectiveAlphaMode: effectiveAlphaMode,
                    effectiveDoubleSided: effectiveDoubleSided,
                    effectiveAlphaCutoff: effectiveAlphaCutoff,
                    faceCategory: faceCategory,
                    materialNameLower: materialLower,
                    nodeNameLower: nodeLower,
                    meshNameLower: meshLower,
                    isFaceMaterial: isFaceMaterial,
                    isEyeMaterial: isEyeMaterial,
                    renderOrder: renderOrder,
                    materialRenderQueue: materialRenderQueue,
                    depthWriteEnabled: depthWriteEnabled,
                    renderQueueOffset: materialRenderQueueOffset,
                    primitiveIndex: globalPrimitiveIndex,
                    primIdxInMesh: primIdxInMesh
                )

                allItems.append(item)
                globalPrimitiveIndex += 1
            }
        }

        // Multi-tier sorting: renderOrder (name-based) + VRM queue + stable order
        // Note: View-Z sorting for transparencies is done at render time with view matrix
        allItems.sort { a, b in
            // Primary: renderOrder (name-based face/body category ordering)
            if a.renderOrder != b.renderOrder {
                return a.renderOrder < b.renderOrder
            }
            // Secondary: VRM render queue (author's intent for fine-grained ordering)
            if a.materialRenderQueue != b.materialRenderQueue {
                return a.materialRenderQueue < b.materialRenderQueue
            }
            // Tertiary: stable definition order for tie-breaking
            return a.primitiveIndex < b.primitiveIndex
        }

        if frameCounter % 60 == 0 {
            vrmLog(
                "[RenderItemBuilder] Sorted render items: opaque=\(opaqueCount) mask=\(maskCount) blend=\(blendCount) faceSkin=\(faceSkinCount)"
            )
        }

        // One-time diagnostic log for all materials
        if frameCounter == 0 {
            vrmLog("[MATERIAL DIAGNOSTIC] All materials in model:")
            for item in allItems {
                vrmLog(
                    "  - '\(item.materialName)' alpha=\(item.alphaMode) effective=\(item.effectiveAlphaMode) category=\(item.faceCategory ?? "none")"
                )
            }
        }

        cachedRenderItems = allItems
        cachedTotalMeshes = totalMeshes
        cacheInvalidated = false

        return Result(items: allItems, totalMeshesWithNodes: totalMeshes)
    }

    private func logFaceCandidate(
        nodeName: String, meshName: String, materialName: String, alpha: String,
        primitive: VRMPrimitive, material: VRMMaterial?
    ) {
        vrmLog("[FACE MATERIAL DEBUG] Potential face material detected:")
        vrmLog("  - Node: '\(nodeName)'")
        vrmLog("  - Mesh: '\(meshName)'")
        vrmLog("  - Material: '\(materialName)'")
        vrmLog("  - Alpha mode: \(alpha)")
        vrmLog("  - IndexCount: \(primitive.indexCount)")
        if let mat = material {
            vrmLog("  - VRM Properties:")
            vrmLog("    - transparentWithZWrite: \(mat.transparentWithZWrite)")
            vrmLog("    - zWriteEnabled: \(mat.zWriteEnabled)")
            vrmLog("    - blendMode: \(mat.blendMode)")
            vrmLog("    - isTransparentWithZWrite: \(mat.isTransparentWithZWrite)")
            vrmLog("    - renderQueue: \(mat.renderQueue)")
            vrmLog("    - renderQueueOffset: \(mat.renderQueueOffset)")
        }
    }
}
