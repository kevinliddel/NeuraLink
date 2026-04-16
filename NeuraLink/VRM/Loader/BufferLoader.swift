//
// BufferLoader.swift
// NeuraLink
//
// Created by Dedicatus on 15/04/2026.
//

import Foundation
import Metal
import simd

public class BufferLoader: @unchecked Sendable {
    private let document: GLTFDocument
    private let binaryData: Data?
    private let baseURL: URL?

    /// Preloaded buffer data (optional optimization)
    private var preloadedData: [Int: Data]?

    /// The file path for error reporting
    internal var filePath: String? {
        return baseURL?.path
    }

    public init(
        document: GLTFDocument, binaryData: Data?, baseURL: URL? = nil,
        preloadedData: [Int: Data]? = nil
    ) {
        self.document = document
        self.binaryData = binaryData
        self.baseURL = baseURL
        self.preloadedData = preloadedData
    }

    /// Set preloaded buffer data (for use with BufferPreloader)
    public func setPreloadedData(_ data: [Int: Data]) {
        self.preloadedData = data
    }

    // MARK: - Accessor Loading

    public func loadAccessor<T>(_ accessorIndex: Int, type: T.Type) throws -> [T] where T: Numeric {
        guard let accessor = document.accessors?[safe: accessorIndex] else {
            throw VRMError.invalidAccessor(
                accessorIndex: accessorIndex,
                reason: "Accessor not found in document",
                context: "loadAccessor<\(T.self)>",
                filePath: filePath
            )
        }

        guard let bufferViewIndex = accessor.bufferView else {
            // Sparse accessor or zero-filled
            return Array(
                repeating: 0 as! T, count: accessor.count * componentCount(for: accessor.type))
        }

        let (data, bufferView) = try loadBufferView(bufferViewIndex)

        // CRITICAL FIX: Apply BOTH the bufferView offset AND accessor offset
        let bufferViewOffset = bufferView.byteOffset ?? 0
        let accessorOffset = accessor.byteOffset ?? 0
        let combinedOffset = bufferViewOffset + accessorOffset

        let stride =
            bufferView.byteStride
            ?? bytesPerElement(componentType: accessor.componentType, accessorType: accessor.type)

        var result: [T] = []
        let componentSize = bytesPerComponent(accessor.componentType)
        let components = componentCount(for: accessor.type)

        for i in 0..<accessor.count {
            let elementOffset = combinedOffset + (i * stride)

            for j in 0..<components {
                let componentOffset = elementOffset + (j * componentSize)
                let value = extractComponent(
                    from: data, at: componentOffset, componentType: accessor.componentType,
                    as: T.self)
                result.append(value)
            }
        }

        return result
    }

    public func loadAccessorAsFloat(_ accessorIndex: Int) throws -> [Float] {
        guard let accessor = document.accessors?[safe: accessorIndex] else {
            throw VRMError.invalidAccessor(
                accessorIndex: accessorIndex,
                reason: "Accessor not found in document",
                context: "loadAccessorAsFloat",
                filePath: filePath
            )
        }

        guard let bufferViewIndex = accessor.bufferView else {
            return Array(repeating: 0, count: accessor.count * componentCount(for: accessor.type))
        }

        let (data, bufferView) = try loadBufferView(bufferViewIndex)

        // CRITICAL FIX: Apply BOTH the bufferView offset AND accessor offset
        let bufferViewOffset = bufferView.byteOffset ?? 0
        let accessorOffset = accessor.byteOffset ?? 0
        let combinedOffset = bufferViewOffset + accessorOffset

        let stride =
            bufferView.byteStride
            ?? bytesPerElement(componentType: accessor.componentType, accessorType: accessor.type)

        var result: [Float] = []
        let componentSize = bytesPerComponent(accessor.componentType)
        let components = componentCount(for: accessor.type)

        for i in 0..<accessor.count {
            let elementOffset = combinedOffset + (i * stride)

            for j in 0..<components {
                let componentOffset = elementOffset + (j * componentSize)
                let value = extractFloatComponent(
                    from: data, at: componentOffset, componentType: accessor.componentType)
                result.append(value)
            }
        }

        return result
    }

