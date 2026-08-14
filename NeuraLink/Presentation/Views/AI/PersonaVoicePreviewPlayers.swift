//
//  PersonaVoicePreviewPlayers.swift
//  NeuraLink
//
//  Internal preview players for `PersonaSettingsView`.
//
//  Created by Dedicatus on 28/04/2026.
//

import AVFoundation
import Observation

// MARK: - Playback session routing

/// Puts the shared audio session into plain playback shape before standalone
/// TTS (voice preview, transcript playback) starts.
///
/// The live pipelines leave the session in voice-call configurations —
/// `PiPManager` sets `mode: .voiceChat`, whose voice processing audibly
/// attenuates any subsequent playback, and without `.defaultToSpeaker` a
/// `.playAndRecord` session routes to the earpiece. The category stays
/// `.playAndRecord` so an active mic pipeline isn't torn down; only the mode
/// and options are normalised (mirrors `LocalLLMManager+Audio`, which does
/// the same before live chat TTS).
enum TTSPlaybackSession {
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        let needsConfig = session.category != .playAndRecord
            || session.mode != .default
            || !session.categoryOptions.contains(.defaultToSpeaker)
        if needsConfig {
            do {
                try session.setCategory(
                    .playAndRecord, mode: .default,
                    options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
            } catch {
                nlLog("[TTSPlayback] setCategory failed: \(error)", level: .warning)
            }
        }
        try? session.setActive(true)
    }
}

// MARK: - OpenAI / Cloud Preview Player (AVAudioPlayer)

/// Plays a complete encoded audio file (MP3/AAC, as returned by OpenAI's
/// `/v1/audio/speech` endpoint) through `AVAudioPlayer`.
@Observable
final class VoicePreviewPlayer: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    var isSpeaking = false
    private var player: AVAudioPlayer?

    func start(data: Data) {
        stop()
        do {
            TTSPlaybackSession.activate()
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            player = p
            p.play()
            isSpeaking = true
        } catch {
            isSpeaking = false
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isSpeaking = false
    }

    func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
        player = nil
        isSpeaking = false
    }

    deinit { player?.stop() }
}

// MARK: - Local Engine Preview Player (AVAudioEngine + PCMBuffer streaming)

/// Plays PCMBuffer streams produced by local TTS engines (VoiceVox, OpenVoice).
/// Owns its own AVAudioEngine so previewing here doesn't interfere with the
/// chat playback engine in `LocalLLMManager`.
@Observable
final class LocalTTSPreviewPlayer: @unchecked Sendable {
    var isSpeaking = false

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var didAttach = false
    private var pendingBuffers = 0

    func schedule(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.sampleRate > 0, buffer.format.channelCount > 0 else {
            nlLog("[Preview] Dropping buffer — invalid format sr=\(buffer.format.sampleRate) ch=\(buffer.format.channelCount)", level: .error)
            return
        }
        // Activate the session first: connecting to mainMixerNode with an
        // inactive session gives the engine output a 0-rate format and trips
        // AVAudioEngine's IsFormatSampleRateAndChannelCountValid assertion.
        // (Also normalises a stale voice-chat mode that would mute playback —
        // see TTSPlaybackSession.)
        TTSPlaybackSession.activate()
        ensureAttached(format: buffer.format)
        if !audioEngine.isRunning {
            try? audioEngine.start()
        }
        if !playerNode.isPlaying { playerNode.play() }

        pendingBuffers += 1
        isSpeaking = true
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingBuffers -= 1
                if self.pendingBuffers <= 0 {
                    self.pendingBuffers = 0
                    self.isSpeaking = false
                }
            }
        }
    }

    func stop() {
        if playerNode.isPlaying {
            playerNode.stop()
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        pendingBuffers = 0
        isSpeaking = false
    }

    private func ensureAttached(format: AVAudioFormat) {
        if !didAttach {
            audioEngine.attach(playerNode)
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
            didAttach = true
            return
        }
        let current = playerNode.outputFormat(forBus: 0)
        if current != format {
            let wasRunning = audioEngine.isRunning
            if wasRunning { audioEngine.pause() }
            audioEngine.disconnectNodeInput(playerNode)
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
            if wasRunning { try? audioEngine.start() }
        }
    }

    deinit { stop() }
}
