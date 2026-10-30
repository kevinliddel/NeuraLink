//
//  GeneratedClipSnapshots.swift
//  NeuraLinkTests
//
//  Review renders, not assertions: plays generated VRMA clips (ARDY-mini
//  output retargeted by the Phase 0 scratch tooling) on the three bundled
//  characters through the app's loader and writes one contact sheet per clip
//  — each character at four moments — plus a report of what the loader made
//  of every file. Generated-gesture quality is judged on these
//  (docs/GENERATIVE_MOTION.md).
//
//  NL_GEN_CLIP_DIR: folder of .vrma files (unset = skip).
//  NL_GEN_CLIP_SNAPSHOT_DIR: output folder (default: <clip dir>/snapshots).
//  NL_GEN_CLIP_FILTER: only clips whose file name contains this text.
//  NL_GEN_CLIP_TIMES: moments in seconds, comma-separated (default 0.5,1.5,2.5,3.5).
//
//  Created by Dedicatus on 29/10/2026.
//

import Foundation
import Metal
import Testing
import UIKit
import simd

@testable import NeuraLink

@MainActor
@Suite("Generated clip snapshots", .serialized)
struct GeneratedClipSnapshots {

    private static let characters = ["Oz", "Ekaterina", "Sonya"]
    private static let defaultTimes: [Float] = [0.5, 1.5, 2.5, 3.5]
    private static let tile = 512

    @Test("Writes contact sheets when NL_GEN_CLIP_DIR is set")
    func render() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["NL_GEN_CLIP_DIR"], !input.isEmpty,
            let device = MTLCreateSystemDefaultDevice(),
            let thumbnails = VRMPartThumbnailRenderer(size: Self.tile)
        else { return }
        let inputDir = URL(fileURLWithPath: input, isDirectory: true)
        let outputDir = URL(fileURLWithPath: env["NL_GEN_CLIP_SNAPSHOT_DIR"] ?? input + "/snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let filter = env["NL_GEN_CLIP_FILTER"] ?? ""
        let times = env["NL_GEN_CLIP_TIMES"].map { $0.split(separator: ",").compactMap { Float($0) } } ?? Self.defaultTimes
        let clips = try FileManager.default.contentsOfDirectory(at: inputDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "vrma" && (filter.isEmpty || $0.lastPathComponent.contains(filter)) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var models: [(name: String, model: VRMModel)] = []
        for name in Self.characters {
            let url = try #require(Bundle.main.url(forResource: name, withExtension: "vrm"))
            models.append((name, try await VRMModel.load(from: url, device: device)))
        }

        var report = "\(clips.count) clips, \(times.count) moments\n"
        for clipURL in clips {
            var tiles: [UIImage] = []
            for entry in models {
                let clip = try VRMAnimationLoader.loadVRMA(from: clipURL, model: entry.model)
                let hips = Self.hipsRange(clip)
                report += String(
                    format: "%@ on %@: %.2fs, %d joint tracks, hips y %+.3f…%+.3f m\n",
                    clipURL.lastPathComponent, entry.name, clip.duration, clip.jointTracks.count, hips.min, hips.max)
                for time in times {
                    Self.pose(entry.model, with: clip, at: time)
                    tiles.append(try #require(thumbnails.render(model: entry.model, subject: .figure)))
                }
            }
            let labels = models.map(\.name)
            let sheet = Self.contactSheet(tiles, columns: times.count, rowLabels: labels, columnLabels: times.map { String(format: "%.1f s", $0) })
            let png = try #require(sheet.pngData())
            try png.write(to: outputDir.appendingPathComponent(clipURL.deletingPathExtension().lastPathComponent + ".png"), options: .atomic)
        }
        try report.write(to: outputDir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: - Posing

    /// Writes the clip's sampled rotations and the hips translation straight
    /// onto the nodes, as the player would with root motion on.
    private static func pose(_ model: VRMModel, with clip: AnimationClip, at time: Float) {
        model.withLock {
            for track in clip.jointTracks {
                guard let index = model.humanoid?.getBoneNode(track.bone), index < model.nodes.count else { continue }
                let node = model.nodes[index]
                let (rotation, translation, _) = track.sample(at: time)
                if let rotation { node.rotation = rotation }
                if let translation { node.translation = translation }
                node.updateLocalMatrix()
            }
            model.updateNodeTransforms()
        }
    }

    /// The hips height the clip asks for, relative to its first sample.
    private static func hipsRange(_ clip: AnimationClip) -> (min: Float, max: Float) {
        guard let hips = clip.jointTracks.first(where: { $0.bone == .hips }),
            let first = hips.sample(at: 0).1
        else { return (0, 0) }
        var low: Float = 0
        var high: Float = 0
        for step in stride(from: Float(0), through: clip.duration, by: 0.1) {
            guard let translation = hips.sample(at: step).1 else { continue }
            let delta = translation.y - first.y
            low = min(low, delta)
            high = max(high, delta)
        }
        return (low, high)
    }

    // MARK: - Contact sheet

    private static func contactSheet(_ tiles: [UIImage], columns: Int, rowLabels: [String], columnLabels: [String]) -> UIImage {
        let tile = CGFloat(Self.tile)
        let rows = max(1, tiles.count / max(1, columns))
        let margin: CGFloat = 40
        let size = CGSize(width: margin + tile * CGFloat(columns), height: margin + tile * CGFloat(rows))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 24, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.12, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for (index, image) in tiles.enumerated() {
                let row = index / columns
                let column = index % columns
                image.draw(in: CGRect(x: margin + tile * CGFloat(column), y: margin + tile * CGFloat(row), width: tile, height: tile))
            }
            for (column, label) in columnLabels.enumerated() {
                label.draw(at: CGPoint(x: margin + tile * CGFloat(column) + 8, y: 8), withAttributes: attributes)
            }
            for (row, label) in rowLabels.enumerated() {
                context.cgContext.saveGState()
                context.cgContext.translateBy(x: 8, y: margin + tile * CGFloat(row) + tile / 2)
                context.cgContext.rotate(by: -.pi / 2)
                label.draw(at: CGPoint(x: -tile / 4, y: 0), withAttributes: attributes)
                context.cgContext.restoreGState()
            }
        }
    }
}
