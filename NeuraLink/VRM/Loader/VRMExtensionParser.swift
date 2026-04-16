//
// VRMExtensionParser.swift
// NeuraLink
//
// Created by Dedicatus on 15/04/2026.
//

import Foundation
import simd

/// VRM node constraint definition for roll, aim, and rotation constraints.
///
/// VRM 1.0 stores these in VRMC_node_constraint extension.
/// VRM 0.0 requires synthesizing constraints from humanoid bone definitions.
public struct VRMNodeConstraint: Sendable {
    /// The type of constraint to apply
    public enum ConstraintType: Sendable {
        /// Roll constraint: transfers rotation around a specific axis from source to target
        case roll(sourceNode: Int, axis: SIMD3<Float>, weight: Float)

        /// Aim constraint: orients target to point at source
        case aim(sourceNode: Int, aimAxis: SIMD3<Float>, weight: Float)

        /// Rotation constraint: copies full rotation from source to target
        case rotation(sourceNode: Int, weight: Float)
    }

    /// The node index that this constraint affects
    public let targetNode: Int

    /// The type and parameters of the constraint
    public let constraint: ConstraintType

    public init(targetNode: Int, constraint: ConstraintType) {
        self.targetNode = targetNode
        self.constraint = constraint
    }
}

public class VRMExtensionParser {

    public init() {}

    public func parseVRMExtension(_ extension: Any, document: GLTFDocument, filePath: String? = nil)
        throws -> VRMModel
    {
        guard let vrmDict = `extension` as? [String: Any] else {
            throw VRMError.missingVRMExtension(
                filePath: filePath,
                suggestion:
                    "The VRM extension is not a valid dictionary object. Ensure your model was exported with proper VRM extension data."
            )
        }

        // Parse spec version (VRM 1.0 uses "specVersion", VRM 0.0 uses "version")
        let versionKey = vrmDict["specVersion"] != nil ? "specVersion" : "version"
        let versionStr = vrmDict[versionKey] as? String

        // For VRM 0.0, we'll assume version "0.0" if it has the old structure
        let specVersion: VRMSpecVersion
        if let versionStr = versionStr {
            specVersion = VRMSpecVersion(rawValue: versionStr) ?? .v0_0
        } else {
            // If no version field but has VRM 0.0 structure, assume 0.0
            specVersion = .v0_0
        }

        // Parse meta (required)
        guard let metaDict = vrmDict["meta"] as? [String: Any] else {
            throw VRMError.invalidJSON(
                context: "VRM extension 'meta' field",
                underlyingError:
                    "Missing or not a dictionary. VRM models require metadata including name, version, author, etc.",
                filePath: filePath
            )
        }
        let meta = try parseMeta(metaDict)

        // Parse humanoid (required)
        guard let humanoidDict = vrmDict["humanoid"] as? [String: Any] else {
            throw VRMError.invalidJSON(
                context: "VRM extension 'humanoid' field",
                underlyingError:
                    "Missing or not a dictionary. VRM models require humanoid bone mappings.",
                filePath: filePath
            )
        }
        let humanoid = try parseHumanoid(humanoidDict)

        // Create model
        let model = VRMModel(
            specVersion: specVersion,
            meta: meta,
            humanoid: humanoid,
            gltf: document
        )

        // Parse optional components
        if let firstPersonDict = vrmDict["firstPerson"] as? [String: Any] {
            model.firstPerson = try parseFirstPerson(firstPersonDict)
        }

        // VRM 1.0 has separate lookAt, VRM 0.0 has lookAt data in firstPerson
        if let lookAtDict = vrmDict["lookAt"] as? [String: Any] {
            model.lookAt = try parseLookAt(lookAtDict)
        } else if let firstPersonDict = vrmDict["firstPerson"] as? [String: Any] {
            // VRM 0.0 embeds lookAt data in firstPerson
            model.lookAt = try parseLookAtFromFirstPerson(firstPersonDict)
        }

        // VRM 1.0 uses "expressions", VRM 0.0 uses "blendShapeMaster"
        if let expressionsDict = vrmDict["expressions"] as? [String: Any] {
            model.expressions = try parseExpressions(expressionsDict)
        } else if let blendShapeMaster = vrmDict["blendShapeMaster"] as? [String: Any] {
            // Parse VRM 0.0 blendShapeMaster
            model.expressions = try parseBlendShapeMaster(blendShapeMaster)
        }

        // Parse SpringBone extension if present
        // VRM 1.0 uses VRMC_springBone extension
        if let springBoneExt = document.extensions?["VRMC_springBone"] as? [String: Any] {
            model.springBone = try parseSpringBone(springBoneExt)
        }
        // VRM 0.0 uses secondaryAnimation in the main VRM extension
        else if let secondaryAnimation = vrmDict["secondaryAnimation"] as? [String: Any] {
            model.springBone = parseSecondaryAnimation(secondaryAnimation)
        }

        // Parse VRM 0.x materialProperties (MToon data at document level)
        if let materialProperties = vrmDict["materialProperties"] as? [[String: Any]] {
            model.vrm0MaterialProperties = parseMaterialProperties(materialProperties)
        }

        // Parse or synthesize node constraints (for twist bones)
        let isVRM0 = specVersion == .v0_0
        model.nodeConstraints = parseOrSynthesizeConstraints(
            gltf: document, humanoid: humanoid, isVRM0: isVRM0)

        return model
    }

