//
// VRMModelTypes.swift
// NeuraLink
//
// Created by Dedicatus on 14/04/2026.
//

import Foundation
import simd

// MARK: - Supporting Classes

/// Humanoid bone configuration for a VRM avatar.
///
/// Maps standard humanoid bones (hips, spine, arms, legs, etc.) to node indices
/// in the model's scene graph. This enables animations to target bones by semantic
/// name rather than model-specific node names.
///
/// ## Required Bones
/// VRM requires these bones: hips, spine, head, and all arm/leg bones.
/// Use `validate()` to check if all required bones are present.
public class VRMHumanoid {
    /// Maps humanoid bone types to their node references.
    public var humanBones: [VRMHumanoidBone: VRMHumanBone] = [:]

    /// A reference to a humanoid bone's node.
    public struct VRMHumanBone {
        /// The index into `VRMModel.nodes` for this bone.
        public let node: Int

        public init(node: Int) {
            self.node = node
        }
    }

    public init() {}

    /// Returns the node index for a humanoid bone.
    ///
    /// - Parameter bone: The bone type to look up (e.g., `.hips`, `.leftHand`).
    /// - Returns: The node index, or `nil` if the bone isn't mapped.
    public func getBoneNode(_ bone: VRMHumanoidBone) -> Int? {
        return humanBones[bone]?.node
    }

    /// Validates that all required humanoid bones are present.
    ///
    /// - Parameter filePath: Optional file path for error messages.
    /// - Throws: `VRMError.missingRequiredBone` if a required bone is missing.
    public func validate(filePath: String? = nil) throws {
        // Check all required bones are present
        for bone in VRMHumanoidBone.allCases where bone.isRequired {
            guard humanBones[bone] != nil else {
                let availableBoneNames = humanBones.keys.map { $0.rawValue }
                throw VRMError.missingRequiredBone(
                    bone: bone,
                    availableBones: availableBoneNames,
                    filePath: filePath
                )
            }
        }
    }
}

/// First-person camera configuration for VRM avatars.
///
/// Defines which meshes should be visible or hidden when rendering from the avatar's
/// perspective. This prevents the avatar's head from blocking the camera view.
public class VRMFirstPerson {
    /// Mesh visibility annotations for first-person rendering.
    public var meshAnnotations: [VRMMeshAnnotation] = []

    /// Annotation specifying how a mesh should be rendered in first-person view.
    public struct VRMMeshAnnotation {
        /// The node index of the annotated mesh.
        public let node: Int
        /// The visibility flag for this mesh.
        public let type: VRMFirstPersonFlag

        public init(node: Int, type: VRMFirstPersonFlag) {
            self.node = node
            self.type = type
        }
    }

    public init() {}
}

/// Eye gaze (look-at) configuration for VRM avatars.
///
/// Defines how the avatar's eyes track a target point, including the offset from the
/// head bone and range limits for horizontal and vertical eye movement.
public class VRMLookAt {
    /// The method used to control gaze (bone rotation or blend shapes).
    public var type: VRMLookAtType = .bone

    /// Offset from the head bone to the eye position in local space.
    public var offsetFromHeadBone: SIMD3<Float> = [0, 0, 0]

    /// Range map for inward horizontal eye movement.
    public var rangeMapHorizontalInner: VRMLookAtRangeMap = VRMLookAtRangeMap()

    /// Range map for outward horizontal eye movement.
    public var rangeMapHorizontalOuter: VRMLookAtRangeMap = VRMLookAtRangeMap()

    /// Range map for downward vertical eye movement.
    public var rangeMapVerticalDown: VRMLookAtRangeMap = VRMLookAtRangeMap()

    /// Range map for upward vertical eye movement.
    public var rangeMapVerticalUp: VRMLookAtRangeMap = VRMLookAtRangeMap()

    public init() {}
}

/// Facial expression configuration for VRM avatars.
///
/// Contains both preset expressions (happy, angry, sad, etc.) defined by the VRM spec
/// and custom expressions defined by the model creator.
///
/// ## Usage
/// ```swift
/// // Get a preset expression
/// if let happy = model.expressions?.preset[.happy] {
///     // Apply with VRMExpressionController
/// }
///
/// // Get a custom expression
/// if let wink = model.expressions?.custom["wink"] {
///     // Apply custom expression
/// }
/// ```
public class VRMExpressions {
    /// Standard VRM expressions (happy, angry, sad, surprised, blink, etc.).
    public var preset: [VRMExpressionPreset: VRMExpression] = [:]

    /// Model-specific custom expressions keyed by name.
    public var custom: [String: VRMExpression] = [:]

