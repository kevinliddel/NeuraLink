//
//  EnvironmentRenderer+Load.swift
//  NeuraLink
//
//  Created by Dedicatus on 08/05/2026.
//

import Foundation
import Metal
import simd

extension EnvironmentRenderer {

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
        let baseURL   = url.deletingLastPathComponent()
        let bufLoader = BufferLoader(document: document, binaryData: binary, baseURL: baseURL)
        let texLoader = TextureLoader(
            device: device, bufferLoader: bufLoader, document: document, baseURL: baseURL)

        // Collect mesh instances in model space (identity root). The instance
        // transform — including any auto-fit scale and recentering — is applied
        // after the model bounds are known (see end of load), so the scale can
        // depend on those bounds.
        var meshInstances: [(meshIndex: Int, worldTransform: simd_float4x4)] = []
        let sceneIndex = document.scene ?? 0
        for ni in document.scenes?[safe: sceneIndex]?.nodes ?? [] {
            collectMeshInstances(nodeIndex: ni, parentTransform: matrix_identity_float4x4,
                                 document: document, into: &meshInstances)
        }

        nlLog("[EnvironmentRenderer] Scene graph: \(meshInstances.count) mesh instance(s) across all nodes")

        var textureCache: [Int: MTLTexture] = [:]
        var groups: [CityMeshGroup] = []
        var aabbMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var aabbMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        // Ground detection: the largest flat (thin-in-y) horizontal surface is
        // taken as the walkable floor; its top y grounds the model exactly so it
        // never sinks/floats when auto-fit scales it.
        var groundFootprint: Float = 0
        var groundTopY: Float = 0

