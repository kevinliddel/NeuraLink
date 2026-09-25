//
//  LocalLLMManager+BargeIn.swift
//  NeuraLink
//
//  Barge-in for the local path (docs/CHAT_LLM_IMPROVEMENT_PLAN.md §A2).
//  While the assistant speaks, mic frames now reach Silero; a voice-start
//  event becomes an interruption only when, over a short confirmation
//  window, the mic energy clearly exceeds the playback energy (echo of our
//  own speaker) and playback has been running long enough to rule out the
//  TTS onset. On commit the LLM, player and TTS engine stop, the partial
//  reply is kept, and recording starts with the pre-roll intact. An echo
//  guard after transcription rejects utterances that merely repeat what
//  the assistant just said.
//
//  Created by Dedicatus on 26/09/2026.
//

import AVFoundation
import Foundation

/// Pure two-signal arbiter, testable without audio.
nonisolated struct BargeInArbiter: Sendable {
    /// How long mic energy must dominate before committing.
    static let confirmWindow: TimeInterval = 0.25
    /// Ignore voice starts this soon after playback began (TTS onset).
    static let onsetGuard: TimeInterval = 0.4
    /// Mic frames below this RMS are silence regardless of playback.
    static let minimumMicRMS: Float = 0.01

    enum Decision: Equatable { case none, commit, reject }

    /// Mic RMS must exceed `energyRatio × playback RMS`. Raised after an
    /// echo rejection so a bad session gets stricter, never looser.
    var energyRatio: Float = 1.5

    private(set) var candidateSince: TimeInterval?
    private var micSum: Float = 0
    private var playbackSum: Float = 0
    private var frames = 0

    /// Silero reported voice start at `now`. Returns true when the start is
    /// eligible (playback running past the onset guard) and a candidate opens.
    mutating func voiceStarted(at now: TimeInterval, playbackStartedAt: TimeInterval?) -> Bool {
        guard let started = playbackStartedAt, now - started >= Self.onsetGuard else { return false }
        candidateSince = now
        micSum = 0
        playbackSum = 0
        frames = 0
        return true
    }

    /// One mic frame while a candidate is open.
    mutating func observe(micRMS: Float, playbackRMS: Float, at now: TimeInterval) -> Decision {
        guard let since = candidateSince else { return .none }
        micSum += micRMS
        playbackSum += playbackRMS
        frames += 1
        guard now - since >= Self.confirmWindow, frames > 0 else { return .none }
        let mic = micSum / Float(frames)
        let playback = playbackSum / Float(frames)
        reset()
        let dominates = mic >= Self.minimumMicRMS && mic > energyRatio * playback
        return dominates ? .commit : .reject
    }

    mutating func reset() {
        candidateSince = nil
        micSum = 0
        playbackSum = 0
        frames = 0
    }
}

/// Rejects an "interruption" that is just our own speech leaking back.
nonisolated enum BargeInEchoGuard {
    static let assistantTailWords = 12
    static let overlapThreshold = 0.8

    static func isEcho(transcript: String, assistantText: String) -> Bool {
        let heard = words(transcript)
        guard !heard.isEmpty else { return true }
        let tail = Set(words(assistantText).suffix(assistantTailWords))
        guard !tail.isEmpty else { return false }
        let overlap = heard.filter(tail.contains).count
        return Double(overlap) / Double(heard.count) >= overlapThreshold
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

extension LocalLLMManager {

    var isBargeInEnabled: Bool { OpenAISettings.shared.isLocalBargeInEnabled }

    /// Audio-thread hook: a mic frame that arrived while the assistant speaks.
    func observeBargeInFrame(_ buffer: AVAudioPCMBuffer, now: TimeInterval) {
        sileroVAD.processAudioBuffer(buffer)
        guard let channelData = buffer.floatChannelData else { return }
        let length = Int(buffer.frameLength)
        guard length > 0 else { return }

        var sum: Float = 0
        for i in 0..<length { sum += channelData[0][i] * channelData[0][i] }
        let micRMS = sqrt(sum / Float(length))

        recordingLock.lock()
        recordingBuffer.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: length))
        let maxPreRoll = Int((hardwareInputFormat?.sampleRate ?? 48_000) * 0.5)
        if recordingBuffer.count > maxPreRoll { recordingBuffer.removeFirst(recordingBuffer.count - maxPreRoll) }
        let decision = bargeInArbiter.observe(micRMS: micRMS, playbackRMS: lastPlaybackRMS, at: now)
        recordingLock.unlock()

        switch decision {
        case .commit:
            Task { @MainActor in self.interruptForBargeIn() }
        case .reject:
            nlLog("[BargeIn] voice start rejected (mic \(micRMS) vs playback \(lastPlaybackRMS))", level: .info)
        case .none:
            break
        }
    }

    /// Silero voice start while `.speaking`.
    func noteVoiceStartDuringSpeech() {
        let now = ProcessInfo.processInfo.systemUptime
        recordingLock.lock()
        let opened = bargeInArbiter.voiceStarted(at: now, playbackStartedAt: speakingStartedUptime)
        recordingLock.unlock()
        if !opened { nlLog("[BargeIn] voice start ignored (TTS onset guard)", level: .info) }
    }

    /// Stops the reply and hands the turn to the user.
    @MainActor
    func interruptForBargeIn() {
        guard state.status == .speaking else { return }
        let spokenFor = speakingStartedUptime.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        bargeInInterrupted = true
        lastSpokenAssistantText = state.aiTranscript

        llmEngine.stop()
        playerNode.stop()
        TTSEngineSelector.shared.engine(for: state.selectedCharacterName)?.stop()
        pendingTTSBuffers = 0
        ttsGenerationDone = false
        inFlightSynthesis = 0
        ttsBuffer = ""
        tagBuffer = ""
        pendingUIActionTask?.cancel()
        pendingUIActionTask = nil
        speakingStartedUptime = nil
        transcriptTypewriter.endGeneration()
        if !state.aiTranscript.isEmpty { state.aiTranscript += " —" }

        recordingLock.lock()
        isRecordingVoice = true
        lastPartialTranscribedCount = 0
        bargeInArbiter.reset()
        recordingLock.unlock()

        state.status = .listening
        nlLog("[BargeIn] interrupted after \(Int(spokenFor * 1000)) ms of speech", level: .info)
    }

    /// Transcript filter after an interruption: drop echoes of our own speech.
    /// Returns true when the transcript should be discarded.
    @MainActor
    func consumeBargeInEcho(transcript: String) -> Bool {
        guard bargeInInterrupted else { return false }
        bargeInInterrupted = false
        guard BargeInEchoGuard.isEcho(transcript: transcript, assistantText: lastSpokenAssistantText) else {
            return false
        }
        recordingLock.lock()
        bargeInArbiter.energyRatio += 0.5
        let ratio = bargeInArbiter.energyRatio
        recordingLock.unlock()
        nlLog("[BargeIn] echo rejected; energy ratio now \(ratio)", level: .warning)
        state.status = .ready
        return true
    }
}
