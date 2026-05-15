//
//  CampusRenderer+Load.swift
//  NeuraLink
//
//  Created by Antigravity on 10/05/2026.
//

import Foundation
import Metal
import simd

extension CampusRenderer {

    // MARK: - Setup

    func setup(config: RendererConfig) {
        setupDepthState()
        setupPipelines(config: config)
        setupUniformBuffers()
        setupFallbackTexture()
    }

    // MARK: - Async load

    @inline(__always) private func f2(_ v: Float) -> String { String(format: "%.2f", v) }
    @inline(__always) private func f3(_ v: Float) -> String { String(format: "%.3f", v) }

    func load(url: URL) async throws {
        let data = try Data(contentsOf: url)
        let (document, binary) = try GLTFParser().parse(data: data)
        let baseURL = url.deletingLastPathComponent()
        let bufLoader = BufferLoader(document: document, binaryData: binary, baseURL: baseURL)
        let texLoader = TextureLoader(
            device: device, bufferLoader: bufLoader, document: document, baseURL: baseURL)

        let s = instanceConfig.scale
        let S = simd_float4x4(diagonal: SIMD4<Float>(s, s, s, 1))
        let R = simd_float4x4(simd_quatf(angle: instanceConfig.rotY, axis: [0, 1, 0]))
        var T = matrix_identity_float4x4
        T[3] = SIMD4<Float>(instanceConfig.x, instanceConfig.y, instanceConfig.z, 1)
        let instanceTransform = T * R * S

        var meshInstances: [(meshIndex: Int, worldTransform: simd_float4x4)] = []
        let sceneIndex = document.scene ?? 0
        for ni in document.scenes?[safe: sceneIndex]?.nodes ?? [] {
            collectMeshInstances(
                nodeIndex: ni, parentTransform: instanceTransform,
                document: document, into: &meshInstances)
        }

        vrmLog(
            "[CampusRenderer] Scene graph: \(meshInstances.count) mesh instance(s) across all nodes"
        )

        var textureCache: [Int: MTLTexture] = [:]
        var groups: [CampusMeshGroup] = []

        for (meshIndex, worldTransform) in meshInstances {
            guard let mesh = document.meshes?[safe: meshIndex] else { continue }

            for primitive in mesh.primitives {
                guard let posIdx = primitive.attributes["POSITION"],
                    let idxIdx = primitive.indices
                else { continue }

                let posF = try bufLoader.loadAccessorAsFloat(posIdx)
                let vertCount = posF.count / 3

                let hasNormals = primitive.attributes["NORMAL"] != nil
                var norF = [Float](repeating: 0, count: vertCount * 3)
                if let i = primitive.attributes["NORMAL"] {
                    norF = try bufLoader.loadAccessorAsFloat(i)
                } else {
                    // Fallback: emit upright normals so lighting doesn't NaN out.
                    // (Ideally compute flat per-face normals from POSITION/indices.)
                    for i in 0..<vertCount { norF[i * 3 + 1] = 1.0 }
                    vrmLog("[CampusRenderer] Primitive missing NORMAL; using fallback (0,1,0)")
                }
                var texF = [Float](repeating: 0, count: vertCount * 2)
                if let i = primitive.attributes["TEXCOORD_0"] {
                    texF = try bufLoader.loadAccessorAsFloat(i)
                }

                var colorF: [Float] = []
                var colorComps = 0
                if let i = primitive.attributes["COLOR_0"] {
                    colorF = (try? bufLoader.loadAccessorAsFloat(i)) ?? []
                    colorComps = colorF.isEmpty ? 0 : colorF.count / vertCount
                }

                var vertices = [CampusVertex](
                    repeating: CampusVertex(
                        position: .zero, normal: [0, 1, 0],
                        texCoord: .zero, color: [1, 1, 1, 1]),
                    count: vertCount)
                for i in 0..<vertCount {
                    var vc = SIMD4<Float>(1, 1, 1, 1)
                    if colorComps >= 4 {
                        vc = SIMD4<Float>(
                            colorF[i * colorComps], colorF[i * colorComps + 1],
                            colorF[i * colorComps + 2], colorF[i * colorComps + 3])
                    } else if colorComps == 3 {
                        vc = SIMD4<Float>(colorF[i * 3], colorF[i * 3 + 1], colorF[i * 3 + 2], 1)
                    }
                    vertices[i] = CampusVertex(
                        position: SIMD3<Float>(posF[i * 3], posF[i * 3 + 1], posF[i * 3 + 2]),
                        normal: SIMD3<Float>(norF[i * 3], norF[i * 3 + 1], norF[i * 3 + 2]),
                        texCoord: SIMD2<Float>(texF[i * 2], texF[i * 2 + 1]),
                        color: vc)
                }

                let indices = try bufLoader.loadAccessorAsUInt32(idxIdx)

                guard
                    let vb = device.makeBuffer(
                        bytes: vertices,
                        length: MemoryLayout<CampusVertex>.stride * vertices.count,
                        options: .storageModeShared),
                    let ib = device.makeBuffer(
                        bytes: indices,
                        length: MemoryLayout<UInt32>.stride * indices.count,
                        options: .storageModeShared)
                else { continue }

                vb.label = "Campus_VB_\(groups.count)"
                ib.label = "Campus_IB_\(groups.count)"

                var texture: MTLTexture? = nil
                var baseColorFactor = SIMD4<Float>(1, 1, 1, 1)
                var emissive = SIMD3<Float>(0, 0, 0)
                var alphaCutoff: Float = 0.01
                var metallic: Float = 0.0
                var roughness: Float = 1.0

                let matIdx = primitive.material
                let mat = matIdx.flatMap { document.materials?[safe: $0] }
                let meshName = mesh.name ?? "mesh[\(meshIndex)]"
                let matName = mat?.name ?? (matIdx.map { "mat[\($0)]" } ?? "no-material")

                let isBlend = mat?.alphaMode == "BLEND"

                if let mat = mat {
                    let pbr = mat.pbrMetallicRoughness
                    if let f = pbr?.baseColorFactor, f.count >= 4 {
                        baseColorFactor = SIMD4<Float>(f[0], f[1], f[2], f[3])
                    }
                    metallic = pbr?.metallicFactor ?? 0.0
                    roughness = pbr?.roughnessFactor ?? 1.0

                    if let texIdx = pbr?.baseColorTexture?.index {
                        if let cached = textureCache[texIdx] {
                            texture = cached
                        } else {
                            do {
                                texture = try await texLoader.loadTexture(
                                    at: texIdx, sRGB: true, withMipmaps: true)
                                if let tex = texture { textureCache[texIdx] = tex }
                            } catch {
                                vrmLog("[CampusRenderer] Texture \(texIdx) load error: \(error)")
                            }
                        }
                    }
                    if let ef = mat.emissiveFactor, ef.count >= 3 {
                        emissive = SIMD3<Float>(ef[0], ef[1], ef[2])
                    }
                    if mat.alphaMode == "MASK" {
                        alphaCutoff = mat.alphaCutoff ?? 0.5
                    }
                }

                if isBlend && baseColorFactor.w <= 0.0 {
                    baseColorFactor.w = 1.0
                }

                groups.append(
                    CampusMeshGroup(
                        vertexBuffer: vb,
                        indexBuffer: ib,
                        indexCount: indices.count,
                        indexType: .uint32,
                        texture: texture,
                        baseColorFactor: baseColorFactor,
                        emissivePacked: SIMD4<Float>(
                            emissive.x, emissive.y, emissive.z, alphaCutoff),
                        materialParams: SIMD4<Float>(metallic, roughness, 0, 0),
                        transform: worldTransform,
                        isBlend: isBlend
                    ))
            }
        }

        meshGroups = groups
        isReady = !groups.isEmpty
        vrmLog(
            "[CampusRenderer] Loaded \(groups.count) mesh group(s) (\(textureCache.count) unique texture(s))"
        )
    }

