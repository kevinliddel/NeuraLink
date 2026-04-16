//
// ParallelTextureLoader.swift
// NeuraLink
//
// Created by Dedicatus on 15/04/2026.
//

@preconcurrency import Foundation
@preconcurrency import Metal
@preconcurrency import MetalKit

/// High-performance parallel texture loader with optimization support.
public final class ParallelTextureLoader: @unchecked Sendable {
    private let device: MTLDevice
    private let textureLoader: MTKTextureLoader
    private let bufferLoader: BufferLoader
    private let document: GLTFDocument
    private let baseURL: URL?

    private let maxConcurrentLoads: Int

    public init(
        device: MTLDevice,
        bufferLoader: BufferLoader,
        document: GLTFDocument,
        baseURL: URL? = nil,
        maxConcurrentLoads: Int = 4
    ) {
        self.device = device
        self.textureLoader = MTKTextureLoader(device: device)
        self.bufferLoader = bufferLoader
        self.document = document
        self.baseURL = baseURL
        self.maxConcurrentLoads = maxConcurrentLoads
    }

    /// Load all textures in parallel using TaskGroup.
    public func loadTexturesParallel(
        indices: [Int],
        normalMapIndices: Set<Int>,
        progressCallback: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [Int: MTLTexture] {
        // Use unchecked sendable wrapper for results
        let results = UncheckedTextureDictionary()
        let totalCount = indices.count
        let progressBox = UncheckedProgressBox()

        // Process textures concurrently using TaskGroup
        await withTaskGroup(of: Void.self) { group in
            for textureIndex in indices {
                group.addTask { [unowned self] in
                    let isNormalMap = normalMapIndices.contains(textureIndex)
                    let texture = try? await self.loadTexture(at: textureIndex, sRGB: !isNormalMap)

                    if let texture = texture {
                        results.set(texture, for: textureIndex)
                    }

                    progressBox.increment()
                    let current = progressBox.countValue
                    await MainActor.run {
                        progressCallback?(current, totalCount)
                    }
                }
            }

            await group.waitForAll()
        }

        return results.getAll()
    }

    private func loadTexture(at index: Int, sRGB: Bool = true) async throws -> MTLTexture? {
        guard let gltfTexture = document.textures?[safe: index],
            let sourceIndex = gltfTexture.source,
            let images = document.images,
            sourceIndex < images.count
        else {
            return nil
        }

        let image = images[sourceIndex]

        let imageData: Data
        if let bufferViewIndex = image.bufferView {
            imageData = try loadImageFromBufferView(bufferViewIndex, textureIndex: index)
        } else if let uri = image.uri {
            if uri.hasPrefix("data:") {
                imageData = try loadImageFromDataURI(uri, textureIndex: index)
            } else {
                imageData = try loadImageFromExternalFile(uri, textureIndex: index)
            }
        } else {
            return nil
        }

        return try await createTexture(from: imageData, textureIndex: index, sRGB: sRGB)
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

        let bufferData = try bufferLoader.getBufferData(bufferIndex: bufferView.buffer)
        let offset = bufferView.byteOffset ?? 0
        let length = bufferView.byteLength

        guard offset + length <= bufferData.count else {
            throw VRMError.missingBuffer(
                bufferIndex: bufferView.buffer,
                requiredBy: "texture[\(textureIndex)] buffer data validation",
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
                reason: "Data URI missing comma separator",
                filePath: baseURL?.path
            )
        }

        let base64String = String(uri[uri.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64String) else {
            throw VRMError.invalidImageData(
                textureIndex: textureIndex,
                reason: "Failed to decode base64 data",
                filePath: baseURL?.path
            )
        }

        return data
    }

    private func loadImageFromExternalFile(_ uri: String, textureIndex: Int) throws -> Data {
        guard let baseURL = baseURL else {
            throw VRMError.missingTexture(
                textureIndex: textureIndex,
                materialName: nil,
                uri: uri,
                filePath: nil
            )
        }

        let fileURL =
            uri.hasPrefix("/") ? URL(fileURLWithPath: uri) : baseURL.appendingPathComponent(uri)

        let basePath = baseURL.standardized.path
        let filePath = fileURL.standardized.path
        guard filePath.hasPrefix(basePath) else {
            throw VRMError.invalidPath(
                path: uri,
                reason: "Path resolves outside base directory",
                filePath: baseURL.path
            )
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw VRMError.missingTexture(
                textureIndex: textureIndex,
                materialName: nil,
                uri: uri,
                filePath: baseURL.path
            )
        }

        return try Data(contentsOf: fileURL)
    }

    private func createTexture(from imageData: Data, textureIndex: Int, sRGB: Bool) async throws
        -> MTLTexture?
    {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            throw VRMError.invalidImageData(
                textureIndex: textureIndex,
                reason: "Failed to decode image data",
                filePath: baseURL?.path
            )
        }

        let width = cgImage.width
        let height = cgImage.height
        let pixelFormat: MTLPixelFormat = sRGB ? .rgba8Unorm_srgb : .rgba8Unorm

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead]
        textureDescriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            return nil
        }

        let bytesPerRow = width * 4
        guard let bitmapData = malloc(height * bytesPerRow) else {
            return nil
        }
        defer { free(bitmapData) }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: bitmapData,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        context.setBlendMode(.copy)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: bitmapData,
            bytesPerRow: bytesPerRow
        )

        return texture
    }
}

// MARK: - Helper Types

/// Thread-safe dictionary for texture results
private final class UncheckedTextureDictionary: @unchecked Sendable {
    private var dict: [Int: MTLTexture] = [:]
    private let lock = NSLock()

    func set(_ texture: MTLTexture, for index: Int) {
        lock.lock()
        dict[index] = texture
        lock.unlock()
    }

    func getAll() -> [Int: MTLTexture] {
        lock.lock()
        defer { lock.unlock() }
        return dict
    }
}

/// Thread-safe progress counter
private final class UncheckedProgressBox: @unchecked Sendable {
    private var count: Int = 0
    private let lock = NSLock()

    var countValue: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
