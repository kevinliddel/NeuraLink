//
//  TreeRenderer.swift
//  NeuraLink
//
//  Created by Dedicatus on 07/05/2026.
//

import Foundation
import Metal
import simd

// MARK: - Vertex / uniform layouts (must mirror TreeShader.metal)

struct TreeVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var texCoord: SIMD2<Float>
}

struct TreeUniforms {
    var viewProjection: simd_float4x4
    var lightViewProjection: simd_float4x4
    var sunDirection: SIMD4<Float>
    var treeParams: SIMD4<Float>
}

struct TreeShadowUniforms {
    var lightViewProjection: simd_float4x4
}

// MARK: - Per-primitive container

private struct TreeMeshGroup {
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    let indexType: MTLIndexType
    let texture: MTLTexture?
    let baseColorFactor: SIMD4<Float>
}

// MARK: - TreeRenderer

final class TreeRenderer: @unchecked Sendable {

    private let device: MTLDevice
    private var meshGroups: [TreeMeshGroup] = []
    private var instanceBuffer: MTLBuffer?
    private var instanceCount: Int = 0
    private var fallbackTexture: MTLTexture?

    private var mainPipeline: MTLRenderPipelineState?
    private var shadowPipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var uniformsBuffer: MTLBuffer?
    private var shadowUniformsBuffer: MTLBuffer?

    private var isReady = false

    // Instance configs passed at init time; nil = use class default.
    typealias InstanceConfig = (x: Float, z: Float, rotY: Float, scale: Float)
    private let customConfigs: [InstanceConfig]?

    // Default tree layout — 12 trees spread close / mid / far / screen-edge.
    // Scale grows with distance so trees maintain visual presence.
    static let defaultTreeConfigs: [InstanceConfig] = [
        // close  (4–6 m)
        (x: -2.5, z: -4.5, rotY: 0.30, scale: 0.13),
        (x: 3.5, z: -5.0, rotY: 1.10, scale: 0.14),
        // mid    (9–13 m)
        (x: -8.5, z: -9.5, rotY: 2.30, scale: 0.17),
        (x: 9.0, z: -8.5, rotY: 0.80, scale: 0.16),
        // far    (17–22 m)
        (x: -6.0, z: -18.0, rotY: 1.70, scale: 0.22),
        (x: 7.5, z: -20.0, rotY: 3.00, scale: 0.21),
        // deep background (28–35 m)
        (x: -3.5, z: -30.0, rotY: 2.80, scale: 0.28),
        (x: 5.0, z: -32.0, rotY: 0.50, scale: 0.26),
        // screen edges — wide x, varying depth
        (x: -17.0, z: -10.0, rotY: 1.40, scale: 0.20),
        (x: 16.5, z: -12.0, rotY: 2.60, scale: 0.19),
        (x: -13.0, z: -24.0, rotY: 0.90, scale: 0.25),
        (x: 14.0, z: -22.0, rotY: 3.40, scale: 0.24)
    ]

    // Default grass layout — 15 small patches scattered around the scene.
    static let defaultGrassConfigs: [InstanceConfig] = [
        (x: -1.5, z: -2.5, rotY: 0.50, scale: 0.005),
        (x: 2.5, z: -2.0, rotY: 1.80, scale: 0.004),
        (x: -3.5, z: -4.5, rotY: 2.50, scale: 0.005),
        (x: 5.0, z: -3.8, rotY: 0.20, scale: 0.004),
        (x: -1.0, z: -6.0, rotY: 3.10, scale: 0.004),
        (x: 4.0, z: -6.5, rotY: 1.50, scale: 0.005),
        (x: -6.0, z: -5.5, rotY: 0.90, scale: 0.005),
        (x: 6.5, z: -6.0, rotY: 2.70, scale: 0.004),
        (x: -2.5, z: -9.0, rotY: 1.20, scale: 0.006),
        (x: 4.5, z: -9.5, rotY: 3.50, scale: 0.005),
        (x: -8.0, z: -8.0, rotY: 0.70, scale: 0.005),
        (x: 8.5, z: -8.5, rotY: 2.10, scale: 0.004),
        (x: -4.5, z: -13.0, rotY: 1.90, scale: 0.006),
        (x: 6.0, z: -12.0, rotY: 0.40, scale: 0.005),
        (x: 0.5, z: -3.0, rotY: 2.80, scale: 0.004)
    ]

