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

    public init(
        device: MTLDevice, bufferLoader: BufferLoader, document: GLTFDocument, baseURL: URL? = nil
    ) {
        self.device = device
        self.textureLoader = MTKTextureLoader(device: device)
        self.bufferLoader = bufferLoader
        self.document = document
        self.baseURL = baseURL
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
        // Try using CGImage directly to avoid MTKTextureLoader async crash
        if let cgImage = createCGImage(from: imageData) {
            do {
                let texture = try createTexture(
                    from: cgImage, textureIndex: textureIndex, sRGB: sRGB, maxSize: maxSize,
                    withMipmaps: withMipmaps)
                return texture
            } catch {
                nlLog("[TextureLoader] Failed to create texture from CGImage: \(error)")
            }
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

    private func createCGImage(from data: Data) -> CGImage? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else {
            return nil
        }
        return cgImage
    }

    private func createTexture(from cgImage: CGImage, textureIndex: Int, sRGB: Bool,
                               maxSize: Int = Int.max, withMipmaps: Bool = false) throws -> MTLTexture? {
        nlLog("[TextureLoader] createTexture(from CGImage) called, sRGB=\(sRGB)")

        // MTKTextureLoader seems to crash when called from background async context
        // Let's create the texture manually instead

        nlLog("[TextureLoader] Getting image dimensions...")
        let srcWidth = cgImage.width
        let srcHeight = cgImage.height

        // Downscale if a maxSize cap is set (e.g. 1024 for background environment meshes).
        let scale = maxSize < Int.max ? min(1.0, Double(maxSize) / Double(max(srcWidth, srcHeight))) : 1.0
        let width  = max(1, Int(Double(srcWidth)  * scale))
        let height = max(1, Int(Double(srcHeight) * scale))
        if scale < 1.0 {
            nlLog("[TextureLoader] Downscaled \(srcWidth)x\(srcHeight) → \(width)x\(height)")
        }
        nlLog("[TextureLoader] Image size: \(width)x\(height)")

        nlLog("[TextureLoader] Creating texture descriptor...")
        let pixelFormat: MTLPixelFormat = sRGB ? .rgba8Unorm_srgb : .rgba8Unorm

        // Upload to a shared staging texture (CPU-writable)
        let stagingDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        stagingDesc.usage       = [.shaderRead]
        stagingDesc.storageMode = .shared

        nlLog("[TextureLoader] Creating Metal texture...")
        guard let stagingTexture = device.makeTexture(descriptor: stagingDesc) else {
            nlLog("[TextureLoader] Failed to create staging texture")
            return nil
        }
        nlLog("[TextureLoader] Metal texture created")

        // Pass data:nil and bytesPerRow:0 so CG allocates its own buffer with the alignment
        // vImage requires. When we provide our own malloc'd buffer CG's internal vImage
        // scaling path fires an alignment assertion for any non-identity scale factor.
        nlLog("[TextureLoader] Creating CGContext...")
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,   // 0 = CG chooses optimal (aligned) stride
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            nlLog("[TextureLoader] Failed to create bitmap context")
            return nil
        }
        nlLog("[TextureLoader] CGContext created")

        nlLog("[TextureLoader] Drawing image to context...")
        context.setBlendMode(.copy)
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        nlLog("[TextureLoader] Image drawn")

        guard let bitmapData = context.data else {
            nlLog("[TextureLoader] CGContext has no backing data")
            return nil
        }
        let bytesPerRow = context.bytesPerRow

        nlLog("[TextureLoader] Replacing texture data...")
        stagingTexture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: bitmapData,
            bytesPerRow: bytesPerRow
        )
        nlLog("[TextureLoader] Texture data replaced")

        // Mipmap path: blit staging → private mipmapped texture, then generate all mip levels.
        // Requires .renderTarget usage on the private texture (Metal requirement for generateMipmaps).
        if withMipmaps,
           let cmdQueue = mipmapCommandQueue,
           let cmdBuf   = cmdQueue.makeCommandBuffer() {
            let mipDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat, width: width, height: height, mipmapped: true)
            mipDesc.usage       = [.shaderRead, .renderTarget]
            mipDesc.storageMode = .private
            if let mipTex = device.makeTexture(descriptor: mipDesc),
               let blit   = cmdBuf.makeBlitCommandEncoder() {
                blit.copy(from: stagingTexture,
                          sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: width, height: height, depth: 1),
                          to: mipTex,
                          destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                blit.generateMipmaps(for: mipTex)
                blit.endEncoding()
                cmdBuf.commit()
                cmdBuf.waitUntilCompleted()
                nlLog("[TextureLoader] Mipmaps generated (\(mipTex.mipmapLevelCount) levels)")
                return mipTex
            }
        }

        // DEBUG: Sample first pixel to check for extreme values
        #if DEBUG
            let firstPixel = bitmapData.assumingMemoryBound(to: UInt8.self)
            let r = Float(firstPixel[0]) / 255.0
            let g = Float(firstPixel[1]) / 255.0
            let b = Float(firstPixel[2]) / 255.0
            let a = Float(firstPixel[3]) / 255.0
            nlLog(
                "[TextureLoader] First pixel RGBA: (\(String(format: "%.3f", r)), \(String(format: "%.3f", g)), \(String(format: "%.3f", b)), \(String(format: "%.3f", a)))"
            )
            if r > 1.0 || g > 1.0 || b > 1.0 {
                nlLog("  ⚠️ WARNING: Pixel values exceed 1.0!")
            }
        #endif

        nlLog("[TextureLoader] Texture created successfully")
        return stagingTexture
    }

    public func createSampler(from gltfSampler: GLTFSampler?) -> MTLSamplerState? {
        let descriptor = MTLSamplerDescriptor()

        if let sampler = gltfSampler {
            // Min filter
            switch sampler.minFilter {
            case 9728:  // NEAREST
                descriptor.minFilter = .nearest
                descriptor.mipFilter = .notMipmapped
            case 9729:  // LINEAR
                descriptor.minFilter = .linear
                descriptor.mipFilter = .notMipmapped
            case 9984:  // NEAREST_MIPMAP_NEAREST
                descriptor.minFilter = .nearest
                descriptor.mipFilter = .nearest
            case 9985:  // LINEAR_MIPMAP_NEAREST
                descriptor.minFilter = .linear
                descriptor.mipFilter = .nearest
            case 9986:  // NEAREST_MIPMAP_LINEAR
                descriptor.minFilter = .nearest
                descriptor.mipFilter = .linear
            case 9987:  // LINEAR_MIPMAP_LINEAR
                descriptor.minFilter = .linear
                descriptor.mipFilter = .linear
            default:
                descriptor.minFilter = .linear
                descriptor.mipFilter = .linear
            }

            // Mag filter
            switch sampler.magFilter {
            case 9728:  // NEAREST
                descriptor.magFilter = .nearest
            case 9729:  // LINEAR
                descriptor.magFilter = .linear
            default:
                descriptor.magFilter = .linear
            }

            // Wrap S
            switch sampler.wrapS {
            case 33071:  // CLAMP_TO_EDGE
                descriptor.sAddressMode = .clampToEdge
            case 33648:  // MIRRORED_REPEAT
                descriptor.sAddressMode = .mirrorRepeat
            case 10497:  // REPEAT
                descriptor.sAddressMode = .repeat
            default:
                descriptor.sAddressMode = .repeat
            }

            // Wrap T
            switch sampler.wrapT {
            case 33071:  // CLAMP_TO_EDGE
                descriptor.tAddressMode = .clampToEdge
            case 33648:  // MIRRORED_REPEAT
                descriptor.tAddressMode = .mirrorRepeat
            case 10497:  // REPEAT
                descriptor.tAddressMode = .repeat
            default:
                descriptor.tAddressMode = .repeat
            }
        } else {
            // Default sampler settings
            descriptor.minFilter = .linear
            descriptor.magFilter = .linear
            descriptor.mipFilter = .linear
            descriptor.sAddressMode = .repeat
            descriptor.tAddressMode = .repeat
        }

        descriptor.maxAnisotropy = 16
        descriptor.normalizedCoordinates = true

        return device.makeSamplerState(descriptor: descriptor)
    }
}