    public func loadAccessorAsUInt32(_ accessorIndex: Int) throws -> [UInt32] {
        guard let accessor = document.accessors?[safe: accessorIndex] else {
            throw VRMError.invalidAccessor(
                accessorIndex: accessorIndex,
                reason: "Accessor not found in document",
                context: "loadAccessorAsUInt32",
                filePath: filePath
            )
        }

        guard let bufferViewIndex = accessor.bufferView else {
            return Array(repeating: 0, count: accessor.count * componentCount(for: accessor.type))
        }

        let (data, bufferView) = try loadBufferView(bufferViewIndex)

        // CRITICAL FIX: Apply BOTH the bufferView offset AND accessor offset
        let bufferViewOffset = bufferView.byteOffset ?? 0
        let accessorOffset = accessor.byteOffset ?? 0
        let combinedOffset = bufferViewOffset + accessorOffset

        // CRITICAL FIX: Use the bufferView's byteStride for interleaved vertex attributes.
        let stride =
            bufferView.byteStride
            ?? bytesPerElement(componentType: accessor.componentType, accessorType: accessor.type)

        var result: [UInt32] = []
        let componentSize = bytesPerComponent(accessor.componentType)
        let components = componentCount(for: accessor.type)

        for i in 0..<accessor.count {
            let elementOffset = combinedOffset + (i * stride)

            for j in 0..<components {
                let componentOffset = elementOffset + (j * componentSize)
                let value = extractUIntComponent(
                    from: data, at: componentOffset, componentType: accessor.componentType)
                result.append(value)
            }
        }

        return result
    }

    public func loadAccessorAsMatrix4x4(_ accessorIndex: Int) throws -> [float4x4] {
        guard let accessor = document.accessors?[safe: accessorIndex] else {
            throw VRMError.invalidAccessor(
                accessorIndex: accessorIndex,
                reason: "Accessor not found in document",
                context: "loadAccessorAsMatrix4x4",
                filePath: filePath
            )
        }

        // MAT4 type should have 16 components per element
        guard accessor.type == "MAT4" else {
            throw VRMError.invalidAccessor(
                accessorIndex: accessorIndex,
                reason: "Expected MAT4 type but got '\(accessor.type)'",
                context: "loadAccessorAsMatrix4x4 requires MAT4 accessor type",
                filePath: filePath
            )
        }

        let floatData = try loadAccessorAsFloat(accessorIndex)
        var matrices: [float4x4] = []

        // Each matrix has 16 floats
        for i in stride(from: 0, to: floatData.count, by: 16) {
            guard i + 15 < floatData.count else { break }

            // GLTF stores matrices in column-major order
            // Load as-is without transpose - the matrices are correct as stored
            let matrix = float4x4(
                SIMD4<Float>(floatData[i], floatData[i + 1], floatData[i + 2], floatData[i + 3]),
                SIMD4<Float>(
                    floatData[i + 4], floatData[i + 5], floatData[i + 6], floatData[i + 7]),
                SIMD4<Float>(
                    floatData[i + 8], floatData[i + 9], floatData[i + 10], floatData[i + 11]),
                SIMD4<Float>(
                    floatData[i + 12], floatData[i + 13], floatData[i + 14], floatData[i + 15])
            )
            matrices.append(matrix)
        }

        return matrices
    }

    // MARK: - Buffer Data Access

    public func getBufferData(bufferIndex: Int) throws -> Data {
        // Check preloaded data first (optimization)
        if let preloaded = preloadedData?[bufferIndex] {
            return preloaded
        }

        guard let buffer = document.buffers?[safe: bufferIndex] else {
            throw VRMError.missingBuffer(
                bufferIndex: bufferIndex,
                requiredBy: "getBufferData",
                expectedSize: nil,
                filePath: filePath
            )
        }

        if bufferIndex == 0, let binaryData = self.binaryData {
            // First buffer is the binary chunk
            return binaryData
        } else if let uri = buffer.uri {
            // Data URI or external file
            if uri.hasPrefix("data:") {
                return try loadDataURI(uri)
            } else {
                // External file
                return try loadExternalBuffer(uri)
            }
        } else {
            throw VRMError.missingBuffer(
                bufferIndex: bufferIndex,
                requiredBy: "getBufferData",
                expectedSize: buffer.byteLength,
                filePath: filePath
            )
        }
    }

    // MARK: - Buffer View Loading

