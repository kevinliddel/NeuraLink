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
    @MainActor
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
    @MainActor
    func testLocalLLMEngineInitialization() async {
        let engine = GGUFLlamaEngine.shared
        
        do {
            try await engine.loadModel()
            Issue.record("Expected modelNotFound error since the mlmodelc is not in the test bundle")
        } catch let error as LLMError {
            #expect(error == .modelNotFound)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Thumb Bone Retargeting Diagnostics")
    @MainActor
    func testThumbBoneRetargetingDiagnostics() async throws {
        // Resolved from the host app bundle so the test stays portable across CI runners.
        // When the .vrm/.vrma aren't packaged (e.g. unit-test-only target builds), skip cleanly.
        guard let vrmURL = Bundle.main.url(forResource: "Sonya", withExtension: "vrm"),
              let vrmaURL = Bundle.main.url(forResource: "neutral", withExtension: "vrma") else {
            print("DIAGNOSTIC: Sonya.vrm or neutral.vrma not found in main bundle — skipping")
            return
        }

        print("DIAGNOSTIC: Loading model from \(vrmURL.path)")
        let model = try await VRMModel.load(from: vrmURL)
        print("DIAGNOSTIC: Model loaded successfully: \(model.meta.name ?? "unnamed")")

        if let humanoid = model.humanoid {
            print("DIAGNOSTIC: Sonya mapped bones:")
            for bone in VRMHumanoidBone.allCases {
                if let node = humanoid.getBoneNode(bone) {
                    let nodeName = model.nodes[safe: node]?.name ?? "unknown"
                    print("  - \(bone.rawValue) -> node \(node) (\(nodeName))")
                }
            }
        }

        print("DIAGNOSTIC: Loading animation from \(vrmaURL.path)")
        let clip = try VRMAnimationLoader.loadVRMA(from: vrmaURL, model: model)
        print("DIAGNOSTIC: Clip loaded successfully, duration=\(clip.duration)")
    }

    @Test("Parser Robustness - Corrupt/Empty Data")
    func testParserRobustnessWithCorruptData() {
        let parser = GLTFParser()
        let emptyData = Data()
        
        do {
            _ = try parser.parse(data: emptyData)
            Issue.record("Expected parser to throw an error for empty data")
        } catch let error as VRMError {
            switch error {
            case .invalidGLBFormat(let reason, _):
                #expect(reason.contains("too small"))
            default:
                Issue.record("Unexpected error case: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Parser Robustness - Truncated Data Header")
    func testParserRobustnessWithTruncatedData() {
        let parser = GLTFParser()
        // Truncated header (only magic, missing version and length)
        let truncatedHeader = Data([0x67, 0x6C, 0x54, 0x46]) // "glTF"
        
        do {
            _ = try parser.parse(data: truncatedHeader)
            Issue.record("Expected parser to throw an error for truncated header")
        } catch let error as VRMError {
            switch error {
            case .invalidGLBFormat(let reason, _):
                #expect(reason.contains("too small"))
            default:
                Issue.record("Unexpected error case: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