        for (meshIndex, worldTransform) in meshInstances {
            guard let mesh = document.meshes?[safe: meshIndex] else { continue }

            for primitive in mesh.primitives {
                guard let posIdx = primitive.attributes["POSITION"],
                      let idxIdx = primitive.indices
                else { continue }

                let posF      = try bufLoader.loadAccessorAsFloat(posIdx)
                let vertCount = posF.count / 3

                var norF = [Float](repeating: 0, count: vertCount * 3)
                if let i = primitive.attributes["NORMAL"] {
                    norF = try bufLoader.loadAccessorAsFloat(i)
                }
                var texF = [Float](repeating: 0, count: vertCount * 2)
                if let i = primitive.attributes["TEXCOORD_0"] {
                    texF = try bufLoader.loadAccessorAsFloat(i)
                }

                var colorF: [Float] = []
                var colorComps = 0
                if let i = primitive.attributes["COLOR_0"] {
                    colorF     = (try? bufLoader.loadAccessorAsFloat(i)) ?? []
                    colorComps = colorF.isEmpty ? 0 : colorF.count / vertCount
                }

                var vertices = [CityVertex](
                    repeating: CityVertex(position: .zero, normal: [0, 1, 0],
                                         texCoord: .zero, color: [1, 1, 1, 1]),
                    count: vertCount)
                var primMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
                var primMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
                for i in 0..<vertCount {
                    var vc = SIMD4<Float>(1, 1, 1, 1)
                    if colorComps >= 4 {
                        vc = SIMD4<Float>(colorF[i*colorComps], colorF[i*colorComps+1],
                                         colorF[i*colorComps+2], colorF[i*colorComps+3])
                    } else if colorComps == 3 {
                        vc = SIMD4<Float>(colorF[i*3], colorF[i*3+1], colorF[i*3+2], 1)
                    }
                    let lp = SIMD3<Float>(posF[i*3], posF[i*3+1], posF[i*3+2])
                    vertices[i] = CityVertex(
                        position: lp,
                        normal: SIMD3<Float>(norF[i*3], norF[i*3+1], norF[i*3+2]),
                        texCoord: SIMD2<Float>(texF[i*2], texF[i*2+1]),
                        color: vc)
                    // Model-space bounds (see auto-fit + grounding at end of load).
                    let wp = worldTransform * SIMD4<Float>(lp, 1)
                    primMin = simd_min(primMin, SIMD3<Float>(wp.x, wp.y, wp.z))
                    primMax = simd_max(primMax, SIMD3<Float>(wp.x, wp.y, wp.z))
                }
                aabbMin = simd_min(aabbMin, primMin)
                aabbMax = simd_max(aabbMax, primMax)
                // The widest thin-in-y surface is the ground plane.
                let primExtent = primMax - primMin
                let primFootprint = max(primExtent.x, primExtent.z)
                if primFootprint > groundFootprint, primExtent.y < 0.25 * primFootprint {
                    groundFootprint = primFootprint
                    groundTopY = primMax.y
                }

                let indices = try bufLoader.loadAccessorAsUInt32(idxIdx)

                guard let vb = device.makeBuffer(
                    bytes: vertices,
                    length: MemoryLayout<CityVertex>.stride * vertices.count,
                    options: .storageModeShared),
                      let ib = device.makeBuffer(
                    bytes: indices,
                    length: MemoryLayout<UInt32>.stride * indices.count,
                    options: .storageModeShared)
                else { continue }

                vb.label = "City_VB_\(groups.count)"
                ib.label = "City_IB_\(groups.count)"

                var texture: MTLTexture? = nil
                var normalTexture: MTLTexture? = nil
                var mrTexture: MTLTexture? = nil
                var emissiveTexture: MTLTexture? = nil
                var normalScale: Float   = 1.0
                var baseColorFactor      = SIMD4<Float>(1, 1, 1, 1)
                var emissive             = SIMD3<Float>(0, 0, 0)
                var alphaCutoff: Float   = 0.01
                var metallic: Float      = 0.0
                var roughness: Float     = 1.0

                let matIdx     = primitive.material
                let mat        = matIdx.flatMap { document.materials?[safe: $0] }
                let meshName   = mesh.name ?? "mesh[\(meshIndex)]"
                let matName    = mat?.name ?? (matIdx.map { "mat[\($0)]" } ?? "no-material")

                let isBlend = mat?.alphaMode == "BLEND"

                var baseColorTexIdx: Int? = nil
                if let mat = mat {
                    let pbr = mat.pbrMetallicRoughness
                    if let f = pbr?.baseColorFactor, f.count >= 4 {
                        baseColorFactor = SIMD4<Float>(f[0], f[1], f[2], f[3])
                    }
                    metallic  = pbr?.metallicFactor  ?? 0.0
                    roughness = pbr?.roughnessFactor ?? 1.0
                    baseColorTexIdx = pbr?.baseColorTexture?.index

                    // Legacy spec-gloss fallback (KHR_materials_pbrSpecularGlossiness):
                    // some GLBs (e.g. apartment.glb, a Blender spec-gloss export)
                    // carry their diffuse colour/texture in this extension rather
                    // than in pbrMetallicRoughness. Without reading it such meshes
                    // render as untextured flat white.
                    var usedSpecGloss = false
                    if baseColorTexIdx == nil, let sg = Self.specGlossDiffuse(from: mat) {
                        usedSpecGloss = true
                        if let df = sg.factor { baseColorFactor = df }
                        if let g = sg.glossiness { roughness = max(0, 1 - g) }
                        baseColorTexIdx = sg.textureIndex
                    }

                    if let texIdx = baseColorTexIdx {
                        if let cached = textureCache[texIdx] {
                            texture = cached
                        } else {
                            do {
                                texture = try await texLoader.loadTexture(
                                    at: texIdx, sRGB: true, withMipmaps: true)
                                if let tex = texture { textureCache[texIdx] = tex }
                            } catch {
                                nlLog("[EnvironmentRenderer] Texture \(texIdx) load error: \(error)")
                            }
                        }
                    }
                    if let ef = mat.emissiveFactor, ef.count >= 3 {
                        emissive = SIMD3<Float>(ef[0], ef[1], ef[2])
                    }
                    // Broken-export guard: Blender spec-gloss exports often carry a
                    // bogus flat near-white emissiveFactor that washes the whole
                    // mesh out (glTF default is black). Drop it — but only for
                    // spec-gloss materials, so genuine emissive on the other envs
                    // is untouched.
                    if usedSpecGloss, min(emissive.x, min(emissive.y, emissive.z)) >= 0.99 {
                        emissive = .zero
                    }

                    // PBR maps — only for runtime-lit envs; baked city/campus
                    // never sample these, so skip the loads and the memory.
                    if !bakedLighting {
                        if let nt = mat.normalTexture {
                            normalScale = nt.scale ?? 1.0
                            normalTexture = await Self.cachedTexture(
                                nt.index, sRGB: false, cache: &textureCache, loader: texLoader)
                        }
                        if let mrIdx = pbr?.metallicRoughnessTexture?.index {
                            mrTexture = await Self.cachedTexture(
                                mrIdx, sRGB: false, cache: &textureCache, loader: texLoader)
                        }
                        if let et = mat.emissiveTexture {
                            emissiveTexture = await Self.cachedTexture(
                                et.index, sRGB: true, cache: &textureCache, loader: texLoader)
                        }
                    }

                    if mat.alphaMode == "MASK" {
                        alphaCutoff = mat.alphaCutoff ?? 0.5
                    }
                }

                // GLB bug guard: some BLEND meshes have bcf.w = 0.0 which multiplies the
                // texture alpha to zero, making the whole mesh invisible. Clamp to 1.0 and
                // let the texture alpha drive transparency instead.
                if isBlend && baseColorFactor.w <= 0.0 {
                    baseColorFactor.w = 1.0
                }

                // --- Per-primitive material / texture log ---
                let hasNormal   = primitive.attributes["NORMAL"]     != nil
                let hasTexCoord = primitive.attributes["TEXCOORD_0"] != nil
                let hasColor0   = primitive.attributes["COLOR_0"]    != nil
                let triCount    = indices.count / 3
                let texIdxStr   = baseColorTexIdx.map { "tex[\($0)]" } ?? "none"
                let alphaMode   = mat?.alphaMode ?? "OPAQUE"
                let cutoffStr   = alphaMode == "MASK" ? String(format: "%.3f", alphaCutoff) : "-"
                let bcf         = baseColorFactor
                let emf         = emissive
                let flags       = "N:\(hasNormal ? "Y":"N") UV:\(hasTexCoord ? "Y":"N") C:\(hasColor0 ? "Y":"N")"
                nlLog("[EnvMat] mesh:\(meshName) mat:\(matName) alpha:\(alphaMode) cut:\(cutoffStr)"
                     + " bcf:(\(f2(bcf.x)),\(f2(bcf.y)),\(f2(bcf.z)),\(f2(bcf.w)))"
                     + " M:\(f2(metallic)) R:\(f2(roughness))"
                     + " emissive:(\(f3(emf.x)),\(f3(emf.y)),\(f3(emf.z)))"
                     + " \(texIdxStr) verts:\(vertCount) tris:\(triCount) \(flags)")

                groups.append(CityMeshGroup(
                    vertexBuffer: vb,
                    indexBuffer: ib,
                    indexCount: indices.count,
                    indexType: .uint32,
                    texture: texture,
                    normalTexture: normalTexture,
                    mrTexture: mrTexture,
                    emissiveTexture: emissiveTexture,
                    baseColorFactor: baseColorFactor,
                    emissivePacked: SIMD4<Float>(emissive.x, emissive.y, emissive.z, alphaCutoff),
                    materialParams: SIMD4<Float>(metallic, roughness, normalScale, 0),
                    texFlags: SIMD4<Float>(
                        normalTexture != nil ? 1 : 0,
                        mrTexture != nil ? 1 : 0,
                        emissiveTexture != nil ? 1 : 0,
                        0),
                    transform: worldTransform,
                    isBlend: isBlend
                ))
            }
        }

