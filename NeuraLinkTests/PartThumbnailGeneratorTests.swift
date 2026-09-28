//
//  PartThumbnailGeneratorTests.swift
//  NeuraLinkTests
//
//  Developer tool disguised as a test: renders the picker pictures for the
//  bundled parts library and writes them as <model>__<category>.png (the
//  part files' own naming) into the directory named by the
//  NL_THUMB_OUTPUT_DIR environment variable, to be committed under
//  App/Resources/Custom/Thumbs. Without the variable it passes immediately.
//  Run with the variable EXPORTED, not as a build setting:
//
//    xcodebuild test -only-testing:NeuraLinkTests/PartThumbnailGeneratorTests \
//      TEST_RUNNER_NL_THUMB_OUTPUT_DIR=/path/to/out …
//

import Testing
import Foundation
import Metal
import UIKit
@testable import NeuraLink

@Suite("Part thumbnail generator", .serialized)
struct PartThumbnailGeneratorTests {

    @Test("Generate library thumbnails when NL_THUMB_OUTPUT_DIR is set")
    @MainActor
    func generate() async throws {
        guard let outputPath = ProcessInfo.processInfo.environment["NL_THUMB_OUTPUT_DIR"], !outputPath.isEmpty else { return }
        guard let device = MTLCreateSystemDefaultDevice(),
            let renderer = VRMPartThumbnailRenderer(size: 512)
        else {
            Issue.record("Metal unavailable")
            return
        }
        let outputDir = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var written = 0
        var seen = Set<String>()
        for item in PartsLibrary.shared.items {
            let itemURL = try await item.resolvedURL()
            let scan = try await VRMDonorTextureCache.shared.scan(url: itemURL, slug: item.donorSlug)
            // Only what the picker will actually ask this file for: an
            // outfit part carries body skin, so rendering a "skin" subject on
            // it would write a blank image the app never looks up.
            var jobs: [(CustomizationCategory, VRMPartThumbnailRenderer.Subject)] = []
            if item.serves(.hair), scan.hasPart(.hair) { jobs.append((.hair, .hair)) }
            if item.serves(.outfit), scan.hasPart(.outfit) { jobs.append((.outfit, .outfit)) }
            if item.serves(.tops), scan.hasPart(.tops) { jobs.append((.tops, .tops)) }
            if item.serves(.bottoms), scan.hasPart(.bottoms) { jobs.append((.bottoms, .bottoms)) }
            if item.serves(.shoes), scan.hasPart(.shoes) { jobs.append((.shoes, .shoes)) }
            if item.serves(.eyes), scan.fingerprint(forSlots: Set(CustomizationCategory.eyes.textureSlots)) != nil {
                jobs.append((.eyes, .eyes))
            }
            let pending = jobs
                .map { (PartThumbnailStore.thumbnailName(base: item.modelStem, category: $0.0), $0.1) }
                .filter { seen.insert($0.0).inserted }
            guard !pending.isEmpty else { continue }
            // Garments render from the whole-look file so the body fills
            // them: a shoe on its own is a dark hollow shell.
            let needsBody = pending.contains { [.tops, .bottoms, .shoes].contains($0.1) }
            var source = itemURL
            if needsBody, let whole = PartsLibrary.shared.item(slug: "lib:\(item.modelStem)__outfit"),
                let wholeURL = try? await whole.resolvedURL() {
                source = wholeURL
            }
            let model = try await VRMModel.load(from: source, device: device)
            for (name, subject) in pending {
                guard let image = renderer.render(model: model, subject: subject), let png = image.pngData() else {
                    Issue.record("render failed: \(item.stem) \(subject)")
                    continue
                }
                try png.write(to: outputDir.appendingPathComponent("\(name).png"), options: .atomic)
                written += 1
            }
        }

        // The bundled characters are donors too — customizing Sonya offers
        // Ekaterina's clothes and back. Their pictures ship with the library
        // so no tile has to wait on a whole character being rendered.
        VRMModelRegistry.shared.refresh()
        for entry in VRMModelRegistry.shared.all where !entry.isImported {
            let base = entry.name.lowercased()
            let scan = try await VRMDonorTextureCache.shared.scan(url: entry.url, slug: base)
            var jobs: [(CustomizationCategory, VRMPartThumbnailRenderer.Subject)] = []
            for (category, subject, part) in Self.characterJobs where scan.hasPart(part) {
                jobs.append((category, subject))
            }
            if scan.fingerprint(forSlots: Set(CustomizationCategory.eyes.textureSlots)) != nil {
                jobs.append((.eyes, .eyes))
            }
            let pending = jobs
                .map { (PartThumbnailStore.thumbnailName(base: base, category: $0.0), $0.1) }
                .filter { seen.insert($0.0).inserted }
            guard !pending.isEmpty else { continue }
            let model = try await VRMModel.load(from: entry.url, device: device)
            for (name, subject) in pending {
                guard let image = renderer.render(model: model, subject: subject), let png = image.pngData() else {
                    Issue.record("render failed: \(base) \(subject)")
                    continue
                }
                try png.write(to: outputDir.appendingPathComponent("\(name).png"), options: .atomic)
                written += 1
            }
        }

        #expect(written > 0)
        nlLog("[ThumbGen] wrote \(written) thumbnails to \(outputPath)", level: .info)
    }

    private static let characterJobs:
        [(CustomizationCategory, VRMPartThumbnailRenderer.Subject, AppearancePartKind)] = [
            (.hair, .hair, .hair), (.outfit, .outfit, .outfit), (.tops, .tops, .tops),
            (.bottoms, .bottoms, .bottoms), (.shoes, .shoes, .shoes)
        ]
}
