//
//  KeepsakePropFactory.swift
//  NeuraLink
//
//  Builds the keepsake props — one surface per KeepsakeSurface and one
//  object per RoomObjectKind — as VRMProps: procedural geometry
//  (PropMeshBuilder), toon materials and painted (KeepsakeArt) or
//  photographed textures. Every prop's local frame has its base at the
//  origin, +Y up and +Z toward the viewer; KeepsakeRoomRules says where
//  each one stands.
//
//  Created by Dedicatus on 05/11/2026.
//

import Foundation
import Metal
import simd

enum KeepsakePropFactory {

    /// Painted images and photographs are decoded no larger than this.
    static let textureCap = 512

    // MARK: - The surfaces

    /// What the keepsakes stand on; its slot origin is on the top, above
    /// the prop's origin.
    static func surface(_ surface: KeepsakeSurface, device: MTLDevice) -> VRMProp? {
        switch surface {
        case .table: return table(device: device)
        case .suitcase: return suitcases(device: device)
        case .chest: return chest(device: device)
        }
    }

    /// A pedestal side table: a round top with chamfered edges in honey
    /// wood, on a turned walnut stem — a collar under the top, a brass
    /// ring, a long neck swelling into a baluster — over a domed foot.
    private static func table(device: MTLDevice) -> VRMProp? {
        let height = KeepsakeSurface.table.topHeight
        let radius = KeepsakeRoomRules.tableRadius
        var top = PropMeshBuilder()
        turn([(height - 0.025, radius - 0.010), (height - 0.017, radius), (height - 0.007, radius), (height, radius - 0.007)],
             segments: 40, into: &top)
        var walnut = PropMeshBuilder()
        turn([(0, 0.150), (0.012, 0.150), (0.040, 0.090), (0.060, 0.050), (0.080, 0.038), (0.200, 0.026),
              (0.230, 0.044), (0.290, 0.044), (0.330, 0.024), (0.600, 0.030), (0.620, 0.034)],
             segments: 28, into: &walnut)
        turn([(0.630, 0.052), (height - 0.025, 0.064)], segments: 28, into: &walnut)
        var brass = PropMeshBuilder()
        turn([(0.620, 0.037), (0.630, 0.037)], segments: 28, into: &brass)
        let honey = material("keepsake_table_top", colour: SIMD3<Float>(0.58, 0.40, 0.22))
        let dark = material("keepsake_table_stem", colour: SIMD3<Float>(0.34, 0.21, 0.12))
        let ring = material("keepsake_table_brass", colour: SIMD3<Float>(0.74, 0.60, 0.30))
        return assemble("keepsake_table", device: device, materials: [honey, dark, ring], textures: [],
                        meshes: [(top, 0), (walnut, 1), (brass, 2)])
    }

    /// Two vintage suitcases set down flat and stacked, the smaller on
    /// top: leather bodies with overhanging lids, corner guards, two
    /// straps each, brass latches at the seam and a handle on the lower
    /// one's front. The keepsakes stand on the upper lid.
    private static func suitcases(device: MTLDevice) -> VRMProp? {
        var lower = PropMeshBuilder(), upper = PropMeshBuilder(), trim = PropMeshBuilder(), brass = PropMeshBuilder()
        addSuitcase(size: [0.62, 0.20, 0.42], base: 0, handle: true, body: &lower, trim: &trim, brass: &brass)
        addSuitcase(size: [0.50, 0.16, 0.34], base: 0.20, handle: false, body: &upper, trim: &trim, brass: &brass)
        let brown = material("keepsake_suitcase_lower", colour: SIMD3<Float>(0.46, 0.28, 0.16))
        let green = material("keepsake_suitcase_upper", colour: SIMD3<Float>(0.24, 0.36, 0.33))
        let leather = material("keepsake_suitcase_trim", colour: SIMD3<Float>(0.22, 0.14, 0.09))
        let fittings = material("keepsake_suitcase_brass", colour: SIMD3<Float>(0.74, 0.60, 0.30))
        return assemble("keepsake_suitcases", device: device, materials: [brown, green, leather, fittings], textures: [],
                        meshes: [(lower, 0), (upper, 1), (trim, 2), (brass, 3)])
    }

