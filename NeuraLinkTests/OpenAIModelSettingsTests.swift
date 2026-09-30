//
//  OpenAIModelSettingsTests.swift
//  NeuraLinkTests
//
//  Model selection + usage metering (docs/CHAT_LLM.md).
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
        #expect(OpenAIModelCatalog.pickerItems(for: .text).first == "gpt-5.6-luna")
    }

    @Test("Catalog ids are unique per role and there is no custom entry")
    func catalogShape() {
        for role in OpenAIModelCatalog.Role.allCases {
            let ids = OpenAIModelCatalog.pickerItems(for: role)
            #expect(Set(ids).count == ids.count)
            #expect(!ids.contains("custom"))
        }
    }

    @Test("Reasoning models get a low reasoning_effort; GPT-4 family gets none")
    func reasoningEffort() {
        #expect(OpenAIModelCatalog.reasoningEffort(forTextModel: "gpt-5.6-luna") == "none")
        #expect(OpenAIModelCatalog.reasoningEffort(forTextModel: "gpt-5") == "minimal")
        #expect(OpenAIModelCatalog.reasoningEffort(forTextModel: "gpt-4o-mini") == nil)
        for entry in OpenAIModelCatalog.text where entry.id.hasPrefix("gpt-5") || entry.id.hasPrefix("gpt-6") {
            #expect(entry.reasoningEffort != nil, "\(entry.id) needs an effort or short calls come back empty")
        }
    }

    @Test("Transcription prompt is skipped for gpt-realtime-whisper only")
    func transcriptionPrompt() {
        #expect(!OpenAIModelCatalog.transcriptionSupportsPrompt("gpt-realtime-whisper"))
        #expect(OpenAIModelCatalog.transcriptionSupportsPrompt("gpt-4o-transcribe"))
    }

    @Test("Model ids persist; blank or unlisted ids fall back to the default")
    func persistence() {
        let settings = OpenAISettings.shared
        let original = settings.textModel
        defer { settings.textModel = original }

        settings.textModel = " gpt-4.1-mini "
        #expect(settings.textModel == "gpt-4.1-mini")
        #expect(UserDefaults.standard.string(forKey: "com.neuralink.openai.model.text") == "gpt-4.1-mini")

        settings.textModel = "my-custom-model"
        #expect(settings.textModel == OpenAIModelCatalog.defaultID(for: .text))

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

    @Test("Temperature is omitted for GPT-5/6 family models")
    func temperatureSupport() {
        #expect(!OpenAIChatClient.supportsTemperature("gpt-5.6-luna"))
        #expect(!OpenAIChatClient.supportsTemperature("gpt-6-luna"))
        #expect(OpenAIChatClient.supportsTemperature("gpt-4o-mini"))
    }
}
