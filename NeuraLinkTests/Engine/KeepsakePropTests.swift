//
//  KeepsakePropTests.swift
//  NeuraLinkTests
//
//  A room that remembers — the engine side: the procedural geometry winds
//  outward, the factory builds every object at table size, and a standing
//  prop joins the draw list without becoming part of the figure.
//
//  Created by Dedicatus on 05/11/2026.
//

import Foundation
import Metal
import simd
import Testing
@testable import NeuraLink

@MainActor
struct KeepsakePropTests {

    @Test func boxFacesWindOutward() {
        var builder = PropMeshBuilder()
        builder.addBox(centre: [0, 0.5, 0], size: [0.2, 1, 0.4])
        #expect(builder.vertices.count == 24 && builder.indices.count == 36)
        #expect(simd_distance(builder.extent, SIMD3<Float>(0.2, 1, 0.4)) < 1e-6)
        #expect(builder.low.y == 0)
        expectOutwardWinding(builder)
    }

    @Test func cylinderSidesAreSmoothAndOutward() {
        var builder = PropMeshBuilder()
        builder.addCylinder(bottom: 0.1, top: 0.4, bottomRadius: 0.05, topRadius: 0.08, segments: 12)
        #expect(abs(builder.extent.y - 0.3) < 1e-6 && abs(builder.extent.x - 0.16) < 1e-5)
        for vertex in builder.vertices { #expect(abs(simd_length(vertex.normal) - 1) < 1e-4) }
        expectOutwardWinding(builder)
        // The sides come first (12 segments × 4 vertices); on a pot that
        // widens upward their normals tilt down.
        #expect(builder.vertices.prefix(48).allSatisfy { $0.normal.y < 0 })
    }

    @Test func centredCropKeepsTheMiddleOfThePicture() {
        let wide = PropMeshBuilder.UVRect.centred(pictureAspect: 2, opening: 1)
        #expect(abs(wide.u0 - 0.25) < 1e-6 && abs(wide.u1 - 0.75) < 1e-6 && wide.v0 == 0 && wide.v1 == 1)
        let tall = PropMeshBuilder.UVRect.centred(pictureAspect: 0.5, opening: 1)
        #expect(abs(tall.v0 - 0.25) < 1e-6 && tall.u0 == 0 && tall.u1 == 1)
        let cell = PropMeshBuilder.UVRect.cell(2, 1, columns: 3, rows: 2)
        #expect(abs(cell.u0 - 2 / 3) < 1e-6 && cell.v0 == 0.5 && cell.u1 == 1 && cell.v1 == 1)
    }

    @Test func factoryBuildsTheTableAndEveryObjectAtTableSize() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let table = try #require(KeepsakePropFactory.table(device: device))
        #expect(abs(table.extent.y - KeepsakeRoomRules.tableHeight) < 1e-5)
        #expect(abs(table.extent.x - 2 * KeepsakeRoomRules.tableRadius) < 1e-4)
        let now = Date()
        let objects: [RoomObject] = [
            RoomObject(kind: .card, milestone: .firstConversation, achievedAt: now),
            RoomObject(kind: .frame, milestone: .firstDiary, achievedAt: now),
            RoomObject(kind: .polaroid, milestone: .firstPhoto, achievedAt: now),
            RoomObject(kind: .sleeve, milestone: .firstSharedSong, achievedAt: now, note: "Blue Train — John Coltrane"),
            RoomObject(kind: .die, milestone: .firstGame, achievedAt: now),
            RoomObject(kind: .plant, milestone: .sevenDays, achievedAt: now, stage: 1),
            RoomObject(kind: .plant, milestone: .hundredDays, achievedAt: now, stage: 3)
        ]
        for object in objects {
            let built = await KeepsakePropFactory.prop(for: object, picture: nil, characterName: "Sonya", device: device)
            let prop = try #require(built, "\(object.kind) stage \(object.stage)")
            #expect(!prop.parts.isEmpty)
            #expect(prop.extent.x < 0.2 && prop.extent.z < 0.2 && prop.extent.y < 0.3, "\(object.kind) is too big for the table")
            #expect(prop.extent.y > 0.01)
            // Shade indices name the prop's own textures, which placement moves.
            for material in prop.materials {
                if let index = material.mtoon?.shadeMultiplyTexture { #expect(index < prop.textures.count) }
            }
        }
    }

    @Test func aPictureGoesIntoTheFrameAndNoneMakesANotebook() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let object = RoomObject(kind: .frame, milestone: .firstDiary, achievedAt: Date(), note: "journal-1.jpg")
        let framed = await KeepsakePropFactory.prop(
            for: object, picture: KeepsakeArt.blankPolaroid(), characterName: "Sonya", device: device)
        #expect(framed?.name == "keepsake_frame")
        #expect(framed?.parts.count == 2)
        let notebook = await KeepsakePropFactory.prop(for: object, picture: nil, characterName: "Sonya", device: device)
        #expect(notebook?.name == "keepsake_notebook")
    }