    /// One suitcase lying flat, its base at `base`, lid on top.
    private static func addSuitcase(
        size: SIMD3<Float>, base: Float, handle: Bool,
        body: inout PropMeshBuilder, trim: inout PropMeshBuilder, brass: inout PropMeshBuilder
    ) {
        let half = size * 0.5
        let seam = base + size.y * 0.6
        let top = base + size.y
        body.addBox(centre: [0, (base + seam) / 2, 0], size: [size.x, seam - base, size.z])
        body.addBox(centre: [0, (seam + top) / 2, 0], size: [size.x + 0.008, top - seam, size.z + 0.008])
        for sx: Float in [-1, 1] {
            for sz: Float in [-1, 1] {
                for y in [base + 0.02, top - 0.02] {
                    trim.addBox(centre: [sx * (half.x - 0.012), y, sz * (half.z - 0.012)], size: [0.04, 0.04, 0.04])
                }
            }
            trim.addBox(centre: [sx * half.x * 0.72, (base + top + 0.004) / 2, 0], size: [0.03, size.y + 0.004, size.z + 0.016])
            brass.addBox(centre: [sx * half.x * 0.45, seam, half.z + 0.008], size: [0.03, 0.024, 0.008])
        }
        guard handle else { return }
        trim.addBox(centre: [0, seam - 0.03, half.z + 0.010], size: [0.14, 0.022, 0.016])
        for sx: Float in [-1, 1] {
            brass.addBox(centre: [sx * 0.075, seam - 0.03, half.z + 0.005], size: [0.022, 0.03, 0.010])
        }
    }

    /// A turned piece: frustums through `profile` (height, radius), bottom up.
    private static func turn(_ profile: [(Float, Float)], segments: Int, into builder: inout PropMeshBuilder) {
        for (lower, upper) in zip(profile, profile.dropFirst()) where upper.0 > lower.0 {
            builder.addCylinder(bottom: lower.0, top: upper.0, bottomRadius: lower.1, topRadius: upper.1, segments: segments)
        }
    }

    /// A closed wooden chest with two iron straps and a hasp, the
    /// keepsakes on its lid.
    private static func chest(device: MTLDevice) -> VRMProp? {
        let lid = KeepsakeSurface.chest.topHeight
        var wood = PropMeshBuilder()
        wood.addBox(centre: [0, 0.20, 0], size: [0.50, 0.40, 0.36])
        wood.addBox(centre: [0, lid - 0.03, 0], size: [0.52, 0.06, 0.38])
        var iron = PropMeshBuilder()
        for x: Float in [-0.20, 0.20] {
            iron.addBox(centre: [x, (lid + 0.005) / 2, 0], size: [0.03, lid + 0.005, 0.39])
        }
        iron.addBox(centre: [0, 0.40, 0.19], size: [0.05, 0.06, 0.012])
        let planks = material("keepsake_chest_wood", colour: SIMD3<Float>(0.40, 0.26, 0.15))
        let straps = material("keepsake_chest_iron", colour: SIMD3<Float>(0.16, 0.15, 0.14))
        return assemble("keepsake_chest", device: device, materials: [planks, straps], textures: [],
                        meshes: [(wood, 0), (iron, 1)])
    }

    // MARK: - The objects

    /// The object for `object`; `picture` is the photograph a frame or
    /// polaroid shows (JPEG/PNG bytes), when there is one.
    static func prop(for object: RoomObject, picture: Data?, characterName: String, device: MTLDevice) async -> VRMProp? {
        switch object.kind {
        case .card: return await card(date: object.achievedAt, device: device)
        case .frame: return await frame(picture: picture, characterName: characterName, device: device)
        case .polaroid: return await polaroid(picture: picture, device: device)
        case .sleeve: return await sleeve(note: object.note, device: device)
        case .die: return await die(device: device)
        case .plant: return await plant(stage: object.stage, device: device)
        }
    }

    /// A tent card: two panels meeting at the top, the front one lettered.
    private static func card(date: Date, device: MTLDevice) async -> VRMProp? {
        guard let art = await texture(KeepsakeArt.card(date: date.formatted(.dateTime.day().month())), device: device)
        else { return nil }
        let cream = SIMD3<Float>(0.98, 0.95, 0.88)
        var front = PropMeshBuilder()
        front.addFace(centre: [0, 0.024, 0.0065], right: [0.0375, 0, 0], up: [0, 0.024, -0.0065])
        var back = PropMeshBuilder()
        back.addFace(centre: [0, 0.024, -0.0065], right: [-0.0375, 0, 0], up: [0, 0.024, 0.0065])
        let lettered = material("keepsake_card_front", colour: [1, 1, 1], texture: art, shadeMultiply: 0, doubleSided: true)
        let plain = material("keepsake_card_back", colour: cream, doubleSided: true)
        return assemble("keepsake_card", device: device, materials: [lettered, plain], textures: [art],
                        meshes: [(front, 0), (back, 1)])
    }

