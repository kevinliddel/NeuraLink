//
// VRMModel+Serialization.swift
// NeuraLink
//
// Created by Dedicatus on 15/04/2026.
//

import Foundation

/// Extension for serializing VRM models to .vrm files
extension VRMModel {

    /// Serialize the VRM model to a .vrm file
    ///
    /// VRM files are glTF 2.0 GLB files with VRM extensions
    /// Format: GLB binary format with JSON + binary data
    ///
    /// - Parameter url: The file URL to write to
    public func serialize(to url: URL) throws {
        vrmLog("[VRMModel] Serializing VRM to: \(url.path)")

        // Build the complete glTF/VRM JSON
        let vrmJSON = try buildVRMJSON()

        // Get binary buffer data from glTF document
        let binaryData = gltf.binaryBufferData ?? Data()

        // Create GLB file with JSON + binary data
        let glbData = try createGLB(json: vrmJSON, binaryData: binaryData)

        // Write to file
        try glbData.write(to: url)

        vrmLog(
            "[VRMModel] VRM file written successfully: \(glbData.count) bytes (\(binaryData.count) bytes binary data)"
        )
    }

    /// Serialize the VRM model to Data (GLB format)
    ///
    /// VRM files are glTF 2.0 GLB files with VRM extensions
    /// Format: GLB binary format with JSON + binary data
    ///
    /// - Returns: GLB-formatted Data
    public func serialize() throws -> Data {
        // Build the complete glTF/VRM JSON
        let vrmJSON = try buildVRMJSON()

        // Get binary buffer data from glTF document
        let binaryData = gltf.binaryBufferData ?? Data()

        // Create GLB file with JSON + binary data
        let glbData = try createGLB(json: vrmJSON, binaryData: binaryData)

        return glbData
    }

    // MARK: - Private Methods

    private func buildVRMJSON() throws -> [String: Any] {
        // Start with glTF document
        let gltfData = try JSONEncoder().encode(gltf)
        var gltfDict = try JSONSerialization.jsonObject(with: gltfData) as! [String: Any]

        // Add VRM extension
        var extensions = gltfDict["extensions"] as? [String: Any] ?? [:]

        // Build VRMC_vrm extension
        var vrmcVrm: [String: Any] = [
            "specVersion": specVersion.rawValue
        ]

        // Add meta
        vrmcVrm["meta"] = buildMetaDict()

        // Add humanoid
        if let humanoid = humanoid {
            vrmcVrm["humanoid"] = buildHumanoidDict(humanoid)
        }

        // Add expressions
        if let expressions = expressions {
            vrmcVrm["expressions"] = buildExpressionsDict(expressions)
        }

        // Add lookAt
        if let lookAt = lookAt {
            vrmcVrm["lookAt"] = buildLookAtDict(lookAt)
        }

        // Add firstPerson
        if let firstPerson = firstPerson {
            vrmcVrm["firstPerson"] = buildFirstPersonDict(firstPerson)
        }

        extensions["VRMC_vrm"] = vrmcVrm

        // Add SpringBone if present
        if let springBone = springBone {
            extensions["VRMC_springBone"] = buildSpringBoneDict(springBone)
        }

        gltfDict["extensions"] = extensions

        // Ensure extensionsUsed includes VRMC_vrm
        var extensionsUsed = gltfDict["extensionsUsed"] as? [String] ?? []
        if !extensionsUsed.contains("VRMC_vrm") {
            extensionsUsed.append("VRMC_vrm")
        }
        gltfDict["extensionsUsed"] = extensionsUsed

        return gltfDict
    }

    private func buildMetaDict() -> [String: Any] {
        var dict: [String: Any] = [:]

        if let name = meta.name {
            dict["name"] = name
        }
        if let version = meta.version {
            dict["version"] = version
        }
        if !meta.authors.isEmpty {
            dict["authors"] = meta.authors
        }
        if let copyrightInformation = meta.copyrightInformation {
            dict["copyrightInformation"] = copyrightInformation
        }
        if let contactInformation = meta.contactInformation {
            dict["contactInformation"] = contactInformation
        }
        dict["licenseUrl"] = meta.licenseUrl

        if let avatarPermission = meta.avatarPermission {
            dict["avatarPermission"] = avatarPermission.rawValue
        }
        if let commercialUsage = meta.commercialUsage {
            dict["commercialUsage"] = commercialUsage.rawValue
        }

        return dict
    }

    private func buildHumanoidDict(_ humanoid: VRMHumanoid) -> [String: Any] {
        var humanBonesDict: [String: Any] = [:]

        for (bone, humanBone) in humanoid.humanBones {
            humanBonesDict[bone.rawValue] = ["node": humanBone.node]
        }

        return ["humanBones": humanBonesDict]
    }

    private func buildExpressionsDict(_ expressions: VRMExpressions) -> [String: Any] {
        var dict: [String: Any] = [:]

        // Preset expressions
        var presetDict: [String: Any] = [:]
        for (preset, expression) in expressions.preset {
            presetDict[preset.rawValue] = buildExpressionDict(expression)
        }
        if !presetDict.isEmpty {
            dict["preset"] = presetDict
        }

        // Custom expressions
        if !expressions.custom.isEmpty {
            var customDict: [String: Any] = [:]
            for (name, expression) in expressions.custom {
                customDict[name] = buildExpressionDict(expression)
            }
            dict["custom"] = customDict
        }

        return dict
    }