    public init() {}
}

// MARK: - Errors

/// Comprehensive VRM loading and validation errors with LLM-friendly contextual information
public enum VRMError: Error {
    // VRM Extension Errors
    case missingVRMExtension(filePath: String?, suggestion: String)

    // Humanoid Bone Errors
    case missingRequiredBone(bone: VRMHumanoidBone, availableBones: [String], filePath: String?)

    // File Format Errors
    case invalidGLBFormat(reason: String, filePath: String?)
    case invalidJSON(context: String, underlyingError: String?, filePath: String?)
    case unsupportedVersion(version: String, supported: [String], filePath: String?)

    // Buffer and Accessor Errors
    case missingBuffer(bufferIndex: Int, requiredBy: String, expectedSize: Int?, filePath: String?)
    case invalidAccessor(accessorIndex: Int, reason: String, context: String, filePath: String?)

    // Texture Errors
    case missingTexture(textureIndex: Int, materialName: String?, uri: String?, filePath: String?)
    case invalidImageData(textureIndex: Int, reason: String, filePath: String?)

    // Mesh and Geometry Errors
    case invalidMesh(meshIndex: Int, primitiveIndex: Int?, reason: String, filePath: String?)
    case missingVertexAttribute(meshIndex: Int, attributeName: String, filePath: String?)

    // Resource Errors
    case deviceNotSet(context: String)
    case invalidPath(path: String, reason: String, filePath: String?)

    // Material Errors
    case invalidMaterial(materialIndex: Int, reason: String, filePath: String?)

    // Loading Errors
    case loadingCancelled
}

