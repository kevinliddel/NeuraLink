//
//  MotionModelAssetsTests.swift
//  NeuraLinkTests
//
//  The nine motion model assets: distinctive file names (a bundle lookup by
//  basename must never hit another model's tokenizer.json), one folder in
//  the dataset, a pin on every file, each graph's weight sidecar named as
//  the graph records it, and the download size the card shows.
//  See docs/GENERATIVE_MOTION.md.
//
//  Created by Dedicatus on 30/10/2026.
//

import Foundation
import Testing

@testable import NeuraLink

@Suite("Motion model assets")
struct MotionModelAssetsTests {

    @Test("Nine pinned files in motion/ardy-mini-external with distinctive names")
    func assets() {
        let assets = MotionModelAccess.assets
        #expect(assets.count == 9)
        #expect(Set(assets.map(\.filename)).count == 9)
        #expect(assets.allSatisfy { $0.filename.hasPrefix("ardy_mini_") })
        #expect(assets.allSatisfy { $0.pathInRepo == "motion/ardy-mini-external/\($0.filename)" })
        #expect(assets.allSatisfy { $0.integrity != nil })
        #expect(assets.allSatisfy { $0.bundleSubdirectory == nil })
        #expect(assets.allSatisfy { $0.remoteURL?.host == "huggingface.co" })
    }

    @Test("Each graph's sidecar is the graph's name plus .data, as the graph records it")
    func sidecars() {
        let pairs: [(RemoteAssetRegistry, RemoteAssetRegistry, String)] = [
            (.motionTextEncoder, .motionTextEncoderWeights, "text_encoder"),
            (.motionDenoiser, .motionDenoiserWeights, "denoiser"),
            (.motionDecoder, .motionDecoderWeights, "decoder")
        ]
        let folder = URL(fileURLWithPath: "/cache/motion", isDirectory: true)
        for (graph, weights, name) in pairs {
            #expect(weights.filename == graph.filename + ".data")
            let expected = folder.appendingPathComponent(weights.filename)
            #expect(ARDYModelFiles.sidecar(of: folder.appendingPathComponent(graph.filename), named: name) == expected)
        }
        let files = ARDYModelFiles(directory: folder)
        #expect(files.all.count == 9)
        #expect(files.denoiserWeights.lastPathComponent == RemoteAssetRegistry.motionDenoiserWeights.filename)
    }

    @Test("The download is the fp32 family with external weights, 775 MB (740 MiB)")
    func size() {
        let mebibytes = Double(MotionModelAccess.totalBytes) / 1_048_576
        #expect(mebibytes > 735 && mebibytes < 745)
        #expect(RemoteAssetRegistry.motionDenoiserWeights.integrity?.size == 589_737_984)
    }

    @Test("The policy's window and frame interval match the model's (40 frames at 20 fps)")
    func policyWindow() {
        let policy = MotionStreamPolicy()
        #expect(policy.windowSeconds == 2)
        #expect((policy.windowSeconds / policy.frameSeconds).rounded() == 40)
    }
}
