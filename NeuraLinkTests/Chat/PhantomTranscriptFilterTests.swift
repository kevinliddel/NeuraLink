//
//  PhantomTranscriptFilterTests.swift
//  NeuraLinkTests
//
//  Phantom user transcripts (docs/openai_realtime_chat.md): prompt echoes,
//  fillers, fragments and segments too short or too dense to be speech are
//  dropped; ordinary speech in any script passes.
//

import Foundation
import Testing

@testable import NeuraLink

@Suite("Phantom transcript filter")
struct PhantomTranscriptFilterTests {

    private let prompt = "Casual voice chat with an AI companion. May include proper nouns: "
        + "media/game/anime/song titles, app names, Japanese words."

    @Test("Genuine speech passes, in English and Japanese, short and long")
    func genuine() {
        #expect(PhantomTranscriptFilter.reason(transcript: "Hi!", speechMs: 620, prompt: prompt) == nil)
        #expect(PhantomTranscriptFilter.reason(transcript: "What's the weather like today?", speechMs: 1_800, prompt: prompt) == nil)
        #expect(PhantomTranscriptFilter.reason(transcript: "今日はどんな一日だった？", speechMs: 1_900, prompt: prompt) == nil)
        #expect(PhantomTranscriptFilter.reason(transcript: "That's great", speechMs: 900) == nil)
        #expect(PhantomTranscriptFilter.reason(transcript: "Play some anime songs", speechMs: 1_200, prompt: prompt) == nil)
        #expect(PhantomTranscriptFilter.reason(transcript: "Okay.", speechMs: nil) == nil)
    }

    @Test("The transcription prompt echoed back is not speech")
    func promptEcho() {
        #expect(PhantomTranscriptFilter.reason(transcript: prompt, speechMs: 2_000, prompt: prompt) == .promptEcho)
        #expect(PhantomTranscriptFilter.reason(
            transcript: "May include proper nouns: media, game, anime, song titles.", prompt: prompt) == .promptEcho)
        #expect(PhantomTranscriptFilter.reason(
            transcript: "Casual voice chat with an AI companion, maybe some anime and song titles and app names and Japanese words today",
            prompt: prompt) == .promptEcho)
        #expect(PhantomTranscriptFilter.reason(transcript: "an AI", prompt: prompt) == nil)
    }

    @Test("Fillers, fragments and empty transcripts are dropped")
    func fillersAndFragments() {
        #expect(PhantomTranscriptFilter.reason(transcript: "ね。") == .filler)
        #expect(PhantomTranscriptFilter.reason(transcript: "Thank you.") == .filler)
        #expect(PhantomTranscriptFilter.reason(transcript: "you") == .filler)
        #expect(PhantomTranscriptFilter.reason(transcript: "That's...") == .fragment)
        #expect(PhantomTranscriptFilter.reason(transcript: "So…") == .fragment)
        #expect(PhantomTranscriptFilter.reason(transcript: "I was thinking that maybe...") == nil)
        #expect(PhantomTranscriptFilter.reason(transcript: " \n") == .empty)
        #expect(PhantomTranscriptFilter.reason(transcript: "...") == .empty)
    }

    @Test("Segment timing rules out breaths and impossible word rates")
    func timing() {
        #expect(PhantomTranscriptFilter.reason(transcript: "Hello there", speechMs: 200) == .tooShort)
        #expect(PhantomTranscriptFilter.reason(
            transcript: "Hey just checking in if your thoughts are wandering we can wander together maybe you are recharging",
            speechMs: 900) == .tooFastForDuration)
        #expect(PhantomTranscriptFilter.speechUnits("今日はどんな一日だった") == 3)
        #expect(PhantomTranscriptFilter.normalized("That's... GREAT, right?!") == "that s great right")
    }

    @Test("Local whisper's subtitle habits: annotations and sign-offs")
    func whisperSubtitleHabits() {
        // As seen on device, and what ggml-base writes for noise, a breath or a thump.
        #expect(PhantomTranscriptFilter.reason(transcript: "(笑)") == .annotation)
        #expect(PhantomTranscriptFilter.reason(transcript: "(エンディング)") == .annotation)
        #expect(PhantomTranscriptFilter.reason(transcript: "[BLANK_AUDIO]") == .annotation)
        #expect(PhantomTranscriptFilter.reason(transcript: "(drill whirring)") == .annotation)
        #expect(PhantomTranscriptFilter.reason(transcript: "（拍手）") == .annotation)
        #expect(PhantomTranscriptFilter.reason(transcript: "[音楽] ♪") == .annotation)
        #expect(PhantomTranscriptFilter.reason(transcript: "*laughs*") == .annotation)
        #expect(PhantomTranscriptFilter.reason(transcript: "笑") == .filler)
        #expect(PhantomTranscriptFilter.reason(transcript: "ご視聴ありがとうございました。") == .filler)
        #expect(PhantomTranscriptFilter.reason(transcript: "チャンネル登録よろしくお願いします！") == .filler)
        #expect(PhantomTranscriptFilter.reason(transcript: "紅茶をお願いします。") == nil)
        // An annotation next to real words leaves the words.
        #expect(PhantomTranscriptFilter.reason(transcript: "(笑) 本当に？") == nil)
        #expect(PhantomTranscriptFilter.spokenText("(ト) 私のメインは?") == "私のメインは?")
        #expect(PhantomTranscriptFilter.spokenText("本当に（笑）面白いね") == "本当に 面白いね")
        #expect(PhantomTranscriptFilter.spokenText("Thank you (applause)") == "Thank you")
    }
}