        // Bounds are known now — derive the instance transform. When
        // `autoFitFootprint` is set, uniformly scale so the larger horizontal
        // extent matches it, and recenter the model over the origin + sit its
        // base on the ground (curated envs keep their authored placement).
        let center    = (aabbMin + aabbMax) * 0.5
        let extent    = simd_max(aabbMax - aabbMin, .zero)
        let footprint = max(extent.x, extent.z)
        let useAutoFit = autoFitFootprint != nil && footprint > 0.0001
        let scale: Float = useAutoFit ? (autoFitFootprint! / footprint) : instanceConfig.scale
        appliedScale = scale

        var recenter = matrix_identity_float4x4
        var placeY   = instanceConfig.y
        if useAutoFit {
            // Recenter horizontally over the origin so the avatar stands inside
            // the env, and ground the detected floor to `instanceConfig.y` — the
            // subtraction cancels the scaled floor height exactly, so the ground
            // never sinks or floats no matter how large the auto-fit scale is.
            recenter[3] = SIMD4<Float>(-center.x, 0, -center.z, 1)
            placeY = instanceConfig.y - groundTopY * scale
        }
        let S = simd_float4x4(diagonal: SIMD4<Float>(scale, scale, scale, 1))
        let R = simd_float4x4(simd_quatf(angle: instanceConfig.rotY, axis: [0, 1, 0]))
        var T = matrix_identity_float4x4
        T[3] = SIMD4<Float>(instanceConfig.x, placeY, instanceConfig.z, 1)
        let instanceTransform = T * R * S * recenter

