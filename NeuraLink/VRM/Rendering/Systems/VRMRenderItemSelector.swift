//
//  VRMRenderItemSelector.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import Foundation
import Metal

struct RenderSelectionInput {
    let items: [RenderItem]
    let frameCounter: Int
    let debugSingleMesh: Bool
    let renderFilter: RenderFilter?
}

final class VRMRenderItemSelector {
    func selectItems(_ input: RenderSelectionInput) -> [RenderItem] {
        var items = input.items

        vrmLog(
            "[WORKAROUND PATH] debugSingleMesh = \(input.debugSingleMesh), allItems.count = \(items.count)"
        )

        if input.debugSingleMesh {
            if let firstItem = items.first {
                items = [firstItem]
                vrmLog(
                    "[DEBUG] 🔧 Debug single-mesh mode: rendering only '\(firstItem.materialName)' from mesh '\(firstItem.mesh.name ?? "unnamed")'"
                )
            } else {
                items = []
                vrmLog("[DEBUG] 🔧 Debug single-mesh mode: no items to render")
            }
        }

        vrmLog("[WORKAROUND LOOP] Starting render loop with \(items.count) items")
        vrmLog("[LOOP DEBUG] About to iterate over \(items.count) items")

        guard let filter = input.renderFilter else {
            return items
        }

        return items.enumerated().compactMap { index, item in
            let meshName = item.mesh.name ?? "unnamed"
            let materialName = item.materialName
            vrmLog("[RENDER CHECK] Item \(index): mesh='\(meshName)', material='\(materialName)')")

            let meshPrimIndex =
                item.mesh.primitives.firstIndex(where: { $0 === item.primitive }) ?? -1

            let shouldRender: Bool
            switch filter {
            case .mesh(let name):
                shouldRender = meshName == name
            case .material(let name):
                shouldRender = materialName == name
            case .primitive(let primIndex):
                shouldRender = meshPrimIndex == primIndex
            }

            guard shouldRender else { return nil }

            if input.frameCounter == 1 {
                logFilterDetails(item: item, meshName: meshName, meshPrimIndex: meshPrimIndex)
            }

            return item
        }
    }

    private func logFilterDetails(item: RenderItem, meshName: String, meshPrimIndex: Int) {
        let prim = item.primitive
        vrmLog("\n━━━━━ FILTERED PRIMITIVE DETAILS ━━━━━")
        vrmLog("Mesh: '\(meshName)'")
        vrmLog("Material: '\(item.materialName)'")
        vrmLog("Primitive index: \(meshPrimIndex)")
        vrmLog("")

        let modeStr: String
        switch prim.primitiveType {
        case .point: modeStr = "POINTS (0)"
        case .line: modeStr = "LINES (1)"
        case .lineStrip: modeStr = "LINE_STRIP (2)"
        case .triangle: modeStr = "TRIANGLES (4)"
        case .triangleStrip: modeStr = "TRIANGLE_STRIP (5)"
        @unknown default: modeStr = "UNKNOWN"
        }
        vrmLog("Mode (glTF → Metal): \(modeStr) → \(prim.primitiveType)")

        let indexTypeStr = prim.indexType == .uint16 ? "uint16" : "uint32"
        let indexElemSize = prim.indexType == .uint16 ? 2 : 4
        vrmLog("Index type: \(indexTypeStr)")
        vrmLog("Index count: \(prim.indexCount)")
        vrmLog("Index buffer offset: \(prim.indexBufferOffset) bytes")

        if let indexBuffer = prim.indexBuffer {
            vrmLog("Index buffer length: \(indexBuffer.length) bytes")

            // Validate alignment - log error instead of crashing
            if prim.indexBufferOffset % indexElemSize != 0 {
                vrmLog(
                    "❌ Index buffer offset \(prim.indexBufferOffset) not aligned to element size \(indexElemSize)"
                )
                return  // Exit diagnostic function
            }

            // Validate buffer size - log error instead of crashing
            if prim.indexBufferOffset + prim.indexCount * indexElemSize > indexBuffer.length {
                vrmLog(
                    "❌ Index buffer overflow: offset(\(prim.indexBufferOffset)) + count(\(prim.indexCount)) * elemSize(\(indexElemSize)) > buffer.length(\(indexBuffer.length))"
                )
                return  // Exit diagnostic function
            }

            vrmLog("\nFirst 24 indices:")
            let indicesToRead = min(24, prim.indexCount)
            var indicesStr: [String] = []
            var maxIndex = 0

            if prim.indexType == .uint16 {
                let base = indexBuffer.contents().advanced(by: prim.indexBufferOffset)
                let indexPtr = base.bindMemory(to: UInt16.self, capacity: prim.indexCount)
                for i in 0..<indicesToRead {
                    let idx = Int(indexPtr[i])
                    indicesStr.append("\(idx)")
                    maxIndex = max(maxIndex, idx)
                }
            } else {
                let base = indexBuffer.contents().advanced(by: prim.indexBufferOffset)
                let indexPtr = base.bindMemory(to: UInt32.self, capacity: prim.indexCount)
                for i in 0..<indicesToRead {
                    let idx = Int(indexPtr[i])
                    indicesStr.append("\(idx)")
                    maxIndex = max(maxIndex, idx)
                }
            }
            vrmLog("  [\(indicesStr.joined(separator: ", "))]")
            vrmLog("  Max index in sample: \(maxIndex)")

            vrmLog("\nPOSITION.count (vertexCount): \(prim.vertexCount)")
            // Validate vertex count - log error instead of crashing
            if maxIndex >= prim.vertexCount {
                vrmLog("❌ Max index \(maxIndex) >= vertex count \(prim.vertexCount)")
                return  // Exit diagnostic function
            }

            vrmLog("\n✅ All validations pass for primitive \(meshPrimIndex)")
        }
    }
}
