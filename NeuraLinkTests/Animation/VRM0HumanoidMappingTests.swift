//
//  VRM0HumanoidMappingTests.swift
//  NeuraLinkTests
//
//  Regression: VRM 0.x names its thumb joints proximal/intermediate/distal
//  where VRM 1.0 uses metacarpal/proximal/distal. The parser must translate,
//  or the first joint lands one link too deep and the middle joint is
//  dropped — thumbs barely animate. Pinned against the bundled 0.x model.
//

import Testing
import Foundation
@testable import NeuraLink

@Suite("VRM 0.x humanoid mapping")
struct VRM0HumanoidMappingTests {

    @Test("The 0.x thumb chain maps fully onto the 1.0 metacarpal scheme")
    func vrm0ThumbChainMapsFully() async throws {
        guard let url = Bundle.main.url(forResource: "Ekaterina", withExtension: "vrm") else {
            Issue.record("Ekaterina.vrm missing from the test host bundle")
            return
        }
        let model = try await VRMModel.load(from: url)
        #expect(model.isVRM0, "Ekaterina is expected to be a VRM 0.x export")
        let humanoid = try #require(model.humanoid)

        let thumbChain: [VRMHumanoidBone] = [
            .leftThumbMetacarpal, .leftThumbProximal, .leftThumbDistal,
            .rightThumbMetacarpal, .rightThumbProximal, .rightThumbDistal
        ]
        for bone in thumbChain {
            #expect(humanoid.getBoneNode(bone) != nil, "\(bone.rawValue) is unmapped")
        }
    }
}