    /// A standing frame around the picture; without one, a closed notebook.
    private static func frame(picture: Data?, characterName: String, device: MTLDevice) async -> VRMProp? {
        let walnut = SIMD3<Float>(0.30, 0.19, 0.12)
        if let picture, let photo = await texture(picture, device: device) {
            var wood = PropMeshBuilder()
            wood.addBox(centre: [0, 0.08, 0.004], size: [0.13, 0.16, 0.008])
            wood.addBox(centre: [-0.0575, 0.08, 0.012], size: [0.015, 0.16, 0.008])
            wood.addBox(centre: [0.0575, 0.08, 0.012], size: [0.015, 0.16, 0.008])
            wood.addBox(centre: [0, 0.1525, 0.012], size: [0.10, 0.015, 0.008])
            wood.addBox(centre: [0, 0.0075, 0.012], size: [0.10, 0.015, 0.008])
            var face = PropMeshBuilder()
            let uv = PropMeshBuilder.UVRect.centred(pictureAspect: aspect(of: photo), opening: 0.10 / 0.13)
            face.addFace(centre: [0, 0.08, 0.0085], right: [0.05, 0, 0], up: [0, 0.065, 0], uv: uv)
            let frameMaterial = material("keepsake_frame", colour: walnut)
            let pictureMaterial = material("keepsake_frame_picture", colour: [1, 1, 1], texture: photo, shadeMultiply: 0)
            return assemble("keepsake_frame", device: device, materials: [frameMaterial, pictureMaterial], textures: [photo],
                            meshes: [(wood, 0), (face, 1)])
        }
        guard let cover = await texture(KeepsakeArt.notebook(name: characterName), device: device) else { return nil }
        var body = PropMeshBuilder()
        body.addBox(centre: [0, 0.075, 0.009], size: [0.11, 0.15, 0.018], faces: [.back, .left, .right, .top, .bottom])
        var face = PropMeshBuilder()
        face.addFace(centre: [0, 0.075, 0.018], right: [0.055, 0, 0], up: [0, 0.075, 0])
        let pages = material("keepsake_notebook", colour: SIMD3<Float>(0.90, 0.87, 0.78))
        let coverMaterial = material("keepsake_notebook_cover", colour: [1, 1, 1], texture: cover, shadeMultiply: 0)
        return assemble("keepsake_notebook", device: device, materials: [pages, coverMaterial], textures: [cover],
                        meshes: [(body, 0), (face, 1)])
    }

    /// A white-bordered card with the photo in its square window.
    private static func polaroid(picture: Data?, device: MTLDevice) async -> VRMProp? {
        var image: MTLTexture?
        if let picture { image = await texture(picture, device: device) }
        if image == nil { image = await texture(KeepsakeArt.blankPolaroid(), device: device) }
        guard let image else { return nil }
        var paper = PropMeshBuilder()
        paper.addBox(centre: [0, 0.043, 0.00075], size: [0.072, 0.086, 0.0015])
        var window = PropMeshBuilder()
        let uv = PropMeshBuilder.UVRect.centred(pictureAspect: aspect(of: image), opening: 1)
        window.addFace(centre: [0, 0.052, 0.0016], right: [0.031, 0, 0], up: [0, 0.031, 0], uv: uv)
        let paperMaterial = material("keepsake_polaroid", colour: SIMD3<Float>(0.97, 0.96, 0.93))
        let pictureMaterial = material("keepsake_polaroid_picture", colour: [1, 1, 1], texture: image, shadeMultiply: 0)
        return assemble("keepsake_polaroid", device: device, materials: [paperMaterial, pictureMaterial], textures: [image],
                        meshes: [(paper, 0), (window, 1)])
    }

