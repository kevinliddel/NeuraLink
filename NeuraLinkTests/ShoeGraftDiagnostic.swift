//
//  ShoeGraftDiagnostic.swift
//  NeuraLinkTests
//
//  Temporary developer tool: grafts every library shoe onto the bundled
//  characters and writes a picture of the result, so the fit can be looked
//  at rather than inferred from bounding boxes. Set NL_SHOE_DIAG_DIR to run.
//

import Testing
import Foundation
import Metal
import UIKit
import simd
@testable import NeuraLink

@Suite("Shoe graft diagnostic", .serialized)
struct ShoeGraftDiagnostic {

    /// Root local matrices as loaded, so a turn is applied to the rest pose
    /// rather than to the previous turn.
    @MainActor private static var restPose: [ObjectIdentifier: float4x4] = [:]

    @Test("Render grafted shoes when NL_SHOE_DIAG_DIR is set")
    @MainActor
    func render() async throws {
        guard let path = ProcessInfo.processInfo.environment["NL_SHOE_DIAG_DIR"], !path.isEmpty else { return }
        guard let device = MTLCreateSystemDefaultDevice(),
            let renderer = VRMPartThumbnailRenderer(size: 512)
        else { return }
        let outputDir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var report = ""
        Self.restPose = [:]
        let shoeItems = PartsLibrary.shared.items.filter { $0.kind == .shoes }
        for hostName in ["Sonya", "Ekaterina"] {
            guard let hostURL = Bundle.main.url(forResource: hostName, withExtension: "vrm") else { continue }
            for item in shoeItems.prefix(6) {
                let host = try await VRMModel.load(from: hostURL, device: device)
                let donor = try await VRMModel.load(from: item.resolvedURL(), device: device)
                let hostFoot = host.referenceFootLength ?? 0
                let donorFoot = donor.referenceFootLength ?? 0
                host.updateNodeTransforms()
                let ownShoe = skinnedBounds(host, slots: AppearancePartKind.shoes.slots)
                let baseMeshes = host.meshes.count
                try VRMPartGrafter.graft(.shoes, from: donor, donorSlug: item.donorSlug, onto: host)
                host.updateNodeTransforms()

                let skin = bounds(host, slots: [.bodySkin], below: 0.18)
                let shoe = skinnedBounds(
                    host, slots: AppearancePartKind.shoes.slots, fromMesh: baseMeshes)
                report += """
                    == \(hostName) + \(item.modelStem)
                       hostFoot=\(String(format: "%.4f", hostFoot)) \
                    donorFoot=\(String(format: "%.4f", donorFoot)) \
                    ratio=\(String(format: "%.3f", donorFoot > 0 ? hostFoot / donorFoot : 0))
                       ownShoe     = \(describe(ownShoe))
                       graftedShoe = \(describe(shoe))
                       skinBelowAnkle = \(describe(skin))
                       drawn below ankle:
                    \(footPrimitives(host))

                    """

                // Front AND side. A heel left outside the shoe is invisible
                // head-on — the first sheet I judged this on was front-only.
                for (turn, suffix) in [(Float(0), ""), (Float.pi / 2, "_side")] {
                    turnModel(host, by: turn)
                    guard let image = renderer.render(model: host, subject: .shoes),
                        let png = image.pngData() else { continue }
                    try png.write(to: outputDir.appendingPathComponent(
                        "\(hostName.lowercased())_\(item.modelStem)\(suffix).png"), options: .atomic)
                }
                turnModel(host, by: 0)
            }
        }
        try report.write(
            to: outputDir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }

    /// Every primitive still drawn below the ankle, with what it is. This is
    /// what tells a poking foot apart from a shoe that failed to hide.
    @MainActor
    private func footPrimitives(_ model: VRMModel) -> String {
        let whole = model.calculateBoundingBox()
        let cut = whole.min.y + (whole.max.y - whole.min.y) * 0.14
        var lines: [String] = []
        for (meshIndex, mesh) in model.meshes.enumerated() {
            for primitive in mesh.primitives {
                guard !model.hiddenPrimitives.contains(ObjectIdentifier(primitive)),
                    let range = primitive.restHeightRange(), range.min < cut,
                    let materialIndex = primitive.materialIndex
                else { continue }
                let slot = model.slot(ofMaterial: materialIndex)
                let name = model.slotMaterialName(at: materialIndex) ?? "<unnamed>"
                lines.append(String(
                    format: "      mesh %d mat %d %@ y[%.3f,%.3f] %@",
                    meshIndex, materialIndex, slot.rawValue, range.min, range.max, name))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Yaws every root node so the offscreen camera, which is fixed on +Z,
    /// can look at the model from another angle.
    ///
    /// `updateWorldTransform` reads the CACHED `localMatrix`, so setting
    /// `rotation` alone changes nothing — the matrix has to be rebuilt from
    /// the one the model loaded with, or repeated turns compound.
    @MainActor
    private func turnModel(_ model: VRMModel, by radians: Float) {
        let roots = model.nodes.filter { $0.parent == nil }
        // Per NODE, not once for the suite: every combination loads a fresh
        // model, so a cache keyed on the first one's nodes silently left all
        // the others unturned.
        for node in roots where Self.restPose[ObjectIdentifier(node)] == nil {
            Self.restPose[ObjectIdentifier(node)] = node.localMatrix
        }
        var turn = matrix_identity_float4x4
        let c = cos(radians), s = sin(radians)
        turn.columns.0 = SIMD4<Float>(c, 0, -s, 0)
        turn.columns.2 = SIMD4<Float>(s, 0, c, 0)
        for node in roots {
            guard let original = Self.restPose[ObjectIdentifier(node)] else { continue }
            node.localMatrix = turn * original
        }
        model.updateNodeTransforms()
    }

    private func describe(_ box: (min: SIMD3<Float>, max: SIMD3<Float>)?) -> String {
        guard let box else { return "nil" }
        return String(
            format: "x[%.3f,%.3f] y[%.3f,%.3f] z[%.3f,%.3f]",
            box.min.x, box.max.x, box.min.y, box.max.y, box.min.z, box.max.z)
    }

    /// Body-skin geometry under `below` (fraction of model height) — the feet.
    @MainActor
    private func bounds(
        _ model: VRMModel, slots: Set<VRoidMaterialSlot>, below: Float
    ) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        let whole = model.calculateBoundingBox()
        let cut = whole.min.y + (whole.max.y - whole.min.y) * below
        var lo = SIMD3<Float>(repeating: .infinity)
        var hi = SIMD3<Float>(repeating: -.infinity)
        var found = false
        for mesh in model.meshes {
            for primitive in mesh.primitives {
                guard let m = primitive.materialIndex,
                    slots.contains(model.slot(ofMaterial: m)) else { continue }
                primitive.forEachRestPosition(budget: 4_000) { position in
                    guard position.y < cut else { return }
                    lo = simd_min(lo, position)
                    hi = simd_max(hi, position)
                    found = true
                }
            }
        }
        return found ? (lo, hi) : nil
    }

    /// World box of the drawn geometry, skinned by hand. Rest positions are
    /// useless here: grafted geometry keeps the DONOR's vertices and is
    /// placed entirely by its inverse bind matrices, so a rest-space box is
    /// identical whatever the graft did with it.
    @MainActor
    private func skinnedBounds(
        _ model: VRMModel, slots: Set<VRoidMaterialSlot>, fromMesh first: Int = 0
    ) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        guard let pOff = MemoryLayout<VRMVertex>.offset(of: \VRMVertex.position),
            let jOff = MemoryLayout<VRMVertex>.offset(of: \VRMVertex.joints),
            let wOff = MemoryLayout<VRMVertex>.offset(of: \VRMVertex.weights)
        else { return nil }
        let vstride = MemoryLayout<VRMVertex>.stride
        var lo = SIMD3<Float>(repeating: .infinity)
        var hi = SIMD3<Float>(repeating: -.infinity)
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
                var step = max(1, p.indexCount / 900)
                if step % 3 != 0 { step += 3 - (step % 3) }
                for n in Swift.stride(from: 0, to: p.indexCount, by: step) {
                    let vi = p.indexType == .uint16
                        ? Int(ibase.load(fromByteOffset: n * 2, as: UInt16.self))
                        : Int(ibase.load(fromByteOffset: n * 4, as: UInt32.self))
                    guard vi < p.vertexCount else { continue }
                    let pos = base.load(fromByteOffset: vi * vstride + pOff, as: SIMD3<Float>.self)
                    let js = base.load(fromByteOffset: vi * vstride + jOff, as: SIMD4<UInt32>.self)
                    let ws = base.load(fromByteOffset: vi * vstride + wOff, as: SIMD4<Float>.self)
                    var acc = SIMD4<Float>(repeating: 0)
                    var total: Float = 0
                    for k in 0..<4 where ws[k] > 0 {
                        let ji = Int(js[k])
                        guard ji < skin.joints.count else { continue }
                        acc += (skin.joints[ji].worldMatrix * skin.inverseBindMatrices[ji]
                            * SIMD4<Float>(pos, 1)) * ws[k]
                        total += ws[k]
                    }
                    guard total > 0.001 else { continue }
                    let world = SIMD3<Float>(acc.x, acc.y, acc.z) / total
                    guard world.x.isFinite else { continue }
                    lo = simd_min(lo, world)
                    hi = simd_max(hi, world)
                    found = true
                }
            }
        }
        return found ? (lo, hi) : nil
    }
}
