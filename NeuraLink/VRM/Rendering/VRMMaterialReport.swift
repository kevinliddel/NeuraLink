//
//  VRMMaterialReport.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import Foundation
import Metal

/// Report containing material information for debugging and diagnostics.
public struct MaterialReport: Codable {
    public let modelName: String
    public let materials: [MaterialInfo]
    public let summary: Summary

    public struct MaterialInfo: Codable {
        public let index: Int
        public let name: String
        public let alphaMode: String
        public let alphaCutoff: Float
        public let baseColorFactor: [Float]
        public let hasBaseTexture: Bool
        public let textureSize: [Int]?
        public let doubleSided: Bool
        public let mtoonShadeColor: [Float]?
        public let hasAlphaIssue: Bool
    }

    public struct Summary: Codable {
        public let totalMaterials: Int
        public let opaqueCount: Int
        public let maskCount: Int
        public let blendCount: Int
        public let suspiciousAlphaCount: Int
    }
}

// MARK: - VRMRenderer Material Report Generation

extension VRMRenderer {
    /// Generates a diagnostic report of all materials in the loaded model.
    public func generateMaterialReport() -> MaterialReport? {
        guard let model = model else {
            vrmLog("[VRMRenderer] No model loaded for material report")
            return nil
        }

        var materialInfos: [MaterialReport.MaterialInfo] = []
        var opaqueCount = 0
        var maskCount = 0
        var blendCount = 0
        var suspiciousAlphaCount = 0

        for (index, material) in model.materials.enumerated() {
            // Count alpha modes
            switch material.alphaMode.lowercased() {
            case "opaque":
                opaqueCount += 1
            case "mask":
                maskCount += 1
            case "blend":
                blendCount += 1
            default:
                opaqueCount += 1
            }

            // Check for suspicious alpha values
            let hasAlphaIssue =
                material.baseColorFactor.w < 0.01
                || (material.alphaMode.lowercased() == "opaque" && material.baseColorFactor.w < 1.0)
            if hasAlphaIssue {
                suspiciousAlphaCount += 1
            }

            // Get texture size if available
            var textureSize: [Int]? = nil
            if let baseTexture = material.baseColorTexture,
                let mtlTexture = baseTexture.mtlTexture
            {
                textureSize = [mtlTexture.width, mtlTexture.height]
            }

            // Get MToon shade color if available
            var mtoonShadeColor: [Float]? = nil
            if let mtoon = material.mtoon {
                mtoonShadeColor = [
                    mtoon.shadeColorFactor.x,
                    mtoon.shadeColorFactor.y,
                    mtoon.shadeColorFactor.z,
                ]
            }

            let info = MaterialReport.MaterialInfo(
                index: index,
                name: material.name ?? "Material_\(index)",
                alphaMode: material.alphaMode,
                alphaCutoff: material.alphaCutoff,
                baseColorFactor: [
                    material.baseColorFactor.x,
                    material.baseColorFactor.y,
                    material.baseColorFactor.z,
                    material.baseColorFactor.w,
                ],
                hasBaseTexture: material.baseColorTexture != nil,
                textureSize: textureSize,
                doubleSided: material.doubleSided,
                mtoonShadeColor: mtoonShadeColor,
                hasAlphaIssue: hasAlphaIssue
            )

            materialInfos.append(info)
        }

        let summary = MaterialReport.Summary(
            totalMaterials: model.materials.count,
            opaqueCount: opaqueCount,
            maskCount: maskCount,
            blendCount: blendCount,
            suspiciousAlphaCount: suspiciousAlphaCount
        )

        return MaterialReport(
            modelName: "VRM Model",
            materials: materialInfos,
            summary: summary
        )
    }
}