    // MARK: - Private setup

    private func setupDepthState() {
        let desc = MTLDepthStencilDescriptor()
        desc.depthCompareFunction = .less
        desc.isDepthWriteEnabled = true
        depthState = device.makeDepthStencilState(descriptor: desc)

        let blendDesc = MTLDepthStencilDescriptor()
        blendDesc.depthCompareFunction = .less
        blendDesc.isDepthWriteEnabled = false
        blendDepthState = device.makeDepthStencilState(descriptor: blendDesc)
    }

    private func setupPipelines(config: RendererConfig) {
        guard let lib = try? VRMPipelineCache.shared.getLibrary(device: device),
            let shadowVert = lib.makeFunction(name: "campus_shadow_vertex"),
            let mainVert = lib.makeFunction(name: "campus_vertex"),
            let mainFrag = lib.makeFunction(name: "campus_fragment")
        else {
            vrmLog("[CampusRenderer] Shader functions not found")
            return
        }

        let posOff = MemoryLayout<CampusVertex>.offset(of: \.position)!
        let norOff = MemoryLayout<CampusVertex>.offset(of: \.normal)!
        let texOff = MemoryLayout<CampusVertex>.offset(of: \.texCoord)!
        let colorOff = MemoryLayout<CampusVertex>.offset(of: \.color)!
        let stride = MemoryLayout<CampusVertex>.stride

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
        vd.attributes[3].format = .float4
        vd.attributes[3].offset = colorOff
        vd.attributes[3].bufferIndex = 0
        vd.layouts[0].stride = stride

        let shadowVD = MTLVertexDescriptor()
        shadowVD.attributes[0].format = .float3
        shadowVD.attributes[0].offset = posOff
        shadowVD.attributes[0].bufferIndex = 0
        shadowVD.layouts[0].stride = stride

        let shadowDesc = MTLRenderPipelineDescriptor()
        shadowDesc.label = "campus_shadow"
        shadowDesc.vertexFunction = shadowVert
        shadowDesc.vertexDescriptor = shadowVD
        shadowDesc.depthAttachmentPixelFormat = .depth32Float

        let mainDesc = MTLRenderPipelineDescriptor()
        mainDesc.label = "campus_main"
        mainDesc.vertexFunction = mainVert
        mainDesc.fragmentFunction = mainFrag
        mainDesc.vertexDescriptor = vd
        mainDesc.colorAttachments[0].pixelFormat = config.colorPixelFormat
        mainDesc.colorAttachments[0].isBlendingEnabled = false
        mainDesc.depthAttachmentPixelFormat = .depth32Float
        mainDesc.rasterSampleCount = config.sampleCount

        let blendDesc = MTLRenderPipelineDescriptor()
        blendDesc.label = "campus_blend"
        blendDesc.vertexFunction = mainVert
        blendDesc.fragmentFunction = mainFrag
        blendDesc.vertexDescriptor = vd
        blendDesc.colorAttachments[0].pixelFormat = config.colorPixelFormat
        blendDesc.colorAttachments[0].isBlendingEnabled = true
        blendDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        blendDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        blendDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        blendDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        blendDesc.depthAttachmentPixelFormat = .depth32Float
        blendDesc.rasterSampleCount = config.sampleCount

        do {
            shadowPipeline = try VRMPipelineCache.shared.getPipelineState(
                device: device, descriptor: shadowDesc, key: "campus_shadow_v1")
            mainPipeline = try VRMPipelineCache.shared.getPipelineState(
                device: device, descriptor: mainDesc, key: "campus_main_v1")
            blendPipeline = try VRMPipelineCache.shared.getPipelineState(
                device: device, descriptor: blendDesc, key: "campus_blend_v1")
        } catch {
            vrmLog("[CampusRenderer] Pipeline creation failed: \(error)")
        }
    }