extension VRMError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingVRMExtension(let filePath, let suggestion):
            let fileInfo = filePath.map { " in file '\($0)'" } ?? ""
            return """
                ❌ Missing VRM Extension

                The file\(fileInfo) does not contain a valid VRMC_vrm extension. This is required for VRM 1.0 models.

                Suggestion: \(suggestion)

                VRM Spec: https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm-1.0/
                """

        case .missingRequiredBone(let bone, let availableBones, let filePath):
            let fileInfo = filePath.map { " in file '\($0)'" } ?? ""
            let bonesListStr =
                availableBones.isEmpty ? "(none)" : availableBones.joined(separator: ", ")
            return """
                ❌ Missing Required Humanoid Bone: '\(bone.rawValue)'

                The VRM model\(fileInfo) is missing the required humanoid bone '\(bone.rawValue)'.
                Available bones: \(bonesListStr)

                Suggestion: Ensure your 3D model has a bone for '\(bone.rawValue)' and that it's properly mapped in the VRM humanoid configuration. Common bone names include: Hips, Spine, Chest, Neck, Head, LeftUpperArm, RightUpperArm, etc.

                VRM Spec: https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_vrm-1.0/humanoid.md
                """

        case .invalidGLBFormat(let reason, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            return """
                ❌ Invalid GLB Format

                \(fileInfo)Reason: \(reason)

                Suggestion: Ensure the file is a valid GLB (binary glTF) file. GLB files must start with the magic number 0x46546C67 ('glTF' in ASCII) and have a valid header structure.

                glTF Spec: https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#glb-file-format-specification
                """

        case .invalidJSON(let context, let underlyingError, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            let errorInfo = underlyingError.map { "\nUnderlying error: \($0)" } ?? ""
            return """
                ❌ Invalid JSON Data

                \(fileInfo)Context: \(context)\(errorInfo)

                Suggestion: Check that the JSON structure in your VRM/GLB file is valid and follows the glTF 2.0 specification. Use a JSON validator or glTF validator tool.

                Tools: https://github.khronos.org/glTF-Validator/
                """

        case .unsupportedVersion(let version, let supported, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            let supportedStr = supported.joined(separator: ", ")
            return """
                ❌ Unsupported Version

                \(fileInfo)Version found: \(version)
                Supported versions: \(supportedStr)

                Suggestion: Convert your VRM model to a supported version. Use VRM conversion tools or export from your 3D software with the correct VRM version settings.
                """

        case .missingBuffer(let bufferIndex, let requiredBy, let expectedSize, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            let sizeInfo = expectedSize.map { " (expected size: \($0) bytes)" } ?? ""
            return """
                ❌ Missing Buffer Data

                \(fileInfo)Buffer index: \(bufferIndex)
                Required by: \(requiredBy)\(sizeInfo)

                Suggestion: The buffer data is missing or incomplete. Check that all buffers referenced in the glTF JSON are present in the GLB binary chunk or as external files. Ensure buffer byte lengths match the declared sizes.

                glTF Spec: https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#buffers-and-buffer-views
                """

        case .invalidAccessor(let accessorIndex, let reason, let context, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            return """
                ❌ Invalid Accessor

                \(fileInfo)Accessor index: \(accessorIndex)
                Context: \(context)
                Reason: \(reason)

                Suggestion: Accessors define how to read vertex data from buffers. Check that the accessor's bufferView, componentType, type, and count are valid. Ensure the accessor doesn't read beyond the buffer bounds.

                glTF Spec: https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#accessors
                """

        case .missingTexture(let textureIndex, let materialName, let uri, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            let materialInfo = materialName.map { "Material: '\($0)'\n" } ?? ""
            let uriInfo = uri.map { "URI: '\($0)'\n" } ?? ""
            return """
                ❌ Missing Texture

                \(fileInfo)\(materialInfo)Texture index: \(textureIndex)
                \(uriInfo)
                Suggestion: The texture file is missing or cannot be loaded. Check that:
                • External texture files exist at the specified URI
                • Embedded textures are properly stored in the GLB binary chunk
                • Data URIs are valid base64-encoded images
                • File paths are correct and accessible

                Supported formats: PNG, JPEG, KTX2, Basis Universal
                """

        case .invalidImageData(let textureIndex, let reason, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            return """
                ❌ Invalid Image Data

                \(fileInfo)Texture index: \(textureIndex)
                Reason: \(reason)

                Suggestion: The image data is corrupted or in an unsupported format. Re-export your textures as PNG or JPEG and ensure they're properly embedded or referenced in your VRM file.
                """

        case .invalidMesh(let meshIndex, let primitiveIndex, let reason, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            let primInfo = primitiveIndex.map { ", primitive \($0)" } ?? ""
            return """
                ❌ Invalid Mesh Data

                \(fileInfo)Mesh index: \(meshIndex)\(primInfo)
                Reason: \(reason)

                Suggestion: Check that your mesh has:
                • Valid vertex positions (POSITION attribute)
                • Valid normals (NORMAL attribute)
                • Valid UVs if textures are used (TEXCOORD_0)
                • Valid indices if indexed drawing is used
                • Skinning data (JOINTS_0, WEIGHTS_0) if the mesh is rigged

                glTF Spec: https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#meshes
                """

        case .missingVertexAttribute(let meshIndex, let attributeName, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            return """
                ❌ Missing Vertex Attribute

                \(fileInfo)Mesh index: \(meshIndex)
                Attribute: \(attributeName)

                Suggestion: The mesh is missing the '\(attributeName)' vertex attribute. Common attributes:
                • POSITION (required) - vertex positions
                • NORMAL (recommended) - for lighting
                • TEXCOORD_0 (for textures) - UV coordinates
                • JOINTS_0, WEIGHTS_0 (for skinning) - bone influences

                Ensure your 3D model has this data and it's properly exported.
                """

        case .deviceNotSet(let context):
            return """
                ❌ Metal Device Not Set

                Context: \(context)

                Suggestion: You must set a Metal device before performing GPU operations. Call `model.device = MTLCreateSystemDefaultDevice()` or pass a device during initialization.
                """

        case .invalidPath(let path, let reason, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            return """
                ❌ Invalid File Path

                \(fileInfo)Path: '\(path)'
                Reason: \(reason)

                Suggestion: Check that the file path is correct and accessible. Ensure:
                • The file exists at the specified location
                • You have read permissions
                • The path doesn't contain invalid characters
                • Relative paths are resolved correctly from the base directory
                """

        case .invalidMaterial(let materialIndex, let reason, let filePath):
            let fileInfo = filePath.map { "File: '\($0)'\n" } ?? ""
            return """
                ❌ Invalid Material

                \(fileInfo)Material index: \(materialIndex)
                Reason: \(reason)

                Suggestion: Check that the material has valid properties:
                • Base color texture references valid texture indices
                • PBR metallic-roughness values are in valid ranges [0, 1]
                • MToon shader parameters are correctly configured
                • Alpha mode is one of: OPAQUE, MASK, BLEND

                VRM MToon Spec: https://github.com/vrm-c/vrm-specification/blob/master/specification/VRMC_materials_mtoon-1.0/README.md
                """

        case .loadingCancelled:
            return """
                ⚠️ Loading Cancelled

                The VRM model loading was cancelled by the user.

                Suggestion: If this was unexpected, check that:
                • The loading task wasn't explicitly cancelled
                • The parent Task wasn't cancelled
                • No timeout or cancellation token was triggered
                """
        }
    }
}