        meshGroups = groups.map {
            CityMeshGroup(
                vertexBuffer: $0.vertexBuffer, indexBuffer: $0.indexBuffer,
                indexCount: $0.indexCount, indexType: $0.indexType, texture: $0.texture,
                normalTexture: $0.normalTexture, mrTexture: $0.mrTexture,
                emissiveTexture: $0.emissiveTexture,
                baseColorFactor: $0.baseColorFactor, emissivePacked: $0.emissivePacked,
                materialParams: $0.materialParams, texFlags: $0.texFlags,
                transform: instanceTransform * $0.transform, isBlend: $0.isBlend)
        }
        isReady = !meshGroups.isEmpty
        nlLog("[EnvironmentRenderer] Loaded \(meshGroups.count) mesh group(s)"
             + " (\(textureCache.count) unique texture(s)); extent"
             + " x=\(f2(extent.x)) y=\(f2(extent.y)) z=\(f2(extent.z)) → scale \(f3(scale))")
    }

    // MARK: - Private setup

    private func setupDepthState() {
        let desc = MTLDepthStencilDescriptor()
        desc.depthCompareFunction = .less
        desc.isDepthWriteEnabled  = true
        depthState = device.makeDepthStencilState(descriptor: desc)

        // Blend pass: depth test enabled, depth write disabled so transparent
        // surfaces don't occlude geometry behind them.
        let blendDesc = MTLDepthStencilDescriptor()
        blendDesc.depthCompareFunction = .less
        blendDesc.isDepthWriteEnabled  = false
        blendDepthState = device.makeDepthStencilState(descriptor: blendDesc)
    }

    private func setupPipelines(config: RendererConfig) {
        guard let lib = try? VRMPipelineCache.shared.getLibrary(device: device),
              let shadowVert = lib.makeFunction(name: "city_shadow_vertex"),
              let mainVert   = lib.makeFunction(name: "city_vertex"),
              let mainFrag   = lib.makeFunction(name: "city_fragment")
        else { nlLog("[EnvironmentRenderer] Shader functions not found"); return }

        let posOff   = MemoryLayout<CityVertex>.offset(of: \.position)!
        let norOff   = MemoryLayout<CityVertex>.offset(of: \.normal)!
        let texOff   = MemoryLayout<CityVertex>.offset(of: \.texCoord)!
        let colorOff = MemoryLayout<CityVertex>.offset(of: \.color)!
        let stride   = MemoryLayout<CityVertex>.stride

        let vd = MTLVertexDescriptor()
        vd.attributes[0].format = .float3; vd.attributes[0].offset = posOff;   vd.attributes[0].bufferIndex = 0
        vd.attributes[1].format = .float3; vd.attributes[1].offset = norOff;   vd.attributes[1].bufferIndex = 0
        vd.attributes[2].format = .float2; vd.attributes[2].offset = texOff;   vd.attributes[2].bufferIndex = 0
        vd.attributes[3].format = .float4; vd.attributes[3].offset = colorOff; vd.attributes[3].bufferIndex = 0
        vd.layouts[0].stride = stride

        let shadowVD = MTLVertexDescriptor()
        shadowVD.attributes[0].format = .float3; shadowVD.attributes[0].offset = posOff
        shadowVD.attributes[0].bufferIndex = 0; shadowVD.layouts[0].stride = stride

        let shadowDesc = MTLRenderPipelineDescriptor()
        shadowDesc.label                      = "city_shadow"
        shadowDesc.vertexFunction             = shadowVert
        shadowDesc.vertexDescriptor           = shadowVD
        shadowDesc.depthAttachmentPixelFormat = .depth32Float

        let mainDesc = MTLRenderPipelineDescriptor()
        mainDesc.label                           = "city_main"
        mainDesc.vertexFunction                  = mainVert
        mainDesc.fragmentFunction                = mainFrag
        mainDesc.vertexDescriptor                = vd
        mainDesc.colorAttachments[0].pixelFormat = config.colorPixelFormat
        mainDesc.colorAttachments[0].isBlendingEnabled = false
        mainDesc.depthAttachmentPixelFormat      = .depth32Float
        mainDesc.rasterSampleCount               = config.sampleCount

        let blendDesc = MTLRenderPipelineDescriptor()
        blendDesc.label                           = "city_blend"
        blendDesc.vertexFunction                  = mainVert
        blendDesc.fragmentFunction                = mainFrag
        blendDesc.vertexDescriptor                = vd
        blendDesc.colorAttachments[0].pixelFormat = config.colorPixelFormat
        blendDesc.colorAttachments[0].isBlendingEnabled          = true
        blendDesc.colorAttachments[0].sourceRGBBlendFactor       = .sourceAlpha
        blendDesc.colorAttachments[0].destinationRGBBlendFactor  = .oneMinusSourceAlpha
        blendDesc.colorAttachments[0].sourceAlphaBlendFactor     = .one
        blendDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        blendDesc.depthAttachmentPixelFormat                      = .depth32Float
        blendDesc.rasterSampleCount                               = config.sampleCount

        do {
            shadowPipeline = try VRMPipelineCache.shared.getPipelineState(
                device: device, descriptor: shadowDesc, key: "city_shadow_v2")
            mainPipeline   = try VRMPipelineCache.shared.getPipelineState(
                device: device, descriptor: mainDesc, key: "city_main_v3")
            blendPipeline  = try VRMPipelineCache.shared.getPipelineState(
                device: device, descriptor: blendDesc, key: "city_blend_v1")
        } catch {
            nlLog("[EnvironmentRenderer] Pipeline creation failed: \(error)")
        }
    }

    private func setupUniformBuffers() {
        uniformsBuffer = device.makeBuffer(
            length: MemoryLayout<CityUniforms>.stride, options: .storageModeShared)
        uniformsBuffer?.label = "CityUniforms"
        shadowUniformsBuffer = device.makeBuffer(
            length: MemoryLayout<CityShadowUniforms>.stride, options: .storageModeShared)
        shadowUniformsBuffer?.label = "CityShadowUniforms"
    }

    private func setupFallbackTexture() {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        desc.usage = [.shaderRead]; desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        var pixel: UInt32 = 0xFFFFFFFF
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                    mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
        fallbackTexture = tex
    }

    // MARK: - Scene graph traversal

    private func collectMeshInstances(
        nodeIndex: Int, parentTransform: simd_float4x4, document: GLTFDocument,
        into result: inout [(meshIndex: Int, worldTransform: simd_float4x4)]
    ) {
        guard let node = document.nodes?[safe: nodeIndex] else { return }
        let world = parentTransform * nodeLocalTransform(node)
        if let meshIdx = node.mesh { result.append((meshIdx, world)) }
        for childIdx in node.children ?? [] {
            collectMeshInstances(nodeIndex: childIdx, parentTransform: world,
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
        let t  = node.translation.map { SIMD3<Float>($0[0], $0[1], $0[2]) } ?? .zero
        let q  = node.rotation.map { simd_quatf(vector: SIMD4<Float>($0[0], $0[1], $0[2], $0[3])) }
                 ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        let s  = node.scale.map { SIMD3<Float>($0[0], $0[1], $0[2]) } ?? SIMD3<Float>(1, 1, 1)
        let Sm = simd_float4x4(diagonal: SIMD4<Float>(s.x, s.y, s.z, 1))
        let Rm = simd_float4x4(q)
        var Tm = matrix_identity_float4x4; Tm[3] = SIMD4<Float>(t.x, t.y, t.z, 1)
        return Tm * Rm * Sm
    }

    /// Loads a texture by index with per-index caching; logs and returns nil on
    /// failure. Shared by base-colour and the PBR maps (normal / MR / emissive).
    private static func cachedTexture(
        _ index: Int, sRGB: Bool, cache: inout [Int: MTLTexture], loader: TextureLoader
    ) async -> MTLTexture? {
        if let cached = cache[index] { return cached }
        do {
            if let tex = try await loader.loadTexture(at: index, sRGB: sRGB, withMipmaps: true) {
                cache[index] = tex
                return tex
            }
        } catch {
            nlLog("[EnvironmentRenderer] Texture \(index) load error: \(error)")
        }
        return nil
    }

    // MARK: - KHR_materials_pbrSpecularGlossiness

    private struct SpecGlossDiffuse {
        var factor: SIMD4<Float>?
        var textureIndex: Int?
        var glossiness: Float?
    }

    /// Pulls the diffuse colour/texture (and glossiness) out of the legacy
    /// spec-gloss material extension, if the material uses it. Returns nil
    /// otherwise. Lets us render older Blender exports that store their base
    /// colour outside `pbrMetallicRoughness`.
    private static func specGlossDiffuse(from mat: GLTFMaterial) -> SpecGlossDiffuse? {
        guard let ext = mat.extensions?["KHR_materials_pbrSpecularGlossiness"] as? [String: Any]
        else { return nil }
        var out = SpecGlossDiffuse()
        if let df = ext["diffuseFactor"] as? [Any] {
            let f = df.compactMap { ($0 as? NSNumber)?.floatValue }
            if f.count >= 4 { out.factor = SIMD4<Float>(f[0], f[1], f[2], f[3]) }
        }
        if let dt = ext["diffuseTexture"] as? [String: Any],
           let idx = (dt["index"] as? NSNumber)?.intValue {
            out.textureIndex = idx
        }
        if let g = (ext["glossinessFactor"] as? NSNumber)?.floatValue {
            out.glossiness = g
        }
        if out.factor == nil, out.textureIndex == nil, out.glossiness == nil { return nil }
        return out
    }
}
