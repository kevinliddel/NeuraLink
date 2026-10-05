//
//  HairGraftDiagnostic.swift
//  NeuraLinkTests
//
//  Developer tool: grafts hair between the bundled characters and the
//  library parts and renders the HEAD — scalp included — so a bald patch
//  shows up as the scalp it is, rather than having to be inferred from
//  bounding boxes. Rest-pose measurements said the hair encloses the skull
//  completely, which is exactly the kind of answer that has been wrong
//  before. Set NL_HAIR_DIAG_DIR to run.
//

import Testing
import Foundation
import Metal
import UIKit
import simd
@testable import NeuraLink

@Suite("Hair graft diagnostic", .serialized)
struct HairGraftDiagnostic {

    @Test("Render grafted hair when NL_HAIR_DIAG_DIR is set")
    @MainActor
    func render() async throws {
        guard let path = ProcessInfo.processInfo.environment["NL_HAIR_DIAG_DIR"], !path.isEmpty,
            let device = MTLCreateSystemDefaultDevice(),
            let renderer = VRMPartThumbnailRenderer(size: 512)
        else { return }
        let outputDir = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var donors: [(label: String, url: URL)] = []
        for item in PartsLibrary.shared.items where item.kind == .hair {
            if let url = try? await item.resolvedURL() { donors.append((item.modelStem, url)) }
        }
        for name in ["Sonya", "Ekaterina"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "vrm") {
                donors.append((name.lowercased(), url))
            }
        }
        #expect(donors.count >= 3, "library hair plus both characters")

        var report = ""
        for hostName in ["Sonya", "Ekaterina"] {
            guard let hostURL = Bundle.main.url(forResource: hostName, withExtension: "vrm")
            else { continue }
            for entry in donors where entry.label != hostName.lowercased() {
                let host = try await VRMModel.load(from: hostURL, device: device)
                let donor = try await VRMModel.load(from: entry.url, device: device)
                host.updateNodeTransforms()
                let fit = VRMPartGrafter.fitScale(.hair, donor: donor, host: host)
                try VRMPartGrafter.graft(.hair, from: donor, donorSlug: entry.label, onto: host)
                host.updateNodeTransforms()
                report += """
                    == \(hostName) + \(entry.label)  fit=\(String(format: "%.3f", fit)) \
                    scalpVisible=\(String(format: "%.1f%%", scalpExposure(host) * 100))

                    """
                guard let image = renderer.render(model: host, subject: .head),
                    let png = image.pngData() else { continue }
                try png.write(
                    to: outputDir.appendingPathComponent("\(hostName.lowercased())_\(entry.label).png"),
                    options: .atomic)
            }
        }
        try report.write(
            to: outputDir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }

    /// Share of the host's scalp — face skin above the head joint — that no
    /// hair sits outside of, along its own outward direction.
    @MainActor
    private func scalpExposure(_ model: VRMModel) -> Float {
        guard let head = model.bindPosition(of: .head) else { return 0 }
        var scalp: [SIMD3<Float>] = []
        var hair: [SIMD3<Float>] = []
        for mesh in model.meshes {
            for primitive in mesh.primitives {
                guard let m = primitive.materialIndex,
                    !model.hiddenPrimitives.contains(ObjectIdentifier(primitive))
                else { continue }
                let slot = model.slot(ofMaterial: m)
                if slot == .faceSkin {
                    primitive.forEachRestPosition(budget: 4_000) {
                        if $0.y > head.y { scalp.append($0) }
                    }
                } else if slot == .hair || slot == .hairBack {
                    primitive.forEachRestPosition(budget: 8_000) { hair.append($0) }
                }
            }
        }
        guard scalp.count > 20, !hair.isEmpty else { return 0 }
        // Bucket the hair by height and bearing, then ask whether any strand
        // sits further out than the scalp point in that same direction.
        var reach: [Int: Float] = [:]
        func key(_ p: SIMD3<Float>) -> Int {
            let band = Int((p.y - head.y) * 100)
            let sector = Int((atan2(p.z - head.z, p.x - head.x) + .pi) / (2 * .pi) * 12)
            return band * 100 + min(11, max(0, sector))
        }
        for point in hair {
            let distance = simd_length(SIMD2(point.x - head.x, point.z - head.z))
            reach[key(point)] = max(reach[key(point)] ?? 0, distance)
        }
        let bare = scalp.filter { point in
            let distance = simd_length(SIMD2(point.x - head.x, point.z - head.z))
            return (reach[key(point)] ?? 0) < distance - 0.001
        }
        return Float(bare.count) / Float(scalp.count)
    }
}