    private func buildExpressionDict(_ expression: VRMExpression) -> [String: Any] {
        var dict: [String: Any] = [:]

        if expression.isBinary {
            dict["isBinary"] = true
        }

        if !expression.morphTargetBinds.isEmpty {
            dict["morphTargetBinds"] = expression.morphTargetBinds.map { bind in
                return [
                    "node": bind.node,
                    "index": bind.index,
                    "weight": bind.weight
                ]
            }
        }

        if !expression.materialColorBinds.isEmpty {
            dict["materialColorBinds"] = expression.materialColorBinds.map { bind in
                return [
                    "material": bind.material,
                    "type": bind.type.rawValue,
                    "targetValue": [
                        bind.targetValue.x, bind.targetValue.y, bind.targetValue.z,
                        bind.targetValue.w
                    ]
                ]
            }
        }

        if expression.overrideBlink != .none {
            dict["overrideBlink"] = expression.overrideBlink.rawValue
        }
        if expression.overrideLookAt != .none {
            dict["overrideLookAt"] = expression.overrideLookAt.rawValue
        }
        if expression.overrideMouth != .none {
            dict["overrideMouth"] = expression.overrideMouth.rawValue
        }

        return dict
    }

    private func buildLookAtDict(_ lookAt: VRMLookAt) -> [String: Any] {
        return [
            "type": lookAt.type.rawValue,
            "offsetFromHeadBone": [
                lookAt.offsetFromHeadBone.x, lookAt.offsetFromHeadBone.y,
                lookAt.offsetFromHeadBone.z
            ]
        ]
    }

    private func buildFirstPersonDict(_ firstPerson: VRMFirstPerson) -> [String: Any] {
        var dict: [String: Any] = [:]

        if !firstPerson.meshAnnotations.isEmpty {
            dict["meshAnnotations"] = firstPerson.meshAnnotations.map { annotation in
                return [
                    "node": annotation.node,
                    "type": annotation.type.rawValue
                ]
            }
        }

        return dict
    }

    private func buildSpringBoneDict(_ springBone: VRMSpringBone) -> [String: Any] {
        var dict: [String: Any] = [:]

        dict["specVersion"] = springBone.specVersion

        // Add colliders, groups, springs, etc.
        // (Simplified for now)

        return dict
    }

    // MARK: - GLB Creation

    private func createGLB(json: [String: Any], binaryData: Data) throws -> Data {
        // GLB structure:
        // Header (12 bytes):
        //   - magic: 0x46546C67 ("glTF")
        //   - version: 2
        //   - length: total file size
        // JSON chunk:
        //   - chunkLength
        //   - chunkType: 0x4E4F534A ("JSON")
        //   - chunkData (padded to 4-byte boundary with spaces)
        // BIN chunk (optional):
        //   - chunkLength
        //   - chunkType: 0x004E4942 ("BIN\0")
        //   - chunkData (padded to 4-byte boundary with zeros)

        // Serialize JSON
        let jsonData = try JSONSerialization.data(
            withJSONObject: json, options: [.sortedKeys, .prettyPrinted])

        // Pad JSON to 4-byte boundary with spaces (0x20)
        let jsonPadding = (4 - (jsonData.count % 4)) % 4
        var paddedJSON = jsonData
        if jsonPadding > 0 {
            paddedJSON.append(Data(repeating: 0x20, count: jsonPadding))
        }

        // Pad binary data to 4-byte boundary with zeros (0x00)
        let binaryPadding = (4 - (binaryData.count % 4)) % 4
        var paddedBinary = binaryData
        if binaryPadding > 0 {
            paddedBinary.append(Data(repeating: 0x00, count: binaryPadding))
        }

        // Calculate total length
        let headerLength = 12
        let jsonChunkHeaderLength = 8
        let binaryChunkHeaderLength = binaryData.isEmpty ? 0 : 8
        let totalLength =
            headerLength + jsonChunkHeaderLength + paddedJSON.count + binaryChunkHeaderLength
            + paddedBinary.count

        // Build GLB
        var glbData = Data()

        // Header
        glbData.append(UInt32(0x4654_6C67).littleEndian.data)  // magic "glTF"
        glbData.append(UInt32(2).littleEndian.data)  // version 2
        glbData.append(UInt32(totalLength).littleEndian.data)  // total length

        // JSON chunk header
        glbData.append(UInt32(paddedJSON.count).littleEndian.data)  // chunk length
        glbData.append(UInt32(0x4E4F_534A).littleEndian.data)  // chunk type "JSON"

        // JSON chunk data
        glbData.append(paddedJSON)

        // Binary chunk (if we have binary data)
        if !binaryData.isEmpty {
            glbData.append(UInt32(paddedBinary.count).littleEndian.data)  // chunk length
            glbData.append(UInt32(0x004E_4942).littleEndian.data)  // chunk type "BIN\0"
            glbData.append(paddedBinary)
        }

        return glbData
    }
}

// MARK: - Helper Extensions

extension UInt32 {
    var data: Data {
        var value = self
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    }
}