    /// A square sleeve standing on edge, its cover on the front.
    private static func sleeve(note: String, device: MTLDevice) async -> VRMProp? {
        let song = KeepsakeRoomRules.songParts(note)
        guard let cover = await texture(KeepsakeArt.sleeve(title: song?.title ?? "", artist: song?.artist ?? ""), device: device)
        else { return nil }
        var body = PropMeshBuilder()
        body.addBox(centre: [0, 0.06, 0.0025], size: [0.12, 0.12, 0.005], faces: [.back, .left, .right, .top, .bottom])
        var face = PropMeshBuilder()
        face.addFace(centre: [0, 0.06, 0.005], right: [0.06, 0, 0], up: [0, 0.06, 0])
        let edges = material("keepsake_sleeve", colour: SIMD3<Float>(0.22, 0.22, 0.24))
        let coverMaterial = material("keepsake_sleeve_cover", colour: [1, 1, 1], texture: cover, shadeMultiply: 0)
        return assemble("keepsake_sleeve", device: device, materials: [edges, coverMaterial], textures: [cover],
                        meshes: [(body, 0), (face, 1)])
    }

    /// A die, opposite faces summing to seven, two up and one to the front.
    private static func die(device: MTLDevice) async -> VRMProp? {
        guard let pips = await texture(KeepsakeArt.diePips(), device: device) else { return nil }
        func cell(_ face: Int) -> PropMeshBuilder.UVRect {
            .cell((face - 1) % 3, (face - 1) / 3, columns: 3, rows: 2)
        }
        var cube = PropMeshBuilder()
        cube.addBox(
            centre: [0, 0.011, 0], size: [0.022, 0.022, 0.022],
            uv: [.front: cell(1), .back: cell(6), .top: cell(2), .bottom: cell(5), .right: cell(3), .left: cell(4)])
        let ivory = material("keepsake_die", colour: [1, 1, 1], texture: pips, shadeMultiply: 0)
        return assemble("keepsake_die", device: device, materials: [ivory], textures: [pips], meshes: [(cube, 0)])
    }

    /// A terracotta pot; a sprout, a leafy stem or a stem in flower.
    private static func plant(stage: Int, device: MTLDevice) async -> VRMProp? {
        guard let leaf = await texture(KeepsakeArt.leaf(), device: device),
              let flower = await texture(KeepsakeArt.flower(), device: device)
        else { return nil }
        var pot = PropMeshBuilder()
        pot.addCylinder(bottom: 0, top: 0.06, bottomRadius: 0.026, topRadius: 0.034, segments: 20)
        pot.addCylinder(bottom: 0.055, top: 0.065, bottomRadius: 0.037, topRadius: 0.037, segments: 20)
        var soil = PropMeshBuilder()
        soil.addCylinder(bottom: 0.05, top: 0.057, bottomRadius: 0.031, topRadius: 0.031, segments: 20)
        let grown = max(1, min(3, stage))
        let stemHeight: Float = [0.05, 0.10, 0.12][grown - 1]
        let stemBase: Float = 0.056
        var stem = PropMeshBuilder()
        stem.addBox(centre: [0, stemBase + stemHeight / 2, 0], size: [0.004, stemHeight, 0.004])
        var leaves = PropMeshBuilder()
        let leafCount = [2, 5, 7][grown - 1]
        let leafLength: Float = grown == 1 ? 0.025 : 0.035
        for index in 0..<leafCount {
            let turn = Float(index) * 2.3999632  // the golden angle, so no two leaves line up
            let height = stemBase + stemHeight * (0.35 + 0.65 * Float(index) / Float(max(1, leafCount - 1)))
            let pitch: Float = 0.6
            let along = SIMD3<Float>(cos(turn) * cos(pitch), sin(pitch), sin(turn) * cos(pitch))
            let across = SIMD3<Float>(-sin(turn), 0, cos(turn))
            leaves.addFace(centre: SIMD3<Float>(0, height, 0) + along * (leafLength / 2),
                           right: across * 0.009, up: along * (leafLength / 2))
        }
        var flowers = PropMeshBuilder()
        if grown == 3 {
            let top = stemBase + stemHeight
            for (index, offset) in [SIMD3<Float>(0, 0.012, 0.004), [-0.016, 0, -0.004], [0.015, -0.004, 0.006]].enumerated() {
                let tilt: Float = 0.5 + 0.2 * Float(index)
                flowers.addFace(centre: SIMD3<Float>(0, top, 0) + offset,
                                right: [0.011, 0, 0], up: [0, 0.011 * sin(tilt), -0.011 * cos(tilt)])
            }
        }
        let clay = material("keepsake_pot", colour: SIMD3<Float>(0.72, 0.38, 0.25))
        let earth = material("keepsake_soil", colour: SIMD3<Float>(0.22, 0.15, 0.10))
        let green = material("keepsake_stem", colour: SIMD3<Float>(0.28, 0.52, 0.26))
        let leafMaterial = material("keepsake_leaf", colour: [1, 1, 1], texture: leaf, shadeMultiply: 0, alphaMode: "MASK", doubleSided: true)
        let flowerMaterial = material("keepsake_flower", colour: [1, 1, 1], texture: flower, shadeMultiply: 1, alphaMode: "MASK", doubleSided: true)
        var meshes: [(PropMeshBuilder, Int)] = [(pot, 0), (soil, 1), (stem, 2), (leaves, 3)]
        if !flowers.isEmpty { meshes.append((flowers, 4)) }
        return assemble("keepsake_plant_\(grown)", device: device, materials: [clay, earth, green, leafMaterial, flowerMaterial],
                        textures: [leaf, flower], meshes: meshes)
    }

