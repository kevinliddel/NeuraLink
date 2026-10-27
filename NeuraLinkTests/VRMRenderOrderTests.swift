//
//  VRMRenderOrderTests.swift
//  NeuraLinkTests
//
//  Draw order from the materials as authored: VRM 1.0 render queues
//  (VRMC_materials_mtoon), and the draw list Unity and three-vrm use —
//  depth-writing parts first, then transparents by queue and back to front
//  by what each primitive draws. No material name decides anything.
//
//  Created by Dedicatus on 23/10/2026.
//

import Foundation
import Metal
import simd
import Testing
@testable import NeuraLink

@MainActor
@Suite("VRM render order")
struct VRMRenderOrderTests {

    // MARK: - VRM 1.0 render queue

    private func material(alphaMode: String, mtoon: String) throws -> VRMMaterial {
        let json = "{\"name\": \"Part\", \"alphaMode\": \"\(alphaMode)\", \"extensions\": {\"VRMC_materials_mtoon\": {\(mtoon)}}}"
        let gltf = try JSONDecoder().decode(GLTFMaterial.self, from: Data(json.utf8))
        return VRMMaterial(from: gltf, textures: [], vrm0MaterialProperty: nil, vrmVersion: .v1_0)
    }

    @Test("Queue per alpha mode, offset clamped to its range", arguments: [
        ("OPAQUE", "\"renderQueueOffsetNumber\": 5", 2000),
        ("MASK", "\"renderQueueOffsetNumber\": -5", 2450),
        ("BLEND", "\"specVersion\": \"1.0\"", 3000),
        ("BLEND", "\"renderQueueOffsetNumber\": -3", 2997),
        ("BLEND", "\"renderQueueOffsetNumber\": -20", 2991),
        ("BLEND", "\"renderQueueOffsetNumber\": 4", 3000),
        ("BLEND", "\"transparentWithZWrite\": true", 2501),
        ("BLEND", "\"transparentWithZWrite\": true, \"renderQueueOffsetNumber\": 3", 2504),
        ("BLEND", "\"transparentWithZWrite\": true, \"renderQueueOffsetNumber\": -3", 2501)
    ])
    func renderQueue(alphaMode: String, mtoon: String, expected: Int) throws {
        #expect(try material(alphaMode: alphaMode, mtoon: mtoon).renderQueue == expected)
    }

    // MARK: - Draw list order

    @Test("Depth-writing parts first, then transparents by queue, far to near")
    func drawListOrder() async throws {
        let harness = try #require(VRMRenderHarness())
        let model = try await harness.load(SyntheticVRM(material: SyntheticVRM.mtoon()))
        let renderer = harness.renderer
        renderer.loadModel(model)
        defer { renderer.clearModel() }
        let eye = SIMD3<Float>(0, 1, 2)
        renderer.viewMatrix = OrthographicCamera.makeLookAt(eye: eye, target: [0, 1, 0], up: [0, 1, 0])
        let base = try #require(renderer.buildRenderItems(model: model).first)

        func item(_ name: String, _ alphaMode: String, queue: Int, z: Float, index: Int) -> VRMRenderer.RenderItem {
            VRMRenderer.RenderItem(
                node: base.node, mesh: base.mesh, primitive: base.primitive, materialName: name,
                meshIndex: base.meshIndex, alphaMode: alphaMode, doubleSided: false, alphaCutoff: 0.5,
                materialRenderQueue: queue, transparentZWrite: false, primitiveIndex: index,
                primIdxInMesh: 0, boundsCentre: [0, 1, z])
        }
        // Distances are measured from the eye here, not in view space.
        let near: Float = 0.5, far: Float = -0.5
        #expect(simd_distance(eye, [0, 1, far]) > simd_distance(eye, [0, 1, near]))
        var items = [
            item("lashNear", "blend", queue: 3000, z: near, index: 0),
            item("iris", "blend", queue: 2997, z: near, index: 1),
            item("skin", "mask", queue: 2450, z: 0, index: 2),
            item("browFar", "blend", queue: 3000, z: far, index: 3),
            item("body", "opaque", queue: 2000, z: 0, index: 4)
        ]
        renderer.sortRenderItems(&items)
        #expect(items.map(\.materialName) == ["body", "skin", "iris", "browFar", "lashNear"])
    }
}
