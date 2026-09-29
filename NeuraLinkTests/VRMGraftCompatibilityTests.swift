//
//  VRMGraftCompatibilityTests.swift
//  NeuraLinkTests
//
//  Cross-model grafting: a part cut from one rig has to land correctly on
//  another, in either VRM spec version. The donor's bones are matched to
//  the host's by HUMANOID ROLE rather than by name — the bundled models all
//  use VRoid's `J_Bip_*` vocabulary, so a name-keyed match passes here
//  while silently detaching a part on any imported model that names its
//  bones differently.
//

import Testing
import Foundation
import Metal
import simd
@testable import NeuraLink

@Suite("Graft compatibility", .serialized)
struct VRMGraftCompatibilityTests {

    private func load(_ name: String) async throws -> VRMModel? {
        guard let device = MTLCreateSystemDefaultDevice(),
            let url = Bundle.main.url(forResource: name, withExtension: "vrm")
        else { return nil }
        return try await VRMModel.load(from: url, device: device)
    }

    @Test("Donor bones bind to the host by humanoid role, not by bone name")
    @MainActor
    func bindsByRole() async throws {
        guard let host = try await load("Sonya"), let donor = try await load("Ekaterina") else { return }
        let donorHumanoid = try #require(donor.humanoid)
        var checked = 0
        for (role, bone) in donorHumanoid.humanBones {
            guard host.humanoid?.getBoneNode(role) != nil else { continue }
            let bound = try #require(host.compositionBindTarget(forDonorNode: bone.node, in: donor),
                                     "\(role.rawValue) binds")
            let boundIndex = try #require(host.nodes.firstIndex { $0 === bound })
            #expect(host.humanoidRole(ofNode: boundIndex) == role,
                    "\(role.rawValue) bound to the host's \(host.humanoidRole(ofNode: boundIndex)?.rawValue ?? "?")")
            checked += 1
        }
        #expect(checked > 40, "most of the humanoid skeleton was checked")

        // A secondary bone must never bind — those names collide between
        // VRoid models while meaning different bones.
        let secondary = donor.nodes.first { ($0.name ?? "").contains("HairJoint") || ($0.name ?? "").hasPrefix("J_Sec_") }
        if let secondary {
            #expect(host.compositionBindTarget(forDonorNode: secondary.index, in: donor) == nil)
        }
    }

    @Test("Hair grafts whole onto both spec versions", arguments: ["Sonya", "Ekaterina"])
    @MainActor
    func hairGraftsWhole(hostName: String) async throws {
        guard let device = MTLCreateSystemDefaultDevice(), let hostURL = Bundle.main.url(forResource: hostName, withExtension: "vrm")
        else { return }
        // A VRoid 1.x donor with many primitives, one with spring-bone hair,
        // and the other bundled character (which crosses spec versions).
        var donors: [(String, URL)] = []
        for stem in ["casual", "school_uniform"] {
            if let item = PartsLibrary.shared.item(slug: "lib:\(stem)__hair"),
                let url = try? await item.resolvedURL() { donors.append((stem, url)) }
        }
        let other = hostName == "Sonya" ? "Ekaterina" : "Sonya"
        if let url = Bundle.main.url(forResource: other, withExtension: "vrm") { donors.append((other.lowercased(), url)) }

        for (stem, url) in donors {
            let host = try await VRMModel.load(from: hostURL, device: device)
            let scan = try await VRMDonorTextureCache.shared.scan(url: url, slug: stem)
            let donor = try await VRMModel.load(
                from: url, device: device,
                options: VRMLoadingOptions(textureIndexFilter: scan.partTextureIndices[.hair]))
            var expected = 0
            for mesh in donor.meshes {
                for p in mesh.primitives where p.materialIndex.map({
                    AppearancePartKind.hair.slots.contains(donor.slot(ofMaterial: $0)) }) == true {
                    expected += 1
                }
            }
            let baseMeshes = host.meshes.count
            let baseNodes = host.nodes.count
            try VRMPartGrafter.graft(.hair, from: donor, donorSlug: stem, onto: host)
            host.updateNodeTransforms()

            var grafted = 0
            let headIndex = try #require(host.humanoid?.getBoneNode(.head))
            let head = host.nodes[headIndex].worldPosition
            for node in host.nodes where (node.mesh ?? -1) >= baseMeshes {
                guard let mi = node.mesh else { continue }
                grafted += host.meshes[mi].primitives.count
                for p in host.meshes[mi].primitives {
                    let m = try #require(p.materialIndex)
                    #expect(host.materials[m].baseColorTexture?.mtlTexture != nil,
                            "\(hostName)←\(stem): the part's texture survived the filtered load")
                }
            }
            #expect(grafted == expected, "\(hostName)←\(stem): every hair primitive grafted")

            // Appended bones hang off the host's head, not off the origin.
            // Long hairstyles reach well down the back, so this only has to
            // rule out "detached and left at the model root".
            for node in host.nodes[baseNodes...] where node.mesh == nil {
                #expect(simd_length(node.worldPosition - head) < 0.8,
                        "\(hostName)←\(stem): '\(node.name ?? "?")' sits near the head")
            }
        }
    }

    /// World-space box of a part actually on this model, skinned by hand so
    /// the check doesn't depend on a render.
    @MainActor
    private func partBounds(
        _ model: VRMModel, slots: Set<VRoidMaterialSlot>, fromMesh first: Int = 0
    ) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard let pOff = MemoryLayout<VRMVertex>.offset(of: \VRMVertex.position),
            let jOff = MemoryLayout<VRMVertex>.offset(of: \VRMVertex.joints),
            let wOff = MemoryLayout<VRMVertex>.offset(of: \VRMVertex.weights)
        else { return nil }
        let vstride = MemoryLayout<VRMVertex>.stride
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        var found = false
        for (mi, mesh) in model.meshes.enumerated() where mi >= first {
            guard let node = model.nodes.first(where: { $0.mesh == mi }), let si = node.skin,
                si < model.skins.count else { continue }
            let skin = model.skins[si]
            for p in mesh.primitives {
                guard let m = p.materialIndex,
                    slots.contains(model.slot(ofMaterial: m)),
                    !model.hiddenPrimitives.contains(ObjectIdentifier(p)),
                    let vb = p.vertexBuffer, let ib = p.indexBuffer else { continue }
                let base = vb.contents(), ibase = ib.contents().advanced(by: p.indexBufferOffset)
                var step = max(1, p.indexCount / 700)
                if step % 3 != 0 { step += 3 - (step % 3) }
                for n in Swift.stride(from: 0, to: p.indexCount, by: step) {
                    let vi = p.indexType == .uint16
                        ? Int(ibase.load(fromByteOffset: n * 2, as: UInt16.self))
                        : Int(ibase.load(fromByteOffset: n * 4, as: UInt32.self))
                    guard vi < p.vertexCount else { continue }
                    let pos = base.load(fromByteOffset: vi * vstride + pOff, as: SIMD3<Float>.self)
                    let js = base.load(fromByteOffset: vi * vstride + jOff, as: SIMD4<UInt32>.self)
                    let ws = base.load(fromByteOffset: vi * vstride + wOff, as: SIMD4<Float>.self)
                    var acc = SIMD4<Float>(repeating: 0); var total: Float = 0
                    for k in 0..<4 where ws[k] > 0 {
                        let ji = Int(js[k]); guard ji < skin.joints.count else { continue }
                        acc += (skin.joints[ji].worldMatrix * skin.inverseBindMatrices[ji] * SIMD4<Float>(pos, 1)) * ws[k]
                        total += ws[k]
                    }
                    guard total > 0.001 else { continue }
                    let world = SIMD3<Float>(acc.x, acc.y, acc.z) / total
                    guard world.x.isFinite else { continue }
                    lo = simd_min(lo, world); hi = simd_max(hi, world); found = true
                }
            }
        }
        return found ? (lo, hi) : nil
    }

    @Test("A hairstyle is resized to the head it moves to")
    @MainActor
    func hairFitsTheNewHead() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
            let sonyaURL = Bundle.main.url(forResource: "Sonya", withExtension: "vrm"),
            let ekURL = Bundle.main.url(forResource: "Ekaterina", withExtension: "vrm")
        else { return }
        let reference = try await VRMModel.load(from: sonyaURL, device: device)
        reference.updateNodeTransforms()
        let donor = try await VRMModel.load(from: ekURL, device: device)

        // The two characters really do have different heads — without that
        // this test proves nothing.
        let hostHead = try #require(reference.referenceHeadSize)
        let donorHead = try #require(donor.referenceHeadSize)
        let ratio = simd_length(hostHead) / simd_length(donorHead)
        #expect(ratio > 1.1, "Sonya's head is meaningfully bigger: \(ratio)")

        let ownHair = try #require(partBounds(reference, slots: AppearancePartKind.hair.slots),
                                   "host's own hair measured")
        let host = try await VRMModel.load(from: sonyaURL, device: device)
        let baseMeshes = host.meshes.count
        try VRMPartGrafter.graft(.hair, from: donor, donorSlug: "ekaterina", onto: host)
        host.updateNodeTransforms()
        let grafted = try #require(
            partBounds(host, slots: AppearancePartKind.hair.slots, fromMesh: baseMeshes))

        // Unfitted, Ekaterina's hair sits ~3 cm below the top of Sonya's own
        // hair and is ~20% narrower, which leaves her scalp showing through.
        #expect(grafted.max.y > ownHair.max.y - 0.02,
                "grafted hair reaches the top of the head: \(grafted.max.y) vs \(ownHair.max.y)")
        let graftedWidth = grafted.max.x - grafted.min.x
        let ownWidth = ownHair.max.x - ownHair.min.x
        #expect(graftedWidth > ownWidth * 0.9, "wide enough to cover: \(graftedWidth) vs \(ownWidth)")
    }

    @Test("A grafted shoe takes the host's bare foot out from under it")
    @MainActor
    func shoeTrimsTheFootBeneathIt() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
            let sonyaURL = Bundle.main.url(forResource: "Sonya", withExtension: "vrm"),
            let donorItem = PartsLibrary.shared.item(slug: "lib:casual__shoes"),
            let donorURL = try? await donorItem.resolvedURL()
        else { return }
        let host = try await VRMModel.load(from: sonyaURL, device: device)
        let donor = try await VRMModel.load(from: donorURL, device: device)
        host.beginComposition()

        let before = try #require(skinFloorSamples(host))
        #expect(before > 0, "Sonya draws a bare foot before anything is grafted")

        try VRMPartGrafter.graft(.shoes, from: donor, donorSlug: "lib:casual__shoes", onto: host)
        host.updateNodeTransforms()
        let after = skinFloorSamples(host) ?? 0
        // The foot under the shoe is gone; the leg above the collar stays.
        #expect(after < before / 4, "foot skin removed: \(after) of \(before) samples left")

        host.restoreBaseComposition()
        let restored = skinFloorSamples(host) ?? 0
        #expect(restored == before, "restore puts the whole foot back")
    }

    /// How many sampled body-skin positions sit in the bottom 4% of the
    /// model — the foot, and nothing else.
    @MainActor
    private func skinFloorSamples(_ model: VRMModel) -> Int? {
        let whole = model.calculateBoundingBox()
        let cut = whole.min.y + (whole.max.y - whole.min.y) * 0.04
        var count = 0
        for mesh in model.meshes {
            for primitive in mesh.primitives {
                guard let m = primitive.materialIndex,
                    model.slot(ofMaterial: m) == .bodySkin,
                    !model.hiddenPrimitives.contains(ObjectIdentifier(primitive))
                else { continue }
                primitive.forEachRestPosition(budget: 20_000) { position in
                    if position.y < cut { count += 1 }
                }
            }
        }
        return count
    }

    @Test("A grafted shoe's sole lands on the floor the host stands on",
          arguments: [("Sonya", false), ("Sonya", true), ("Ekaterina", true)])
    @MainActor
    func shoesMeetTheFloor(hostName: String, posed: Bool) async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
            let hostURL = Bundle.main.url(forResource: hostName, withExtension: "vrm")
        else { return }
        // The reference wears its OWN shoes under the SAME pose, so the
        // comparison holds whatever the skeleton is doing.
        let reference = try await VRMModel.load(from: hostURL, device: device)
        if posed { poseOffBindPose(reference) }
        reference.updateNodeTransforms()
        let floor = try #require(
            partBounds(reference, slots: AppearancePartKind.shoes.slots)).min.y

        var checked = 0
        for stem in ["casual", "classic", "bunny_girl"] {
            guard let item = PartsLibrary.shared.item(slug: "lib:\(stem)__shoes"),
                let url = try? await item.resolvedURL() else { continue }
            let host = try await VRMModel.load(from: hostURL, device: device)
            let donor = try await VRMModel.load(from: url, device: device)
            // `VRMMetalState.display` starts the idle animation BEFORE the
            // saved look is applied, so a graft always runs on a skeleton
            // that has already moved off its bind pose. Grounding that read
            // `node.worldPosition` measured that moved ankle against
            // rest-space geometry and drove the shoes underground.
            if posed { poseOffBindPose(host) }
            host.updateNodeTransforms()
            let baseMeshes = host.meshes.count
            try VRMPartGrafter.graft(.shoes, from: donor, donorSlug: item.donorSlug, onto: host)
            host.updateNodeTransforms()
            let shoe = try #require(
                partBounds(host, slots: AppearancePartKind.shoes.slots, fromMesh: baseMeshes))
            #expect(abs(shoe.min.y - floor) < 0.015,
                    "\(hostName) posed=\(posed) + \(stem): sole \(shoe.min.y), floor \(floor)")
            checked += 1
        }
        #expect(checked > 0, "at least one donor was available")
    }

    /// Moves the skeleton off its bind pose the way the idle animation has
    /// by the time a graft runs.
    @MainActor
    private func poseOffBindPose(_ model: VRMModel) {
        guard let humanoid = model.humanoid else { return }
        for bone in [VRMHumanoidBone.leftUpperLeg, .rightUpperLeg] {
            guard let index = humanoid.getBoneNode(bone), index < model.nodes.count else { continue }
            let node = model.nodes[index]
            node.rotation = simd_quatf(angle: 0.15, axis: SIMD3<Float>(1, 0, 0)) * node.rotation
            node.updateLocalMatrix()
        }
        if let hips = humanoid.getBoneNode(.hips), hips < model.nodes.count {
            model.nodes[hips].translation.y -= 0.06
            model.nodes[hips].updateLocalMatrix()
        }
        model.updateNodeTransforms()
    }

    @Test("A garment's rest box covers the garment, not the whole body")
    @MainActor
    func slotBoundsFollowTheIndices() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
            let url = Bundle.main.url(forResource: "Sonya", withExtension: "vrm")
        else { return }
        let model = try await VRMModel.load(from: url, device: device)
        let whole = model.calculateBoundingBox()
        let height = whole.max.y - whole.min.y
        #expect(height > 1)
        let tops = try #require(model.restBounds(ofSlots: AppearancePartKind.tops.slots))
        let shoes = try #require(model.restBounds(ofSlots: AppearancePartKind.shoes.slots))
        // VRoid merges a whole body into one vertex array and slices it per
        // primitive with indices. Reading that array directly makes every
        // garment report the entire model, which framed thumbnails on the
        // whole character instead of the shirt.
        #expect((tops.max.y - tops.min.y) < height * 0.45, "the shirt is not the whole body")
        #expect((shoes.max.y - shoes.min.y) < height * 0.2, "the shoes are not the whole body")
        #expect(shoes.max.y < whole.min.y + height * 0.2, "the shoes sit at the floor")
    }

    @Test("Shoes are resized to the foot they move to, the same way hair is")
    @MainActor
    func shoesFitTheNewFoot() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
            let sonyaURL = Bundle.main.url(forResource: "Sonya", withExtension: "vrm"),
            let ekURL = Bundle.main.url(forResource: "Ekaterina", withExtension: "vrm")
        else { return }
        let donor = try await VRMModel.load(from: ekURL, device: device)
        let host = try await VRMModel.load(from: sonyaURL, device: device)
        let donorFoot = try #require(donor.referenceFootLength)
        let hostFoot = try #require(host.referenceFootLength)
        let ratio = hostFoot / donorFoot
        #expect(ratio > 1.1, "Sonya's foot is meaningfully longer: \(ratio)")

        donor.updateNodeTransforms()
        let donorShoes = try #require(partBounds(donor, slots: AppearancePartKind.shoes.slots))
        let baseMeshes = host.meshes.count
        try VRMPartGrafter.graft(.shoes, from: donor, donorSlug: "ekaterina", onto: host)
        host.updateNodeTransforms()
        let grafted = try #require(
            partBounds(host, slots: AppearancePartKind.shoes.slots, fromMesh: baseMeshes))

        // The shoe grew roughly in step with the foot it now sits on.
        let donorLength = donorShoes.max.z - donorShoes.min.z
        let graftedLength = grafted.max.z - grafted.min.z
        #expect(donorLength > 0.01 && graftedLength > 0.01)
        let grew = graftedLength / donorLength
        #expect(grew > 1.1 && grew < ratio * 1.25, "shoe scaled with the foot: \(grew) vs \(ratio)")
    }

    @Test("Clothes are never resized — they are skinned across the body and fit already")
    @MainActor
    func clothesAreNotResized() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
            let sonyaURL = Bundle.main.url(forResource: "Sonya", withExtension: "vrm"),
            let ekURL = Bundle.main.url(forResource: "Ekaterina", withExtension: "vrm")
        else { return }
        let donor = try await VRMModel.load(from: ekURL, device: device)
        let host = try await VRMModel.load(from: sonyaURL, device: device)
        donor.updateNodeTransforms()
        let slots = AppearancePartKind.tops.slots
        guard let donorTop = partBounds(donor, slots: slots) else { return }
        let baseMeshes = host.meshes.count
        try VRMPartGrafter.graft(.tops, from: donor, donorSlug: "ekaterina", onto: host)
        host.updateNodeTransforms()
        let grafted = try #require(partBounds(host, slots: slots, fromMesh: baseMeshes))
        let donorHeight = donorTop.max.y - donorTop.min.y
        let graftedHeight = grafted.max.y - grafted.min.y
        #expect(abs(graftedHeight - donorHeight) < donorHeight * 0.25,
                "a top keeps its own size: \(graftedHeight) vs \(donorHeight)")
    }

    @Test("Library hair parts carry the head they were cut from")
    @MainActor
    func partsRecordTheirHeadSize() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var checked = 0
        for item in PartsLibrary.shared.items where item.kind == .hair {
            guard let url = try? await item.resolvedURL() else { continue }
            let model = try await VRMModel.load(from: url, device: device)
            #expect(model.restBounds(ofSlots: [.faceSkin]) == nil, "\(item.stem) keeps no face geometry")
            let head = try #require(model.referenceHeadSize, "\(item.stem) records its head size")
            #expect(head.x > 0.05 && head.x < 0.6, "\(item.stem) head size is plausible: \(head)")
            checked += 1
            if checked >= 4 { break }
        }
        #expect(checked > 0)
    }

    @Test("Spring buffers are resized for the grafted chains before they are filled")
    @MainActor
    func springBuffersTrackTheGraft() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
            let hostURL = Bundle.main.url(forResource: "Sonya", withExtension: "vrm"),
            let item = PartsLibrary.shared.item(slug: "lib:school_uniform__hair")
        else { return }
        let host = try await VRMModel.load(from: hostURL, device: device)
        let donor = try await VRMModel.load(from: item.resolvedURL(), device: device)
        let baseJoints = host.springBoneJointCount
        #expect(host.springBoneBuffersMatchSprings, "a freshly loaded model is consistent")

        try VRMPartGrafter.graft(.hair, from: donor, donorSlug: item.donorSlug, onto: host)
        #expect(host.springBoneJointCount > baseJoints, "the donor's chains came along")
        #expect(!host.springBoneBuffersMatchSprings,
                "buffers are stale until something re-allocates them — filling them here would write out of bounds")

        // Both paths that fill those buffers must re-allocate first. This is
        // the crash the repeated graft/restore cycle used to hit.
        let renderer = VRMRenderer(device: device, config: RendererConfig(strict: .off))
        renderer.loadModel(host)
        #expect(host.springBoneBuffersMatchSprings, "loadModel re-allocated for the grafted chains")

        renderer.refreshModelStructure()
        #expect(host.springBoneBuffersMatchSprings)

        host.restoreBaseComposition()
        #expect(host.springBoneJointCount == baseJoints)
        renderer.refreshModelStructure()
        #expect(host.springBoneBuffersMatchSprings, "and shrank again on restore")
    }

    @Test("Swapping parts repeatedly leaves the model consistent")
    @MainActor
    func repeatedSwapsStayConsistent() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
            let hostURL = Bundle.main.url(forResource: "Sonya", withExtension: "vrm")
        else { return }
        let host = try await VRMModel.load(from: hostURL, device: device)
        let renderer = VRMRenderer(device: device, config: RendererConfig(strict: .off))
        renderer.loadModel(host)
        let baseMeshes = host.meshes.count
        let baseNodes = host.nodes.count
        let baseJoints = host.springBoneJointCount

        var donors: [(String, VRMModel)] = []
        for stem in ["goth", "casual", "school_uniform"] {
            guard let item = PartsLibrary.shared.item(slug: "lib:\(stem)__hair") else { continue }
            donors.append((stem, try await VRMModel.load(from: item.resolvedURL(), device: device)))
        }
        guard !donors.isEmpty else { return }

        // Two rounds of what the picker does on every tap.
        for _ in 0..<2 {
            for (stem, donor) in donors {
                host.restoreBaseComposition()
                try VRMPartGrafter.graft(.hair, from: donor, donorSlug: stem, onto: host)
                renderer.refreshModelStructure()
                #expect(host.springBoneBuffersMatchSprings, "\(stem): buffers match after the swap")
                for skin in host.skins {
                    #expect(skin.joints.count == skin.inverseBindMatrices.count)
                    #expect(skin.joints.allSatisfy { joint in host.nodes.contains { $0 === joint } })
                }
                for spring in host.springBone?.springs ?? [] {
                    for joint in spring.joints { #expect(joint.node < host.nodes.count) }
                }
            }
        }
        host.restoreBaseComposition()
        renderer.refreshModelStructure()
        #expect(host.meshes.count == baseMeshes)
        #expect(host.nodes.count == baseNodes)
        #expect(host.springBoneJointCount == baseJoints)
        #expect(host.hiddenPrimitives.isEmpty)
    }

    @Test("Spring colliders come with the hair so it can't pass through the head")
    @MainActor
    func collidersSurvive() async throws {
        guard let device = MTLCreateSystemDefaultDevice(),
            let hostURL = Bundle.main.url(forResource: "Sonya", withExtension: "vrm"),
            let item = PartsLibrary.shared.item(slug: "lib:school_uniform__hair")
        else { return }
        let host = try await VRMModel.load(from: hostURL, device: device)
        let donor = try await VRMModel.load(from: item.resolvedURL(), device: device)
        let donorGroups = (donor.springBone?.springs ?? []).reduce(0) { $0 + $1.colliderGroups.count }
        guard donorGroups > 0 else { return }

        let baseColliders = host.springBone?.colliders.count ?? 0
        let receipt = try VRMPartGrafter.graft(.hair, from: donor, donorSlug: item.donorSlug, onto: host)
        let spring = try #require(host.springBone)
        let appendedSprings = spring.springs.suffix(receipt.springCount)
        #expect(appendedSprings.contains { !$0.colliderGroups.isEmpty }, "grafted springs kept their collider groups")
        #expect(spring.colliders.count > baseColliders, "the donor's colliders were re-homed")
        for group in appendedSprings.flatMap(\.colliderGroups) {
            #expect(group < spring.colliderGroups.count)
            for collider in spring.colliderGroups[group].colliders {
                #expect(collider < spring.colliders.count)
                #expect(spring.colliders[collider].node < host.nodes.count)
            }
        }
    }
}
