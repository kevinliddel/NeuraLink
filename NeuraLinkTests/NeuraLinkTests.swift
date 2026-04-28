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

    @Test("Node Name Normalization")
    func testNormalization() {
        // Accessing internal function via @testable
        #expect(normalizeNodeName("Hips") == "hips")
        #expect(normalizeNodeName("Left_Arm_01") == "leftarm01")
        #expect(normalizeNodeName("Head (Root)") == "headroot")
    }

    // MARK: - AI Systems Tests

    @Test("AI Settings Mutual Exclusivity")
    func testSettingsMutualExclusivity() {
        let settings = OpenAISettings.shared
        
        // Reset defaults for clean state
        settings.isEnabled = false
        settings.isLocalLLMEnabled = false
        
        settings.isEnabled = true
        #expect(settings.isEnabled == true)
        
        // Turning on Local LLM should turn off OpenAI
        settings.isLocalLLMEnabled = true
        #expect(settings.isLocalLLMEnabled == true)
        #expect(settings.isEnabled == false)
        
        // Turning on OpenAI should turn off Local LLM
        settings.isEnabled = true
        #expect(settings.isEnabled == true)
        #expect(settings.isLocalLLMEnabled == false)
    }

    @Test("Chat State Transitions")
    @MainActor
    func testChatStateTransitions() {
        let state = RealtimeChatState.shared
        state.status = .disconnected
        #expect(state.status == .disconnected)
        
        state.status = .connecting
        #expect(state.status == .connecting)
        #expect(state.status.label == "Connecting...")
        
        state.setError("Network timeout")
        #expect(state.status == .error("Network timeout"))
        
        state.clearTranscripts()
        #expect(state.userTranscript == "")
        #expect(state.aiTranscript == "")
        #expect(state.audioLevel == 0.0)
    }

    @Test("Character Personas")
    func testCharacterPersonas() {
        let sonya = CharacterPersona.forCharacter(named: "Sonya")
        #expect(sonya.instructions.contains("Tsundere") == true)
        #expect(sonya.voice == "marin")
        
        let ekaterina = CharacterPersona.forCharacter(named: "Ekaterina")
        #expect(ekaterina.instructions.contains("Onee-san") == true)
        #expect(ekaterina.voice == "shimmer")
    }

    @Test("Local LLM Engine Initialization")
    func testLocalLLMEngineInitialization() async {
        let engine = LocalLLMEngine.shared
        
        do {
            try await engine.loadModel()
            Issue.record("Expected modelNotFound error since the mlmodelc is not in the test bundle")
        } catch let error as LLMError {
            #expect(error == .modelNotFound)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