    // MARK: - Pieces

    /// A toon material: lit colour from the factor (× texture), the shade
    /// a darker copy of it. `shadeMultiply` names the prop's texture the
    /// shade multiplies, so a picture stays a picture in shadow; the index
    /// is moved into the model's texture array on placement.
    private static func material(
        _ name: String, colour: SIMD3<Float>, texture: MTLTexture? = nil, shadeMultiply: Int? = nil,
        alphaMode: String = "OPAQUE", doubleSided: Bool = false
    ) -> VRMMaterial {
        let material = VRMMaterial(name: name)
        material.baseColorFactor = SIMD4<Float>(colour, 1)
        material.baseColorTexture = texture.map { VRMTexture(name: name, mtlTexture: $0) }
        material.alphaMode = alphaMode
        material.alphaCutoff = 0.5
        material.doubleSided = doubleSided
        material.renderQueue = alphaMode == "MASK" ? 2450 : 2000
        var mtoon = VRMMToonMaterial()
        mtoon.shadeColorFactor = texture == nil ? colour * 0.55 : SIMD3<Float>(repeating: 0.6)
        mtoon.shadeMultiplyTexture = shadeMultiply
        mtoon.shadingToonyFactor = 0.85
        mtoon.shadingShiftFactor = 0
        mtoon.giIntensityFactor = 0.25
        mtoon.matcapFactor = .zero
        mtoon.parametricRimColorFactor = .zero
        mtoon.outlineWidthMode = .none
        material.mtoon = mtoon
        return material
    }

    /// Materials, textures (in the order the shade-multiply indices use)
    /// and one mesh per builder, each with its material index.
    private static func assemble(
        _ name: String, device: MTLDevice, materials: [VRMMaterial], textures: [MTLTexture],
        meshes: [(PropMeshBuilder, Int)]
    ) -> VRMProp? {
        var parts: [VRMProp.Part] = []
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for (index, (builder, materialIndex)) in meshes.enumerated() where !builder.isEmpty {
            guard let primitive = builder.makePrimitive(device: device, materialIndex: materialIndex) else { return nil }
            let mesh = VRMMesh(name: "\(name)_\(index)")
            mesh.primitives.append(primitive)
            parts.append(VRMProp.Part(mesh: mesh, chain: .identity))
            low = simd_min(low, builder.low)
            high = simd_max(high, builder.high)
        }
        guard !parts.isEmpty else { return nil }
        // Every texture the shade indices may name, so the indices line up
        // with the model's array after placement.
        let propTextures = textures.enumerated().map { VRMTexture(name: "\(name)_texture_\($0.offset)", mtlTexture: $0.element) }
        return VRMProp(name: name, parts: parts, materials: materials, textures: propTextures, extent: high - low)
    }

    private static func texture(_ data: Data, device: MTLDevice) async -> MTLTexture? {
        await VRMPropTextureDecoder.decode(data, sRGB: true, maxSize: textureCap, device: device)
    }

    private static func aspect(of texture: MTLTexture) -> Float {
        Float(max(1, texture.width)) / Float(max(1, texture.height))
    }
}
