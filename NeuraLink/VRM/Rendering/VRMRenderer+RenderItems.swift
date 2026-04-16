//
//  VRMRenderer+RenderItems.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import Foundation
@preconcurrency import Metal
import simd

// MARK: - Render Item Building

extension VRMRenderer {
    func buildRenderItems(model: VRMModel) -> [RenderItem] {
        // ALPHA MODE QUEUING: Collect all primitives and sort by alpha mode
        // OPTIMIZATION: Pre-allocate single array instead of 8 separate arrays + concatenation
        // Typical models have 20-100 primitives across all meshes
        let estimatedPrimitiveCount = model.meshes.reduce(0) { $0 + $1.primitives.count }
        var allItems: [RenderItem] = []
        allItems.reserveCapacity(estimatedPrimitiveCount)

        var blendCount = 0
        var globalPrimitiveIndex = 0

        // Collect all primitives and categorize by alpha mode
        for (_, node) in model.nodes.enumerated() {
            guard let meshIndex = node.mesh,
                meshIndex < model.meshes.count
            else {
                continue
            }

            let mesh = model.meshes[meshIndex]

            for (primIdxInMesh, primitive) in mesh.primitives.enumerated() {
                let alphaMode =
                    primitive.materialIndex.flatMap { idx in
                        idx < model.materials.count ? model.materials[idx].alphaMode : nil
                    }?.lowercased() ?? "opaque"

                let materialName =
                    (primitive.materialIndex.flatMap { idx in
                        idx < model.materials.count ? model.materials[idx].name : nil
                    }) ?? "unnamed"

                let nodeName = node.name ?? "unnamed"
                let meshName = mesh.name ?? "unnamed_mesh"

                let materialNameLower = materialName.lowercased()
                let nodeNameLower = nodeName.lowercased()
                let meshNameLower = meshName.lowercased()

                // Get original doubleSided and alphaCutoff from material
                let originalDoubleSided =
                    primitive.materialIndex.flatMap { idx in
                        idx < model.materials.count ? model.materials[idx].doubleSided : false
                    } ?? false

                let originalAlphaCutoff =
                    primitive.materialIndex.flatMap { idx in
                        idx < model.materials.count ? model.materials[idx].alphaCutoff : 0.5
                    } ?? 0.5

                // Get renderQueue from VRM material (for sorting face/transparent materials)
                let materialRenderQueue =
                    primitive.materialIndex.flatMap { idx in
                        idx < model.materials.count ? model.materials[idx].renderQueue : 2000
                    } ?? 2000

                // OPTIMIZATION: Single face/body detection pass (consolidates 3 separate checks)
                // Include body, clothing, and transparentZWrite materials for proper categorization
                let isFaceMaterial =
                    materialNameLower.contains("face") || materialNameLower.contains("eye")
                    || nodeNameLower.contains("face") || nodeNameLower.contains("eye")
                    || (materialNameLower.contains("body") && !materialNameLower.contains("face"))
                    || materialNameLower.contains("cloth") || materialNameLower.contains("tops")
                    || materialNameLower.contains("bottoms") || materialNameLower.contains("skirt")
                    || materialNameLower.contains("shorts") || materialNameLower.contains("pants")
                    || materialNameLower.contains("lace") || materialNameLower.contains("collar")
                    || materialNameLower.contains("ribbon") || materialNameLower.contains("frill")
                    || materialNameLower.contains("ruffle")
                let isEyeMaterial =
                    materialNameLower.contains("eye") && !materialNameLower.contains("brow")
                let nodeOrMeshIsFace =
                    nodeNameLower.contains("face") || nodeNameLower.contains("eye")
                    || meshNameLower.contains("face") || meshNameLower.contains("eye")
                var item = RenderItem(
                    node: node,
                    mesh: mesh,
                    primitive: primitive,
                    alphaMode: alphaMode,
                    materialName: materialName,
                    meshIndex: meshIndex,
                    effectiveAlphaMode: alphaMode,  // Start with original
                    effectiveDoubleSided: originalDoubleSided,  // Start with original
                    effectiveAlphaCutoff: originalAlphaCutoff,  // Start with original cutoff
                    faceCategory: nil,  // Will be set if this is a face material
                    materialNameLower: materialNameLower,
                    nodeNameLower: nodeNameLower,
                    meshNameLower: meshNameLower,
                    isFaceMaterial: isFaceMaterial,
                    isEyeMaterial: isEyeMaterial,
                    renderOrder: 0,  // Will be set based on category
                    materialRenderQueue: materialRenderQueue,
                    primitiveIndex: globalPrimitiveIndex,
                    primIdxInMesh: primIdxInMesh
                )

                // Enhanced face/body material detection and overrides
                // OPTIMIZATION: Use pre-computed flags (nodeOrMeshIsFace, isBodyOrSkinMaterial)
                if nodeOrMeshIsFace {
                    // Override double-sided for face materials to ensure visibility
                    item.effectiveDoubleSided = true

                    // For face materials, handle different material types:
                    // - Face skin (OPAQUE or MASK) - main face surface
                    // - Eyelashes/Eyebrows (MASK) - need transparency
                    // - Eyes/Mouth interior (OPAQUE) - solid surfaces

                    if let matIdx = primitive.materialIndex, matIdx < model.materials.count {
                        let material = model.materials[matIdx]

                        // OPTIMIZATION: Use cached lowercased string
                        if item.materialNameLower.contains("skin")
                            && item.effectiveAlphaMode == "mask"
                        {
                            // Use a mid cutoff to respect cutout regions (eyes/mouth)
                            item.effectiveAlphaCutoff = max(0.5, material.alphaCutoff)
                        }
                    }
                }

                // Demote MASK → OPAQUE for body/skin materials.
                // Body textures have alpha=0 padding that would cause holes via MASK discard.
                // Clothing materials (tops, bottoms, shoes) keep MASK for proper cutout.
                let isBodyOrSkinMaterial =
                    materialNameLower.contains("body") || materialNameLower.contains("skin")
                if isBodyOrSkinMaterial && !item.isFaceMaterial && item.effectiveAlphaMode == "mask"
                {
                    item.effectiveAlphaMode = "opaque"
                }

                // OPTIMIZATION: Set renderOrder instead of appending to separate arrays
                if item.isFaceMaterial {
                    // Classify face material by type and set category + renderOrder
                    // Body detection - must come before skin check since body materials contain "skin"
                    if item.materialNameLower.contains("body")
                        && !item.materialNameLower.contains("face")
                    {
                        item.faceCategory = "body"
                        item.renderOrder = 0  // body renders first, pushed back by depth bias
                    } else if item.materialNameLower.contains("lace")
                        || item.materialNameLower.contains("collar")
                        || item.materialNameLower.contains("ribbon")
                        || item.materialNameLower.contains("frill")
                        || item.materialNameLower.contains("ruffle")
                    {
                        // TransparentWithZWrite - semi-transparent overlays that need depth writing
                        item.faceCategory = "transparentZWrite"
                        item.renderOrder = 8  // After opaque, before regular blend
                    } else if item.materialNameLower.contains("cloth")
                        || item.materialNameLower.contains("tops")
                        || item.materialNameLower.contains("bottoms")
                        || item.materialNameLower.contains("skirt")
                        || item.materialNameLower.contains("shorts")
                        || item.materialNameLower.contains("pants")
                    {
                        item.faceCategory = "clothing"
                        item.renderOrder = 8  // Same as transparentZWrite for proper layering
                    } else if item.materialNameLower.contains("mouth")
                        || item.materialNameLower.contains("lip")
                    {
                        // Face mouth/lip overlays - render after base face skin
                        item.faceCategory = "faceOverlay"
                        item.renderOrder = 2  // after skin (1), before eyebrow (2) - same as eyebrow but named differently
                    } else if item.materialNameLower.contains("skin")
                        || (item.materialNameLower.contains("face")
                            && !item.materialNameLower.contains("eye"))
                    {
                        item.faceCategory = "skin"
                        item.renderOrder = 1  // faceSkin - base face renders first
                    } else if item.materialNameLower.contains("brow") {
                        item.faceCategory = "eyebrow"
                        item.renderOrder = 2  // faceEyebrow
                    } else if item.materialNameLower.contains("line")
                        || item.materialNameLower.contains("lash")
                    {
                        item.faceCategory = "eyeline"
                        item.renderOrder = 3  // faceEyeline
                    } else if item.materialNameLower.contains("highlight") {
                        item.faceCategory = "highlight"
                        item.renderOrder = 6  // faceHighlight
                    } else if item.materialNameLower.contains("eye") {
                        item.faceCategory = "eye"
                        item.renderOrder = 5  // faceEye
                    } else {
                        // Unknown face material - default to skin queue
                        item.faceCategory = "skin"
                        item.renderOrder = 1  // faceSkin
                    }

                    // Enforce effective alpha modes per face part for correct pipeline selection
                    switch item.faceCategory {
                    case "eye":
                        // Eyes should be fully opaque geometry rendered after face skin
                        item.effectiveAlphaMode = "opaque"
                        item.effectiveDoubleSided = true
                    case "highlight":
                        // Eye highlights remain blended overlays
                        item.effectiveAlphaMode = "blend"
                        item.effectiveDoubleSided = true
                    case "eyeline", "eyebrow":
                        // Often alpha-cutout; ensure double-sided to avoid missing strokes
                        item.effectiveDoubleSided = true
                    default:
                        break
                    }
                } else {
                    // OPTIMIZATION: Set renderOrder for non-face materials
                    switch item.effectiveAlphaMode {
                    case "opaque":
                        item.renderOrder = 0  // opaque
                    case "mask":
                        item.renderOrder = 4  // mask
                    case "blend":
                        item.renderOrder = 7  // blend
                        blendCount += 1
                    default:
                        item.renderOrder = 0  // opaque (default)
                    }
                }

                // OPTIMIZATION: Add to single pre-allocated array
                allItems.append(item)
                globalPrimitiveIndex += 1
            }
        }

        // Pre-compute view-space Z for transparent items to avoid redundant matrix multiplies in comparator
        var viewZByIndex = [Int: Float]()
        viewZByIndex.reserveCapacity(blendCount)
        for item in allItems where item.materialRenderQueue >= 2500 {
            let worldPos = item.node.worldMatrix.columns.3
            viewZByIndex[item.primitiveIndex] = (viewMatrix * worldPos).z
        }

        // Multi-tier sorting: renderOrder (name-based) + VRM queue + view-Z + stable order
        allItems.sort { a, b in
            // 1. Primary: renderOrder (name-based face/body category ordering)
            // Order: 0=body/opaque, 1=skin, 2=brow, 3=line, 4=mask, 5=eye, 6=highlight, 7=blend, 8=clothing
            if a.renderOrder != b.renderOrder {
                return a.renderOrder < b.renderOrder
            }

            // 2. Secondary: VRM render queue (author's intent for fine-grained ordering)
            // Within same renderOrder, respect explicit queue differences
            if a.materialRenderQueue != b.materialRenderQueue {
                return a.materialRenderQueue < b.materialRenderQueue
            }

            // 3. Tertiary: Transparent materials (queue >= 2500): back-to-front Z-sorting
            // This threshold covers TransparentWithZWrite (2450+) and Transparent (3000+)
            if a.materialRenderQueue >= 2500 {
                let aViewZ = viewZByIndex[a.primitiveIndex] ?? 0
                let bViewZ = viewZByIndex[b.primitiveIndex] ?? 0
                return aViewZ < bViewZ  // Far to near (Painter's Algorithm)
            }

            // 4. Quaternary: stable definition order for tie-breaking
            return a.primitiveIndex < b.primitiveIndex
        }

        return allItems
    }
}
