//
// TextureLoader.swift
// NeuraLink
//
// Created by Dedicatus on 15/04/2026.
//

import CoreGraphics
import Foundation
import ImageIO
import Metal
import MetalKit

public class TextureLoader {
    private let device: MTLDevice
    private let textureLoader: MTKTextureLoader
    private let bufferLoader: BufferLoader
    private let document: GLTFDocument
    private let baseURL: URL?
    private lazy var mipmapCommandQueue: MTLCommandQueue? = device.makeCommandQueue()
    /// Mip blits committed by `loadTexture`; see `waitForMipmaps`.
    private let mipmapWork = MipmapWork()

    public init(
        device: MTLDevice, bufferLoader: BufferLoader, document: GLTFDocument, baseURL: URL? = nil
    ) {
        self.device = device
        self.textureLoader = MTKTextureLoader(device: device)
        self.bufferLoader = bufferLoader
        self.document = document
        self.baseURL = baseURL
    }

    /// Blocks until every mip chain this loader started is generated. Call
    /// once after the last `loadTexture(withMipmaps: true)`, before drawing.
    public func waitForMipmaps() {
        mipmapWork.wait()
    }

    /// Load a texture at the given index
    /// - Parameters:
    ///   - index: The texture index in the glTF document
    ///   - sRGB: If true, texture is treated as sRGB color data (default). If false, treated as linear data (normal maps, etc.)
    public func loadTexture(at index: Int, sRGB: Bool = true, maxSize: Int = Int.max, withMipmaps: Bool = false) async throws -> MTLTexture? {
        guard let gltfTexture = document.textures?[safe: index] else {
            nlLog("[TextureLoader] Warning: No texture at index \(index)")
            return nil
        }

        guard let sourceIndex = gltfTexture.source else {
            nlLog("[TextureLoader] Warning: Texture \(index) has no source")
            return nil
        }

        guard let images = document.images, sourceIndex < images.count else {
            nlLog(
                "[TextureLoader] Error: Source index \(sourceIndex) out of bounds for images array (count: \(document.images?.count ?? 0))"
            )
            return nil
        }

        let image = images[sourceIndex]

        // Load image data
        let imageData: Data

        if let bufferViewIndex = image.bufferView {
            // Image is embedded in buffer
            imageData = try loadImageFromBufferView(bufferViewIndex, textureIndex: index)
        } else if let uri = image.uri {
            if uri.hasPrefix("data:") {
                // Data URI
                imageData = try loadImageFromDataURI(uri, textureIndex: index)
            } else {
                // External file
                imageData = try loadImageFromExternalFile(uri, textureIndex: index)
            }
        } else {
            return nil
        }

        // Create texture from image data
        return try await createTexture(
            from: imageData, mimeType: image.mimeType, textureIndex: index, sRGB: sRGB,
            maxSize: maxSize, withMipmaps: withMipmaps)
    }

    private func loadImageFromBufferView(_ bufferViewIndex: Int, textureIndex: Int) throws -> Data {
        guard let bufferView = document.bufferViews?[safe: bufferViewIndex],
            document.buffers?[safe: bufferView.buffer] != nil
        else {
            throw VRMError.missingBuffer(
                bufferIndex: bufferViewIndex,
                requiredBy: "texture[\(textureIndex)] loading from bufferView",
                expectedSize: nil,
                filePath: baseURL?.path
            )
        }

        // Get binary data from buffer loader
        let bufferData = try bufferLoader.getBufferData(bufferIndex: bufferView.buffer)

        let offset = bufferView.byteOffset ?? 0
        let length = bufferView.byteLength

        guard offset + length <= bufferData.count else {
            throw VRMError.missingBuffer(
                bufferIndex: bufferView.buffer,
                requiredBy:
                    "texture[\(textureIndex)] buffer data validation (offset: \(offset), length: \(length), available: \(bufferData.count))",
                expectedSize: offset + length,
                filePath: baseURL?.path
            )
        }

        return bufferData.subdata(in: offset..<(offset + length))
    }

    private func loadImageFromDataURI(_ uri: String, textureIndex: Int) throws -> Data {
        guard let commaIndex = uri.firstIndex(of: ",") else {
            throw VRMError.invalidImageData(
                textureIndex: textureIndex,
                reason: "Data URI missing comma separator in '\(uri.prefix(50))...'",
                filePath: baseURL?.path
            )
        }

        let base64String = String(uri[uri.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64String) else {
            throw VRMError.invalidImageData(
                textureIndex: textureIndex,
                reason: "Failed to decode base64 data from URI",
                filePath: baseURL?.path
            )
        }

        return data
    }

    private func loadImageFromExternalFile(_ uri: String, textureIndex: Int) throws -> Data {
        guard let baseURL = baseURL else {
            nlLog("[TextureLoader] Warning: Cannot load external file without base URL: \(uri)")
            throw VRMError.missingTexture(
                textureIndex: textureIndex,
                materialName: nil,
                uri: uri,
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
        let filePath = fileURL.standardized.path
        guard filePath.hasPrefix(basePath) else {
            nlLog("[TextureLoader] Security: Refusing to load file outside base directory: \(uri)")
            throw VRMError.invalidPath(
                path: uri,
                reason:
                    "texture[\(textureIndex)]: Path resolves outside base directory (security violation)",
                filePath: baseURL.path
            )
        }

        // Check if file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            nlLog("[TextureLoader] Warning: External image file not found: \(fileURL.path)")
            throw VRMError.missingTexture(
                textureIndex: textureIndex,
                materialName: nil,
                uri: uri,
                filePath: baseURL.path
            )
        }

        // Load the image data
        do {
            let data = try Data(contentsOf: fileURL)
            nlLog("[TextureLoader] Loaded external image: \(uri) (\(data.count) bytes)")
            return data
        } catch {
            nlLog("[TextureLoader] Error loading external image: \(error)")
            throw VRMError.invalidImageData(
                textureIndex: textureIndex,
                reason:
                    "Failed to read external image file '\(uri)': \(error.localizedDescription)",
                filePath: baseURL.path
            )
        }
    }

    private func createTexture(
        from imageData: Data, mimeType: String?, textureIndex: Int, sRGB: Bool,
        maxSize: Int = Int.max, withMipmaps: Bool = false
    ) async throws -> MTLTexture? {
        // Straight alpha + optional mips (TextureUploader); MTKTextureLoader
        // only for formats neither decoder reads.
        if let texture = TextureUploader.makeTexture(
            device: device, imageData: imageData, sRGB: sRGB, maxSize: maxSize,
            withMipmaps: withMipmaps, commandQueue: mipmapCommandQueue, pending: mipmapWork) {
            return texture
        }

        // Fallback to MTKTextureLoader if CGImage fails (but this might crash in async context)
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue,
            .SRGB: sRGB
        ]

        do {
            let texture = try await textureLoader.newTexture(data: imageData, options: options)
            return texture
        } catch {
            nlLog("[TextureLoader] Failed to create texture: \(error)")
            throw VRMError.invalidImageData(
                textureIndex: textureIndex,
                reason:
                    "Failed to create Metal texture from image data (mimeType: \(mimeType ?? "unknown")): \(error.localizedDescription)",
                filePath: baseURL?.path
            )
        }
    }
}
