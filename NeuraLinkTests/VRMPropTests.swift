//
//  VRMPropTests.swift
//  NeuraLinkTests
//
//  The phone prop: loads from the bundle, hangs off the right hand of both
//  bundled characters at life size, hides without disturbing the figure's
//  bounds, takes the renderer's rigid path, and survives a composition
//  restore whichever side of the snapshot it was attached on.
//

import Foundation
import Metal
import Testing
import simd

@testable import NeuraLink

@MainActor
@Suite("Phone prop", .serialized)
struct VRMPropTests {

    private static let characters = ["Sonya", "Ekaterina"]

    private static func loadProp(_ device: MTLDevice) async throws -> VRMProp {
        let url = try #require(Bundle.main.url(forResource: VRMMetalState.phonePropName, withExtension: "glb"))
        return try await VRMPropLoader.load(url: url, device: device, maxTextureSize: 256)
    }

    private static func loadModel(_ name: String, _ device: MTLDevice) async throws -> VRMModel {
        let url = try #require(Bundle.main.url(forResource: name, withExtension: "vrm"))
        return try await VRMModel.load(from: url, device: device)
    }

    @Test("The phone loads life-size, with capped textures and a screen that keeps its glow")
    func loads() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let prop = try await Self.loadProp(device)
        #expect(prop.parts.count == 3, "shell, screen and glass")
        let sorted = [prop.extent.x, prop.extent.y, prop.extent.z].sorted()
        #expect(abs(sorted[2] - 0.147) < 0.004, "long side \(sorted[2]) m")
        #expect(abs(sorted[1] - 0.0735) < 0.004, "width \(sorted[1]) m")
        #expect(sorted[0] < 0.01, "thickness \(sorted[0]) m")
        #expect(prop.materials.allSatisfy { $0.preservesEmissive && $0.vrmVersion == .v1_0 })
        let loaded = prop.textures.compactMap(\.mtlTexture)
        #expect(loaded.count == 6, "base colour ×3, normal ×2, emissive ×1 — occlusion/MR stay unloaded")
        #expect(loaded.allSatisfy { $0.width <= 256 && $0.mipmapLevelCount > 1 })
    }

    @Test("Attaches hidden under the right hand, life-size, without inflating the bounds")
    func attaches() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let prop = try await Self.loadProp(device)
        for character in Self.characters {
            let model = try await Self.loadModel(character, device)
            let before = model.calculateBoundingBox()
            let attachment = try model.attachProp(prop, to: .rightHand, grip: VRMMetalState.phoneGrip)
            let handIndex = try #require(model.humanoid?.getBoneNode(.rightHand))
            let hand = model.nodes[handIndex]

            #expect(attachment.nodes.count == prop.parts.count)
            #expect(attachment.nodes.allSatisfy { $0.parent === hand })
            #expect(attachment.nodes.allSatisfy { node in hand.children.contains { $0 === node } })
            #expect(attachment.nodes.allSatisfy { $0.mesh == nil }, "\(character): hidden on attach")

            let hidden = model.calculateBoundingBox()
            #expect(simd_length(hidden.min - before.min) < 1e-5 && simd_length(hidden.max - before.max) < 1e-5,
                    "\(character): a hidden prop leaves the bounds alone")
            model.setProp(attachment, visible: true)
            #expect(attachment.nodes.allSatisfy { $0.mesh != nil })
            let shown = model.calculateBoundingBox()
            #expect(simd_length(shown.max - before.max) < 1e-5, "\(character): prop vertices never count towards the figure")

            // Life-size in the hand: transform the raw vertices by the node's
            // world matrix and measure.
            model.updateNodeTransforms()
            var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for (node, mesh) in zip(attachment.nodes, attachment.meshes) {
                for primitive in mesh.primitives {
                    guard let buffer = primitive.vertexBuffer else { continue }
                    let vertices = buffer.contents().bindMemory(to: VRMVertex.self, capacity: primitive.vertexCount)
                    for index in 0..<primitive.vertexCount {
                        let p = vertices[index].position
                        let world = node.worldMatrix * SIMD4<Float>(p.x, p.y, p.z, 1)
                        low = min(low, SIMD3(world.x, world.y, world.z))
                        high = max(high, SIMD3(world.x, world.y, world.z))
                    }
                }
            }
            let longest = (high - low).max()
            #expect(abs(longest - 0.147) < 0.004, "\(character): longest side in hand \(longest) m")
            let centre = (low + high) * 0.5
            #expect(simd_length(centre - hand.worldPosition) < 0.12, "\(character): the phone sits at the hand, not across the room")
        }
    }

    @Test("Shown, every prop primitive takes the renderer's rigid path; hidden, none is drawn")
    func rigidPath() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let prop = try await Self.loadProp(device)
        let model = try await Self.loadModel("Sonya", device)
        let attachment = try model.attachProp(prop, to: .rightHand, grip: VRMMetalState.phoneGrip)
        let renderer = VRMRenderer(device: device, config: RendererConfig(strict: .off))
        renderer.loadModel(model)
        let propNodes = Set(attachment.nodes.map { ObjectIdentifier($0) })

        let hiddenItems = renderer.buildRenderItems(model: model).filter { propNodes.contains(ObjectIdentifier($0.node)) }
        #expect(hiddenItems.isEmpty)

        model.setProp(attachment, visible: true)
        renderer.invalidateRenderItems()
        let items = renderer.buildRenderItems(model: model).filter { propNodes.contains(ObjectIdentifier($0.node)) }
        #expect(items.count == prop.parts.reduce(0) { $0 + $1.mesh.primitives.count })
        #expect(items.allSatisfy { $0.node.skin == nil && !$0.primitive.hasJoints }, "no skin, no joints → rigid branch")
        #expect(items.allSatisfy { !$0.isFaceMaterial && !$0.isEyeMaterial }, "phone names must not trip the face heuristics")
    }

    @Test("The grip lands the same way on VRM 0.x and 1.x once the renderer's yaw is applied")
    func gripMirrors() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let prop = try await Self.loadProp(device)
        var offsets: [String: SIMD3<Float>] = [:]
        var rotations: [String: simd_quatf] = [:]
        for character in Self.characters {
            let model = try await Self.loadModel(character, device)
            let attachment = try model.attachProp(prop, to: .rightHand, grip: VRMMetalState.phoneGrip)
            model.updateNodeTransforms()
            let handIndex = try #require(model.humanoid?.getBoneNode(.rightHand))
            let node = try #require(attachment.nodes.first)
            let yaw: simd_quatf = model.isVRM0 ? VRMModel.vrmVersionYaw : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            offsets[character] = yaw.act(node.worldPosition - model.nodes[handIndex].worldPosition)
            let m = node.worldMatrix
            let basis = float3x3(
                simd_normalize(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)),
                simd_normalize(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)),
                simd_normalize(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)))
            rotations[character] = simd_normalize(yaw * simd_quatf(basis))
        }
        let a = try #require(offsets["Sonya"]), b = try #require(offsets["Ekaterina"])
        #expect(simd_length(a - b) < 0.005, "render-space offset Sonya \(a) vs Ekaterina \(b)")
        let qa = try #require(rotations["Sonya"]), qb = try #require(rotations["Ekaterina"])
        #expect(abs(simd_dot(qa.vector, qb.vector)) > 0.999, "render-space orientation differs")
    }

    @Test("Survives a composition restore on either side of the snapshot")
    func survivesRestore() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let prop = try await Self.loadProp(device)

        // Attached before the snapshot: part of the base, untouched by restore.
        let early = try await Self.loadModel("Sonya", device)
        let earlyAttachment = try early.attachProp(prop, to: .rightHand, grip: VRMMetalState.phoneGrip)
        early.beginComposition()
        early.restoreBaseComposition()
        #expect(earlyAttachment.nodes.allSatisfy { node in early.nodes.contains { $0 === node } })

        // Attached after the snapshot: truncated with the grafts, put back.
        let late = try await Self.loadModel("Ekaterina", device)
        late.beginComposition()
        let baseNodes = late.nodes.count, baseMeshes = late.meshes.count, baseMaterials = late.materials.count
        let lateAttachment = try late.attachProp(prop, to: .rightHand, grip: VRMMetalState.phoneGrip)
        late.setProp(lateAttachment, visible: true)
        late.restoreBaseComposition()
        let hand = late.nodes[try #require(late.humanoid?.getBoneNode(.rightHand))]
        #expect(lateAttachment.nodes.count == prop.parts.count)
        #expect(lateAttachment.nodes.allSatisfy { node in late.nodes.contains { $0 === node } })
        #expect(lateAttachment.nodes.allSatisfy { $0.parent === hand })
        #expect(lateAttachment.nodes.allSatisfy { node in hand.children.contains { $0 === node } })
        #expect(lateAttachment.nodes.allSatisfy { $0.mesh != nil }, "visibility survives the restore")
        #expect(late.nodes.count == baseNodes + prop.parts.count)
        #expect(late.meshes.count == baseMeshes + prop.parts.count)
        #expect(late.materials.count == baseMaterials + prop.materials.count)
        #expect(lateAttachment.meshes.allSatisfy { mesh in late.meshes.contains { $0 === mesh } })
    }
}