    private func setupUniformBuffers() {
        uniformsBuffer = device.makeBuffer(
            length: MemoryLayout<CampusUniforms>.stride, options: .storageModeShared)
        uniformsBuffer?.label = "CampusUniforms"
        shadowUniformsBuffer = device.makeBuffer(
            length: MemoryLayout<CampusShadowUniforms>.stride, options: .storageModeShared)
        shadowUniformsBuffer?.label = "CampusShadowUniforms"
    }

    private func setupFallbackTexture() {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        var pixel: UInt32 = 0xFFFF_FFFF
        tex.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
        fallbackTexture = tex
    }

    private func collectMeshInstances(
        nodeIndex: Int, parentTransform: simd_float4x4, document: GLTFDocument,
        into result: inout [(meshIndex: Int, worldTransform: simd_float4x4)]
    ) {
        guard let node = document.nodes?[safe: nodeIndex] else { return }
        let world = parentTransform * nodeLocalTransform(node)
        if let meshIdx = node.mesh { result.append((meshIdx, world)) }
        for childIdx in node.children ?? [] {
            collectMeshInstances(
                nodeIndex: childIdx, parentTransform: world,
                document: document, into: &result)
        }
    }

    private func nodeLocalTransform(_ node: GLTFNode) -> simd_float4x4 {
        if let m = node.matrix, m.count == 16 {
            return simd_float4x4(
                SIMD4<Float>(m[0], m[1], m[2], m[3]),
                SIMD4<Float>(m[4], m[5], m[6], m[7]),
                SIMD4<Float>(m[8], m[9], m[10], m[11]),
                SIMD4<Float>(m[12], m[13], m[14], m[15]))
        }
        let t = node.translation.map { SIMD3<Float>($0[0], $0[1], $0[2]) } ?? .zero
        let q =
            node.rotation.map { simd_quatf(vector: SIMD4<Float>($0[0], $0[1], $0[2], $0[3])) }
            ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let s = node.scale.map { SIMD3<Float>($0[0], $0[1], $0[2]) } ?? SIMD3<Float>(1, 1, 1)
        let Sm = simd_float4x4(diagonal: SIMD4<Float>(s.x, s.y, s.z, 1))
        let Rm = simd_float4x4(q)
        var Tm = matrix_identity_float4x4
        Tm[3] = SIMD4<Float>(t.x, t.y, t.z, 1)
        return Tm * Rm * Sm
    }
}
