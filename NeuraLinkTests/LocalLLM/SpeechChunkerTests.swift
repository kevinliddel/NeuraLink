//
//  SpeechChunkerTests.swift
//  NeuraLinkTests
//
//  The voice preview and transcript playback speak a finished text chunk by
//  chunk so audio starts after the first clause. These pin the split rules
//  and the background-work hold that keeps the model off the CPU meanwhile.
//
//  Created by Dedicatus on 20/10/2026.
//

import Testing
@testable import NeuraLink

@Suite("Speech chunker")
struct SpeechChunkerTests {

    @Test("English: a short first clause, then whole sentences")
    func english() {
        #expect(SpeechChunker.chunks("Good evening, sir. Tea is served in the library. Shall I bring biscuits?")
                == ["Good evening,", "sir.", "Tea is served in the library.", "Shall I bring biscuits?"])
        #expect(SpeechChunker.chunks("It costs 3.14 dollars today. Fine.")
                == ["It costs 3.14 dollars today.", "Fine."], "a decimal point is not a sentence end")
        #expect(SpeechChunker.chunks("I have prepared the tea and the biscuits are warming in the oven for you")
                == ["I have prepared the tea", "and the biscuits are warming in the oven for you"],
                "no punctuation: the first chunk still ends early, at a space")
    }

    @Test("Japanese: first clause, then sentences; quotes stay with their sentence")
    func japanese() {
        #expect(SpeechChunker.chunks("かしこまりました、ご主人様。お茶をお持ちいたします。「少々お待ちください。」")
                == ["かしこまりました、", "ご主人様。", "お茶をお持ちいたします。", "「少々お待ちください。」"])
        #expect(SpeechChunker.chunks("はい！？そうです。") == ["はい！？", "そうです。"])
    }

    @Test("Punctuation runs stay whole; nothing speakable is never sent")
    func punctuation() {
        #expect(SpeechChunker.chunks("Really?! Yes...") == ["Really?!", "Yes..."])
        #expect(SpeechChunker.chunks("……").isEmpty)
        #expect(SpeechChunker.chunks("   ").isEmpty)
    }

    @Test("A runaway sentence is capped and nothing is lost")
    func runaway() {
        let text = String(repeating: "あ", count: 300)
        let chunks = SpeechChunker.chunks(text)
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.count <= SpeechChunker.hardLength })
        #expect(chunks.joined() == text)
    }

    @Test("Paraphrased scene narration is caught by copied-run coverage")
    func echoCoverage() {
        let cue = ProactivePresenceManager.smallTalkEventJapanese(
            name: "Oz", timeOfDay: "午後", angle: .checkIn, previousLine: nil)
        #expect(CueReplyValidator.echoCoverage("今は午後で、しばらく会話が途切れています。", cue) >= 0.5)
        #expect(CueReplyValidator.echoCoverage("紅茶でもお淹れしましょうか。", cue) < 0.2)
    }

    @Test("Standalone speech preempts background generation and holds new runs")
    @MainActor
    func standaloneSpeechHold() {
        let manager = LocalLLMManager.shared
        let original = manager.llmEngine
        let stub = PreemptCountingEngine()
        manager.llmEngine = stub
        defer { manager.llmEngine = original }

        let before = manager.standaloneSpeechHolds
        manager.beginStandaloneSpeech()
        #expect(stub.preempts == 1)
        #expect(manager.standaloneSpeechHolds == before + 1)
        manager.endStandaloneSpeech()
        #expect(manager.standaloneSpeechHolds == before)
        manager.endStandaloneSpeech()
        #expect(manager.standaloneSpeechHolds == max(0, before - 1), "never goes negative")
        manager.standaloneSpeechHolds = before
    }
}

private final class PreemptCountingEngine: LLMEngineProtocol {
    weak var delegate: LocalLLMEngineDelegate?
    var isLoaded: Bool { false }
    var preempts = 0
    func loadModel() async throws {}
    func generate(prompt: String, maxTokens: Int) async {}
    func stop() {}
    func unloadModel() {}
    func applyChatTemplate(messages: [LLMChatMessage]) -> String? { nil }
    func preemptSilentWork() { preempts += 1 }
}