    public func createMTLBuffer(for bufferViewIndex: Int, device: MTLDevice) throws -> MTLBuffer? {
        let (fullData, bufferView) = try loadBufferView(bufferViewIndex)

        // For creating an MTLBuffer, we need just the bufferView's slice
        let offset = bufferView.byteOffset ?? 0
        let length = bufferView.byteLength

        guard offset + length <= fullData.count else {
            throw VRMError.missingBuffer(
                bufferIndex: bufferView.buffer,
                requiredBy: "createMTLBuffer for bufferView \(bufferViewIndex)",
                expectedSize: offset + length,
                filePath: filePath
            )
        }

        let slicedData = fullData.subdata(in: offset..<(offset + length))
        return device.makeBuffer(
            bytes: slicedData.withUnsafeBytes { $0.baseAddress! },
            length: slicedData.count,
            options: .storageModeShared)
    }

    // Returns the entire buffer data and the bufferView for offset calculation
    private func loadBufferView(_ bufferViewIndex: Int) throws -> (
        data: Data, bufferView: GLTFBufferView
    ) {
        guard let bufferView = document.bufferViews?[safe: bufferViewIndex] else {
            throw VRMError.invalidAccessor(
                accessorIndex: bufferViewIndex,
                reason: "BufferView not found in document",
                context: "loadBufferView",
                filePath: filePath
            )
        }

        guard let buffer = document.buffers?[safe: bufferView.buffer] else {
            throw VRMError.missingBuffer(
                bufferIndex: bufferView.buffer,
                requiredBy: "loadBufferView \(bufferViewIndex)",
                expectedSize: bufferView.byteLength,
                filePath: filePath
            )
        }

        let data: Data

        if bufferView.buffer == 0, let binaryData = self.binaryData {
            // First buffer is typically the binary chunk in GLB
            data = binaryData
        } else if let uri = buffer.uri {
            // External buffer or data URI
            if uri.hasPrefix("data:") {
                // Data URI
                data = try loadDataURI(uri)
            } else {
                // External file
                data = try loadExternalBuffer(uri)
            }
        } else {
            throw VRMError.missingBuffer(
                bufferIndex: bufferView.buffer,
                requiredBy: "loadBufferView \(bufferViewIndex)",
                expectedSize: buffer.byteLength,
                filePath: filePath
            )
        }

        // Return the entire buffer data and the bufferView
        // The accessor loading functions will apply the combined offset
        return (data, bufferView)
    }

    private func loadDataURI(_ uri: String) throws -> Data {
        guard let commaIndex = uri.firstIndex(of: ",") else {
            throw VRMError.invalidJSON(
                context: "loadDataURI: Invalid data URI format",
                underlyingError: "Missing comma separator in data URI",
                filePath: filePath
            )
        }

        let base64String = String(uri[uri.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64String) else {
            throw VRMError.invalidJSON(
                context: "loadDataURI: Failed to decode base64 data",
                underlyingError: "Invalid base64 encoding in data URI",
                filePath: filePath
            )
        }

        return data
    }

    private func loadExternalBuffer(_ uri: String) throws -> Data {
        guard let baseURL = baseURL else {
            throw VRMError.invalidPath(
                path: uri,
                reason: "Cannot load external buffer without base URL",
                filePath: nil
            )
        }

        // Resolve the URI relative to the base URL
        let fileURL: URL
        if uri.hasPrefix("/") {
            // Absolute path (not recommended for portability)
            fileURL = URL(fileURLWithPath: uri)
        } else {
            // Relative path
            fileURL = baseURL.appendingPathComponent(uri)
        }

        // Security check: Ensure the resolved path is within the base directory
        let basePath = baseURL.standardized.path
        let resolvedFilePath = fileURL.standardized.path
        guard resolvedFilePath.hasPrefix(basePath) else {
            throw VRMError.invalidPath(
                path: uri,
                reason: "Security: Path resolves outside base directory (attempted path traversal)",
                filePath: filePath
            )
        }

        // Check if file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw VRMError.invalidPath(
                path: uri,
                reason: "External buffer file not found at resolved path: \(fileURL.path)",
                filePath: filePath
            )
        }

        // Load the buffer data
        do {
            let data = try Data(contentsOf: fileURL)
            return data
        } catch {
            throw VRMError.invalidPath(
                path: uri,
                reason: "Failed to load external buffer: \(error.localizedDescription)",
                filePath: filePath
            )
        }
    }

}

// MARK: - Array Safe Access

extension Array {
    subscript(safe index: Int) -> Element? {
        return index >= 0 && index < count ? self[index] : nil
    }
}