    // MARK: - VRM 0.x Material Properties Parsing

    private func parseMaterialProperties(_ properties: [[String: Any]]) -> [VRM0MaterialProperty] {
        var result: [VRM0MaterialProperty] = []

        for (index, propDict) in properties.enumerated() {
            var prop = VRM0MaterialProperty()

            prop.name = propDict["name"] as? String
            prop.shader = propDict["shader"] as? String
            prop.renderQueue = propDict["renderQueue"] as? Int

            // Parse float properties
            if let floatProps = propDict["floatProperties"] as? [String: Any] {
                for (key, value) in floatProps {
                    if let floatValue = value as? Double {
                        prop.floatProperties[key] = Float(floatValue)
                    } else if let floatValue = value as? Float {
                        prop.floatProperties[key] = floatValue
                    } else if let intValue = value as? Int {
                        prop.floatProperties[key] = Float(intValue)
                    }
                }
            }

            // Parse vector properties
            if let vectorProps = propDict["vectorProperties"] as? [String: Any] {
                for (key, value) in vectorProps {
                    if let arrayValue = value as? [Double] {
                        prop.vectorProperties[key] = arrayValue.map { Float($0) }
                    } else if let arrayValue = value as? [Float] {
                        prop.vectorProperties[key] = arrayValue
                    } else if let arrayValue = value as? [Int] {
                        prop.vectorProperties[key] = arrayValue.map { Float($0) }
                    }
                }
            }

            // Parse texture properties
            if let textureProps = propDict["textureProperties"] as? [String: Any] {
                for (key, value) in textureProps {
                    if let intValue = value as? Int {
                        prop.textureProperties[key] = intValue
                    }
                }
            }

            // Parse keyword map
            if let keywordMap = propDict["keywordMap"] as? [String: Bool] {
                prop.keywordMap = keywordMap
            }

            // Parse tag map
            if let tagMap = propDict["tagMap"] as? [String: String] {
                prop.tagMap = tagMap
            }

            result.append(prop)
        }

        return result
    }