    init(device: MTLDevice, instanceConfigs: [InstanceConfig]? = nil) {
        self.device = device
        self.customConfigs = instanceConfigs
    }

    // MARK: - Setup (synchronous, called on init path)

    func setup(config: RendererConfig) {
        setupDepthState()
        setupPipelines(config: config)
        setupUniformBuffers()
        setupInstanceBuffer()
        setupFallbackTexture()
    }

    // MARK: - Async load

    func load(url: URL) async throws {
        let data = try Data(contentsOf: url)
        let (document, binary) = try GLTFParser().parse(data: data)
        let baseURL = url.deletingLastPathComponent()
        let bufLoader = BufferLoader(document: document, binaryData: binary, baseURL: baseURL)
        let texLoader = TextureLoader(
            device: device, bufferLoader: bufLoader, document: document, baseURL: baseURL)

        var groups: [TreeMeshGroup] = []

        for mesh in document.meshes ?? [] {
            for primitive in mesh.primitives {
                guard let posIdx = primitive.attributes["POSITION"],
                    let idxIdx = primitive.indices
                else { continue }

                let posF = try bufLoader.loadAccessorAsFloat(posIdx)
                let vertCount = posF.count / 3

                var norF: [Float] = Array(repeating: 0, count: vertCount * 3)
                if let i = primitive.attributes["NORMAL"] {
                    norF = try bufLoader.loadAccessorAsFloat(i)
                }
                var texF: [Float] = Array(repeating: 0, count: vertCount * 2)
                if let i = primitive.attributes["TEXCOORD_0"] {
                    texF = try bufLoader.loadAccessorAsFloat(i)
                }

                var vertices = [TreeVertex](
                    repeating: TreeVertex(position: .zero, normal: [0, 1, 0], texCoord: .zero),
                    count: vertCount)
                for i in 0..<vertCount {
                    vertices[i] = TreeVertex(
                        position: SIMD3<Float>(posF[i*3], posF[i*3+1], posF[i*3+2]),
                        normal: SIMD3<Float>(norF[i*3], norF[i*3+1], norF[i*3+2]),
                        texCoord: SIMD2<Float>(texF[i*2], texF[i*2+1])
                    )
                }

                let indices = try bufLoader.loadAccessorAsUInt32(idxIdx)

                guard let vb = device.makeBuffer(
                    bytes: vertices,
                    length: MemoryLayout<TreeVertex>.stride * vertices.count,
                    options: .storageModeShared),
                    let ib = device.makeBuffer(
                        bytes: indices,
                        length: MemoryLayout<UInt32>.stride * indices.count,
                        options: .storageModeShared)
                else { continue }

                vb.label = "Tree_VB_\(groups.count)"
                ib.label = "Tree_IB_\(groups.count)"

                var texture: MTLTexture? = nil
                var baseColorFactor = SIMD4<Float>(1, 1, 1, 1)

                if let matIdx = primitive.material,
                    let mat = document.materials?[safe: matIdx] {
                    // Read base color factor (default white [1,1,1,1] per glTF spec)
                    if let f = mat.pbrMetallicRoughness?.baseColorFactor, f.count >= 4 {
                        baseColorFactor = SIMD4<Float>(f[0], f[1], f[2], f[3])
                    }

                    // Load base color texture if present
                    if let texIdx = mat.pbrMetallicRoughness?.baseColorTexture?.index {
                        do {
                            texture = try await texLoader.loadTexture(at: texIdx, sRGB: true)
                        } catch {
                            vrmLog("[TreeRenderer] Texture \(texIdx) load error: \(error), using fallback")
                        }
                    }
                }

                groups.append(TreeMeshGroup(
                    vertexBuffer: vb,
                    indexBuffer: ib,
                    indexCount: indices.count,
                    indexType: .uint32,
                    texture: texture,
                    baseColorFactor: baseColorFactor
                ))
            }
        }

        meshGroups = groups
        isReady = !groups.isEmpty
        vrmLog("[TreeRenderer] Loaded \(groups.count) mesh group(s) from tree.glb")
    }

