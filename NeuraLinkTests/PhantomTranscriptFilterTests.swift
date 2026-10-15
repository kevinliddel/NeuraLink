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
}