    private func parseMeta(_ dict: [String: Any]) throws -> VRMMeta {
        // VRM 1.0 uses "licenseUrl", VRM 0.0 uses "otherLicenseUrl"
        let licenseUrl =
            (dict["licenseUrl"] as? String) ?? (dict["otherLicenseUrl"] as? String) ?? ""

        var meta = VRMMeta(licenseUrl: licenseUrl)

        // VRM 1.0 uses "name", VRM 0.0 uses "title"
        meta.name = (dict["name"] as? String) ?? (dict["title"] as? String)
        meta.version = dict["version"] as? String
        // VRM 1.0 uses "authors" array, VRM 0.0 uses "author" string
        if let authors = dict["authors"] as? [String] {
            meta.authors = authors
        } else if let author = dict["author"] as? String {
            meta.authors = [author]
        } else {
            meta.authors = []
        }
        meta.copyrightInformation = dict["copyrightInformation"] as? String
        meta.contactInformation = dict["contactInformation"] as? String
        meta.references = dict["references"] as? [String] ?? []
        meta.thirdPartyLicenses = dict["thirdPartyLicenses"] as? String
        meta.thumbnailImage = dict["thumbnailImage"] as? Int

        if let avatarPermissionStr = dict["avatarPermission"] as? String {
            meta.avatarPermission = VRMAvatarPermission(rawValue: avatarPermissionStr)
        }

        if let commercialUsageStr = dict["commercialUsage"] as? String {
            meta.commercialUsage = VRMCommercialUsage(rawValue: commercialUsageStr)
        }

        if let creditNotationStr = dict["creditNotation"] as? String {
            meta.creditNotation = VRMCreditNotation(rawValue: creditNotationStr)
        }

        meta.allowRedistribution = dict["allowRedistribution"] as? Bool

        if let modifyStr = dict["modify"] as? String {
            meta.modify = VRMModifyPermission(rawValue: modifyStr)
        }

        meta.otherLicenseUrl = dict["otherLicenseUrl"] as? String

        return meta
    }

    private func parseHumanoid(_ dict: [String: Any]) throws -> VRMHumanoid {
        let humanoid = VRMHumanoid()

        // VRM 1.0 uses a dictionary, VRM 0.0 uses an array
        if let humanBonesDict = dict["humanBones"] as? [String: Any] {
            // VRM 1.0 format
            for (boneName, boneData) in humanBonesDict {
                guard let bone = VRMHumanoidBone(rawValue: boneName),
                    let boneDict = boneData as? [String: Any],
                    let nodeIndex = boneDict["node"] as? Int
                else {
                    continue
                }

                humanoid.humanBones[bone] = VRMHumanoid.VRMHumanBone(node: nodeIndex)
            }
        } else if let humanBonesArray = dict["humanBones"] as? [[String: Any]] {
            // VRM 0.0 format - array of bone objects
            for boneData in humanBonesArray {
                guard let boneName = boneData["bone"] as? String,
                    let bone = VRMHumanoidBone(rawValue: boneName),
                    let nodeIndex = boneData["node"] as? Int
                else {
                    continue
                }

                humanoid.humanBones[bone] = VRMHumanoid.VRMHumanBone(node: nodeIndex)
            }
        }

        try humanoid.validate()

        return humanoid
    }

    private func parseFirstPerson(_ dict: [String: Any]) throws -> VRMFirstPerson {
        let firstPerson = VRMFirstPerson()

        if let meshAnnotations = dict["meshAnnotations"] as? [[String: Any]] {
            for annotation in meshAnnotations {
                // VRM 0.0 uses "mesh" instead of "node" for some annotations
                let nodeOrMesh = annotation["node"] as? Int ?? annotation["mesh"] as? Int
                guard let node = nodeOrMesh,
                    let typeStr = annotation["firstPersonFlag"] as? String ?? annotation["type"]
                        as? String
                else {
                    continue
                }

                // Map VRM 0.0 flag names to VRM 1.0 if needed
                let type = VRMFirstPersonFlag(rawValue: typeStr) ?? .auto

                firstPerson.meshAnnotations.append(
                    VRMFirstPerson.VRMMeshAnnotation(node: node, type: type)
                )
            }
        }

        return firstPerson
    }

}