    @Test func standingPropsJoinTheDrawListAndNotTheFigure() async throws {
        guard let harness = VRMRenderHarness(size: 32) else { return }
        let model = try await harness.load(SyntheticVRM(material: SyntheticVRM.mtoon()))
        let table = try #require(KeepsakePropFactory.table(device: harness.device))
        let nodesBefore = model.nodes.count
        let boundsBefore = model.calculateBoundingBox()
        let itemsBefore = harness.renderer.buildRenderItems(model: model).count
        let world = RestTransform(
            rotation: simd_quatf(angle: 0, axis: [0, 1, 0]), translation: [-0.5, 0, -0.4], scale: [1, 1, 1])
        let placement = model.placeProp(table, at: world)
        #expect(model.nodes.count == nodesBefore + table.parts.count)
        #expect(placement.nodes.allSatisfy { $0.parent == nil })
        let boundsAfter = model.calculateBoundingBox()
        #expect(simd_distance(boundsAfter.min, boundsBefore.min) < 1e-6 && simd_distance(boundsAfter.max, boundsBefore.max) < 1e-6)
        #expect(harness.renderer.buildRenderItems(model: model).count == itemsBefore + table.parts.count)
        #expect(simd_distance(placement.nodes[0].worldPosition, [-0.5, 0, -0.4]) < 1e-5)

        // The heel lift raises the figure, not the table.
        VRMPartGrafter.raiseFigure(by: 0.02, in: model)
        #expect(abs(placement.nodes[0].worldPosition.y) < 1e-6)
        VRMPartGrafter.lowerFigure(in: model)

        model.moveSceneProp(placement, to: RestTransform(rotation: world.rotation, translation: [0.3, 0, 0.1], scale: [1, 1, 1]))
        #expect(simd_distance(placement.nodes[0].worldPosition, [0.3, 0, 0.1]) < 1e-5)
        model.setSceneProp(placement, visible: false)
        #expect(harness.renderer.buildRenderItems(model: model).count == itemsBefore)
        model.removeSceneProp(placement)
        #expect(model.sceneProps.isEmpty && model.scenePropNodeIDs.isEmpty)
    }

    @Test func vrm0NodesArePreYawedBackIntoPlace() {
        let world = RestTransform(rotation: simd_quatf(angle: 0, axis: [0, 1, 0]), translation: [1, 0, 2], scale: [1, 1, 1])
        let node = VRMModel.modelSpace(world, isVRM0: true)
        #expect(simd_distance(node.translation, [-1, 0, -2]) < 1e-5)
        // The renderer's own yaw then puts it where the world placement says.
        #expect(simd_distance(VRMModel.vrmVersionYaw.act(node.translation), [1, 0, 2]) < 1e-5)
        #expect(VRMModel.modelSpace(world, isVRM0: false).translation == world.translation)
    }

    private func expectOutwardWinding(_ builder: PropMeshBuilder) {
        let vertices = builder.vertices, indices = builder.indices
        for triangle in stride(from: 0, to: indices.count, by: 3) {
            let a = vertices[Int(indices[triangle])]
            let b = vertices[Int(indices[triangle + 1])]
            let c = vertices[Int(indices[triangle + 2])]
            let geometric = simd_cross(b.position - a.position, c.position - a.position)
            #expect(simd_dot(geometric, a.normal + b.normal + c.normal) > 0)
        }
    }
}
