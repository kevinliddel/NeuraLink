//
//  NeuraLinkTests.swift
//  NeuraLinkTests
//
//  Created by Dedicatus on 14/04/2026.
//

import Testing
import Foundation
@testable import NeuraLink

@Suite("NeuraLink Unit Tests")
struct NeuraLinkTests {

    @Test("VRM Spec Version")
    func testSpecVersion() {
        #expect(VRMSpecVersion.v0_0.rawValue == "0.0")
        #expect(VRMSpecVersion.v1_0.rawValue == "1.0")
        #expect(VRMSpecVersion.v1_1.rawValue == "1.1")
    }

    @Test("Humanoid Bones Requirement")
    func testRequiredBones() {
        #expect(VRMHumanoidBone.hips.isRequired == true)
        #expect(VRMHumanoidBone.head.isRequired == true)
        #expect(VRMHumanoidBone.leftEye.isRequired == false)
        #expect(VRMHumanoidBone.chest.isRequired == false)
    }

    @Test("OpenAI Settings Validation")
    func testSettingsValidation() {
        let settings = OpenAISettings.shared
        let originalKey = settings.apiKey
        
        settings.apiKey = ""
        #expect(settings.hasValidKey == false)
        
        settings.apiKey = "invalid"
        #expect(settings.hasValidKey == false)
        
        settings.apiKey = "sk-12345"
        #expect(settings.hasValidKey == true)
        
        // Restore
        settings.apiKey = originalKey
    }

    @Test("VRM Model Basic Init")
    func testModelInitialization() throws {
        let meta = VRMMeta(licenseUrl: "https://vrm.dev")
        
        // Minimal valid GLTF JSON
        let json = """
        {
            "asset": {"version": "2.0"}
        }
        """.data(using: .utf8)!
        
        let decoder = JSONDecoder()
        let document = try decoder.decode(GLTFDocument.self, from: json)
        
        let model = VRMModel(
            specVersion: .v1_0,
            meta: meta,
            humanoid: nil,
            gltf: document
        )
        
        #expect(model.specVersion == .v1_0)
        #expect(model.meta.licenseUrl == "https://vrm.dev")
        #expect(model.isVRM0 == false)
    }
}
