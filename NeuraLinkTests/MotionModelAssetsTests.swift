//
//  MotionModelAssetsTests.swift
//  NeuraLinkTests
//
//  The six motion model assets: distinctive file names (a bundle lookup by
//  basename must never hit another model's tokenizer.json), one folder in
//  the dataset, a pin on every file, and the download size the card shows.
//  docs/REALTIME_MOTION_PLAN.md, Phase 5.
//
//  Created by Dedicatus on 30/10/2026.
//

import Foundation
import Testing

@testable import NeuraLink

@Suite("Motion model assets")
struct MotionModelAssetsTests {

    @Test("Six pinned files in motion/ardy-mini with distinctive names")
    func assets() {
        let assets = MotionModelAccess.assets
        #expect(assets.count == 6)
        #expect(Set(assets.map(\.filename)).count == 6)
        #expect(assets.allSatisfy { $0.filename.hasPrefix("ardy_mini_") })
        #expect(assets.allSatisfy { $0.pathInRepo == "motion/ardy-mini/\($0.filename)" })
        #expect(assets.allSatisfy { $0.integrity != nil })
        #expect(assets.allSatisfy { $0.bundleSubdirectory == nil })
        #expect(assets.allSatisfy { $0.remoteURL?.host == "huggingface.co" })
    }

    @Test("The download is the published fp32 family, about 740 MB")
    func size() {
        let megabytes = Double(MotionModelAccess.totalBytes) / 1_048_576
        #expect(megabytes > 735 && megabytes < 745)
        #expect(RemoteAssetRegistry.motionDenoiser.integrity?.size == 590_701_771)
    }

    @Test("The policy's budget matches the model's window")
    func policyWindow() {
        #expect(MotionStreamPolicy().windowSeconds == 2)
    }
}
