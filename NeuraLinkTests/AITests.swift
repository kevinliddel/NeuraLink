//
//  AITests.swift
//  NeuraLinkTests
//
//  Created by Dedicatus on 23/04/2026.
//

import XCTest

@testable import NeuraLink

final class AITests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Reset settings before each test
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "com.neuralink.openai.enabled")
        defaults.removeObject(forKey: "com.neuralink.localllm.enabled")
        defaults.removeObject(forKey: "com.neuralink.openai.apiKey")

        RealtimeChatState.shared.clearTranscripts()
        RealtimeChatState.shared.status = .disconnected
    }

    // MARK: - OpenAISettings Tests

    func testSettingsMutualExclusivity() {
        let settings = OpenAISettings.shared

        // Test 1: Enabling Local LLM should disable OpenAI
        settings.isEnabled = true
        XCTAssertTrue(settings.isEnabled)

        settings.isLocalLLMEnabled = true
        XCTAssertTrue(settings.isLocalLLMEnabled, "Local LLM should be enabled")
        XCTAssertFalse(
            settings.isEnabled,
            "OpenAI should be automatically disabled when Local LLM is turned on")

        // Test 2: Enabling OpenAI should disable Local LLM
        settings.isEnabled = true
        XCTAssertTrue(settings.isEnabled, "OpenAI should be enabled")
        XCTAssertFalse(
            settings.isLocalLLMEnabled,
            "Local LLM should be automatically disabled when OpenAI is turned on")
    }

    func testAPIKeyValidation() {
        let settings = OpenAISettings.shared

        settings.apiKey = ""
        XCTAssertFalse(settings.hasValidKey)

        settings.apiKey = "invalid-key"
        XCTAssertFalse(settings.hasValidKey)

        settings.apiKey =
            "sk-proj-this_is_for_test_purpose_only_1234567890_never_put_api_key_in_code"
        XCTAssertTrue(settings.hasValidKey)
    }

    // MARK: - RealtimeChatState Tests

    func testChatStateTransitions() {
        let state = RealtimeChatState.shared

        XCTAssertEqual(state.status, .disconnected)

        state.status = .connecting
        XCTAssertEqual(state.status, .connecting)
        XCTAssertEqual(state.status.label, "Connecting...")

        state.setError("Network timeout")
        XCTAssertEqual(state.status, .error("Network timeout"))

        state.clearTranscripts()
        XCTAssertEqual(state.userTranscript, "")
        XCTAssertEqual(state.aiTranscript, "")
        XCTAssertEqual(state.audioLevel, 0.0)
    }

    // MARK: - CharacterPersona Tests

    func testCharacterPersonas() {
        // Test Sonya
        let sonya = CharacterPersona.forCharacter(named: "Sonya")
        XCTAssertTrue(sonya.instructions.contains("Tsundere"))
        XCTAssertEqual(sonya.voice, "shimmer")  // Or whatever the voice is

        // Test Ekaterina
        let ekaterina = CharacterPersona.forCharacter(named: "Ekaterina")
        XCTAssertTrue(ekaterina.instructions.contains("Onee-san"))
    }

    // MARK: - Local LLM Engine Tests

    func testLocalLLMEngineInitialization() async {
        let engine = LocalLLMEngine.shared

        do {
            // Since the test target doesn't bundle the real .mlmodelc, it should fail gracefully
            try await engine.loadModel()
            XCTFail("Expected modelNotFound error since the mlmodelc is not in the test bundle")
        } catch let error as LLMError {
            XCTAssertEqual(error, .modelNotFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
