//
//  OpenAIModelSettingsTests.swift
//  NeuraLinkTests
//
//  Model selection + usage metering (docs/CHAT_LLM_IMPROVEMENT_PLAN.md §B3).
//

import Foundation
import Testing

@testable import NeuraLink

@MainActor
@Suite("OpenAI model settings", .serialized)
struct OpenAIModelSettingsTests {

    @Test("Catalog defaults are the ids the app shipped with")
    func catalogDefaults() {
        #expect(OpenAIModelCatalog.defaultID(for: .realtime) == "gpt-realtime-2.1-mini")
        #expect(OpenAIModelCatalog.defaultID(for: .transcription) == "gpt-4o-transcribe")
        #expect(OpenAIModelCatalog.defaultID(for: .text) == "gpt-5.6-luna")
        #expect(OpenAIChatClient.defaultModel == "gpt-5.6-luna")
        #expect(OpenAIModelCatalog.pickerItems(for: .text).last == OpenAIModelCatalog.customID)
    }

    @Test("Model ids persist and blank falls back to the default")
    func persistence() {
        let settings = OpenAISettings.shared
        let original = settings.textModel
        defer { settings.textModel = original }

        settings.textModel = "  my-custom-model "
        #expect(settings.textModel == "my-custom-model")
        #expect(UserDefaults.standard.string(forKey: "com.neuralink.openai.model.text") == "my-custom-model")

        settings.textModel = "   "
        #expect(settings.textModel == OpenAIModelCatalog.defaultID(for: .text))
    }

    @Test("Usage meter accumulates response.done usage payloads")
    func usageMeter() {
        var meter = RealtimeUsageMeter()
        meter.add(usage: [
            "input_tokens": 1_200, "output_tokens": 300,
            "input_token_details": ["audio_tokens": 900, "cached_tokens": 100],
            "output_token_details": ["audio_tokens": 250]
        ])
        meter.add(usage: ["input_tokens": 100, "output_tokens": 50])
        #expect(meter.responses == 2)
        #expect(meter.inputTokens == 1_300)
        #expect(meter.outputTokens == 350)
        #expect(meter.inputAudioTokens == 900)
        #expect(meter.cachedInputTokens == 100)
        #expect(meter.outputAudioTokens == 250)
        #expect(meter.summary == "1.6k tokens")
        #expect(meter.logLine.hasPrefix("[Cost] realtime responses=2"))
    }

    @Test("Temperature is omitted for GPT-5 family models")
    func temperatureSupport() {
        #expect(!OpenAIChatClient.supportsTemperature("gpt-5.6-luna"))
        #expect(OpenAIChatClient.supportsTemperature("gpt-4o-mini"))
    }
}