    // MARK: - Shadow pass (depth-only, loadAction controlled by caller)

    func drawShadow(
        commandBuffer: MTLCommandBuffer,
        shadowMap: MTLTexture,
        lightViewProjection: simd_float4x4,
        clearFirst: Bool
    ) {
        guard isReady,
            let pipeline = shadowPipeline,
            let ds = depthState,
            let instanceBuf = instanceBuffer,
            let shadowUniBuf = shadowUniformsBuffer
        else { return }

        var su = TreeShadowUniforms(lightViewProjection: lightViewProjection)
        shadowUniBuf.contents().copyMemory(from: &su, byteCount: MemoryLayout<TreeShadowUniforms>.stride)

        let passDesc = MTLRenderPassDescriptor()
        passDesc.depthAttachment.texture = shadowMap
        passDesc.depthAttachment.loadAction = clearFirst ? .clear : .load
        passDesc.depthAttachment.storeAction = .store
        passDesc.depthAttachment.clearDepth = 1.0

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }
        encoder.label = "TreeShadowPass"
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(ds)
        encoder.setCullMode(.none)
        encoder.setDepthBias(0.0, slopeScale: 2.0, clamp: 0.005)
        encoder.setVertexBuffer(shadowUniBuf, offset: 0, index: 1)
        encoder.setVertexBuffer(instanceBuf, offset: 0, index: 2)

