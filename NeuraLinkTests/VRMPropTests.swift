//
//  VRMPropTests.swift
//  NeuraLinkTests
//
//  The phone prop: loads from the bundle, hangs off the right hand of both
//  bundled characters at life size, hides without disturbing the figure's
//  bounds, takes the renderer's rigid path, and survives a composition
//  restore whichever side of the snapshot it was attached on.
//

import CoreGraphics
import Foundation
import Metal
import Testing
import UIKit
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

            // Sized for the hand: transform the raw vertices by the node's
            // world matrix and measure along the phone's own axes (the grip
            // tilts it obliquely, so a world-aligned box would not do).
            model.updateNodeTransforms()
            var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            var worldLow = low, worldHigh = high
            for (node, mesh) in zip(attachment.nodes, attachment.meshes) {
                let m = node.worldMatrix
                let axes = [m.columns.0, m.columns.1, m.columns.2].map { simd_normalize(SIMD3($0.x, $0.y, $0.z)) }
                let origin = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
                for primitive in mesh.primitives {
                    guard let buffer = primitive.vertexBuffer else { continue }
                    let vertices = buffer.contents().bindMemory(to: VRMVertex.self, capacity: primitive.vertexCount)
                    for index in 0..<primitive.vertexCount {
                        let p = vertices[index].position
                        let world4 = m * SIMD4<Float>(p.x, p.y, p.z, 1)
                        let world = SIMD3(world4.x, world4.y, world4.z)
                        worldLow = min(worldLow, world)
                        worldHigh = max(worldHigh, world)
                        let local = SIMD3(simd_dot(world - origin, axes[0]), simd_dot(world - origin, axes[1]), simd_dot(world - origin, axes[2]))
                        low = min(low, local)
                        high = max(high, local)
                    }
                }
            }
            let longest = (high - low).max()
            let expected = 0.147 * VRMMetalState.phoneGrip.scale
            #expect(abs(longest - expected) < 0.004, "\(character): longest side in hand \(longest) m, expected \(expected)")
            let centre = (worldLow + worldHigh) * 0.5
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

    @Test("Shown, the phone is actually drawn through the rigid path; hidden, the frame is unchanged")
    func drawsThroughRigidPath() async throws {
        guard let device = MTLCreateSystemDefaultDevice(), let thumbnails = VRMPartThumbnailRenderer(size: 256) else { return }
        let prop = try await Self.loadProp(device)
        let model = try await Self.loadModel("Sonya", device)
        // A grip chosen for visibility, not the shipped one: in the T-pose this
        // renders, the shipped grip lays the phone flat along the outstretched
        // arm and the level camera sees only its edge. Upright, 10 cm below
        // the hand, it stands clear of the body as a full rectangle.
        let visibleGrip = VRMPropGrip(
            translation: SIMD3<Float>(0, -0.1, 0), rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
        let attachment = try model.attachProp(prop, to: .rightHand, grip: visibleGrip)
        let before = try #require(thumbnails.render(model: model, subject: .figure)?.cgImage)
        model.setProp(attachment, visible: true)
        let after = try #require(thumbnails.render(model: model, subject: .figure)?.cgImage)
        #expect(before.width == after.width && before.height == after.height)
        let changed = Self.differingPixels(before, after)
        #expect(changed > 40, "a visible phone must change pixels — got \(changed)")
    }

    private static func differingPixels(_ a: CGImage, _ b: CGImage) -> Int {
        func bytes(_ image: CGImage) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
            out.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return out
        }
        let first = bytes(a), second = bytes(b)
        guard first.count == second.count else { return Int.max }
        var count = 0
        for pixel in stride(from: 0, to: first.count, by: 4) {
            let delta = abs(Int(first[pixel]) - Int(second[pixel])) + abs(Int(first[pixel + 1]) - Int(second[pixel + 1]))
                + abs(Int(first[pixel + 2]) - Int(second[pixel + 2])) + abs(Int(first[pixel + 3]) - Int(second[pixel + 3]))
            if delta > 24 { count += 1 }
        }
        return count
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

        // Attached before the snapshot: part of the base, untouched by restore
        // — and not appended a second time.
        let early = try await Self.loadModel("Sonya", device)
        let earlyAttachment = try early.attachProp(prop, to: .rightHand, grip: VRMMetalState.phoneGrip)
        let earlyNodes = earlyAttachment.nodes
        let earlyHand = early.nodes[try #require(early.humanoid?.getBoneNode(.rightHand))]
        let counts = (early.nodes.count, early.meshes.count, early.materials.count, earlyHand.children.count)
        early.beginComposition()
        early.restoreBaseComposition()
        #expect(earlyAttachment.nodes.elementsEqual(earlyNodes, by: ===), "the same nodes, not fresh ones")
        #expect(earlyAttachment.nodes.allSatisfy { node in early.nodes.contains { $0 === node } })
        #expect((early.nodes.count, early.meshes.count, early.materials.count, earlyHand.children.count) == counts,
                "nothing appended twice")

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