        for group in meshGroups {
            encoder.setVertexBuffer(group.vertexBuffer, offset: 0, index: 0)
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: group.indexCount,
                indexType: group.indexType,
                indexBuffer: group.indexBuffer,
                indexBufferOffset: 0,
                instanceCount: instanceCount
            )
        }
        encoder.endEncoding()
    }

    // MARK: - Main draw (inside main render encoder)

    func draw(
        encoder: MTLRenderCommandEncoder,
        viewProjection: simd_float4x4,
        lightViewProjection: simd_float4x4,
        sunDirection: SIMD3<Float>,
        sunHeight: Float,
        shadowSoft: Float,
        shadowMap: MTLTexture,
        shadowSampler: MTLSamplerState
    ) {
        guard isReady,
            let pipeline = mainPipeline,
            let ds = depthState,
            let instanceBuf = instanceBuffer,
            let uniBuf = uniformsBuffer
        else { return }

        var u = TreeUniforms(
            viewProjection: viewProjection,
            lightViewProjection: lightViewProjection,
            sunDirection: SIMD4<Float>(sunDirection.x, sunDirection.y, sunDirection.z, sunHeight),
            treeParams: SIMD4<Float>(shadowSoft, 0, 0, 0)
        )
        uniBuf.contents().copyMemory(from: &u, byteCount: MemoryLayout<TreeUniforms>.stride)

        encoder.pushDebugGroup("Trees")
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(ds)
        encoder.setCullMode(.none)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setVertexBuffer(uniBuf, offset: 0, index: 1)
        encoder.setVertexBuffer(instanceBuf, offset: 0, index: 2)
        encoder.setFragmentBuffer(uniBuf, offset: 0, index: 1)
        encoder.setFragmentTexture(shadowMap, index: 1)
        encoder.setFragmentSamplerState(shadowSampler, index: 0)

        for group in meshGroups {
            var factor = group.baseColorFactor
            encoder.setVertexBuffer(group.vertexBuffer, offset: 0, index: 0)
            encoder.setFragmentBytes(&factor, length: MemoryLayout<SIMD4<Float>>.size, index: 2)
            encoder.setFragmentTexture(group.texture ?? fallbackTexture, index: 0)
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: group.indexCount,
                indexType: group.indexType,
                indexBuffer: group.indexBuffer,
                indexBufferOffset: 0,
                instanceCount: instanceCount
            )
        }
        encoder.popDebugGroup()
    }

    // MARK: - Private setup

    private func setupDepthState() {
        let desc = MTLDepthStencilDescriptor()
        desc.depthCompareFunction = .less
        desc.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: desc)
    }

    private func setupPipelines(config: RendererConfig) {
        guard let lib = try? VRMPipelineCache.shared.getLibrary(device: device),
            let shadowVert = lib.makeFunction(name: "tree_shadow_vertex"),
            let mainVert = lib.makeFunction(name: "tree_vertex"),
            let mainFrag = lib.makeFunction(name: "tree_fragment")
        else {
            vrmLog("[TreeRenderer] Shader functions not found in library")
            return
        }

        let posOff = MemoryLayout<TreeVertex>.offset(of: \.position)!
        let norOff = MemoryLayout<TreeVertex>.offset(of: \.normal)!
        let texOff = MemoryLayout<TreeVertex>.offset(of: \.texCoord)!
        let stride = MemoryLayout<TreeVertex>.stride

        // Full vertex descriptor (used by main pipeline + shadow pipeline)
        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3
        vd.attributes[0].offset = posOff
        vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float3
        vd.attributes[1].offset = norOff
        vd.attributes[1].bufferIndex = 0
        vd.attributes[2].format = .float2
        vd.attributes[2].offset = texOff
        vd.attributes[2].bufferIndex = 0
        vd.layouts[0].stride = stride

        // Shadow: position-only vertex descriptor
        let shadowVD = MTLVertexDescriptor()
        shadowVD.attributes[0].format = .float3
        shadowVD.attributes[0].offset = posOff
        shadowVD.attributes[0].bufferIndex = 0
        shadowVD.layouts[0].stride = stride

        let shadowDesc = MTLRenderPipelineDescriptor()
        shadowDesc.label = "tree_shadow"
        shadowDesc.vertexFunction = shadowVert
        shadowDesc.vertexDescriptor = shadowVD
        shadowDesc.depthAttachmentPixelFormat = .depth32Float

        let mainDesc = MTLRenderPipelineDescriptor()
        mainDesc.label = "tree_main"
        mainDesc.vertexFunction = mainVert
        mainDesc.fragmentFunction = mainFrag
        mainDesc.vertexDescriptor = vd
        mainDesc.colorAttachments[0].pixelFormat = config.colorPixelFormat
        mainDesc.colorAttachments[0].isBlendingEnabled = false
        mainDesc.depthAttachmentPixelFormat = .depth32Float
        mainDesc.rasterSampleCount = config.sampleCount

        do {
            shadowPipeline = try VRMPipelineCache.shared.getPipelineState(
                device: device, descriptor: shadowDesc, key: "tree_shadow")
            mainPipeline = try VRMPipelineCache.shared.getPipelineState(
                device: device, descriptor: mainDesc, key: "tree_main")
        } catch {
            vrmLog("[TreeRenderer] Pipeline creation failed: \(error)")
        }
    }

    private func setupUniformBuffers() {
        uniformsBuffer = device.makeBuffer(
            length: MemoryLayout<TreeUniforms>.stride, options: .storageModeShared)
        uniformsBuffer?.label = "TreeUniforms"
        shadowUniformsBuffer = device.makeBuffer(
            length: MemoryLayout<TreeShadowUniforms>.stride, options: .storageModeShared)
        shadowUniformsBuffer?.label = "TreeShadowUniforms"
    }

    private func setupFallbackTexture() {
        // Olive-green 1×1 fallback used when GLB texture fails to load
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        var pixel: UInt32 = 0xFF4A6625  // RGBA: R=37, G=102, B=74, A=255 (forest green)
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
        fallbackTexture = tex
    }

    private func setupInstanceBuffer() {
        let configs = customConfigs ?? Self.defaultTreeConfigs
        let transforms = Self.makeTransforms(from: configs)
        instanceCount = transforms.count
        instanceBuffer = device.makeBuffer(
            bytes: transforms,
            length: MemoryLayout<simd_float4x4>.stride * transforms.count,
            options: .storageModeShared)
        instanceBuffer?.label = "MeshInstances"
    }

    private static func makeTransforms(from configs: [InstanceConfig]) -> [simd_float4x4] {
        configs.map { c in
            let s = c.scale
            let S = simd_float4x4(diagonal: SIMD4<Float>(s, s, s, 1))
            let R = simd_float4x4(simd_quatf(angle: c.rotY, axis: [0, 1, 0]))
            var T = matrix_identity_float4x4
            T[3] = SIMD4<Float>(c.x, 0, c.z, 1)
            return T * R * S
        }
    }
}
