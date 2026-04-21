//
//  OpenAIRealtimeManager.swift
//  NeuraLink
//
//  Created by Dedicatus on 16/04/2026.
//

import AVFoundation
import Foundation
import RealTimeCutVADLibrary
import SwiftUI

/// Signature for handling incoming events from OpenAI
protocol OpenAIRealtimeDelegate: AnyObject {
    func openaiDidUpdateStatus(_ status: AIConnectionStatus)
    func openaiDidReceiveTranscript(_ text: String, isUser: Bool)
    func openaiDidUpdateAudioLevel(_ level: Float)
}

/// Core manager for OpenAI Realtime API via WebSocket + AVAudioEngine.
/// AVAudioEngine routes audio through the system audio graph — fully capturable
/// by iOS screen recording (unlike WebRTC VPIO which bypasses it).
final class OpenAIRealtimeManager: NSObject, @unchecked Sendable {
    static let shared = OpenAIRealtimeManager()

    private var webSocketTask: URLSessionWebSocketTask?
    private let urlSession: URLSession
    private let sileroVAD = SileroVADProcessor()

    // AVAudioEngine for mic capture and AI playback
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let levelMixer = AVAudioMixerNode()
    private var micConverter: AVAudioConverter?
    private let aiSampleRate: Double = 24000
    private var audioLevelResetTask: Task<Void, Never>?

    // Dependencies
    private let settings = OpenAISettings.shared
    private let state = RealtimeChatState.shared

    override init() {
        urlSession = URLSession(configuration: .default)
        super.init()
        setupAudioSession()
        setupAudioEngine()
    }

    private func setupAudioSession() {
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(
                .playAndRecord, mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
            try s.setActive(true)
            print("[AI]: AVAudioSession configured (.default mode, mixWithOthers)")
        } catch {
            print("[AI]: Failed to configure audio session: \(error)")
        }
    }

    private func setupAudioEngine() {
        let playFmt = AVAudioFormat(standardFormatWithSampleRate: aiSampleRate, channels: 1)!
        engine.attach(playerNode)
        engine.attach(levelMixer)
        // playerNode → levelMixer → mainMixerNode so the tap measures actual playback
        engine.connect(playerNode, to: levelMixer, format: playFmt)
        engine.connect(levelMixer, to: engine.mainMixerNode, format: playFmt)
    }

    // MARK: - Connection

    func connect() {
        guard settings.hasValidKey else {
            state.setError("Invalid API Key")
            return
        }
        state.status = .connecting
        print("[AI]: Connecting to OpenAI Realtime (WebSocket)...")

        var req = URLRequest(
            url: URL(string: "wss://api.openai.com/v1/realtime?model=gpt-4o-realtime-preview")!)
        req.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        webSocketTask = urlSession.webSocketTask(with: req)
        webSocketTask?.resume()
        receiveMessages()
        startAudioEngine()
    }

    func disconnect() {
        sileroVAD.stop()
        audioLevelResetTask?.cancel()
        engine.inputNode.removeTap(onBus: 0)
        levelMixer.removeTap(onBus: 0)
        playerNode.stop()
        if engine.isRunning { engine.stop() }
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        Task { @MainActor in RealtimeChatState.shared.audioLevel = 0 }
        state.status = .disconnected
    }

    // MARK: - WebSocket

    private func receiveMessages() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                let text: String? = switch msg {
                case .string(let s): s
                case .data(let d): String(data: d, encoding: .utf8)
                @unknown default: nil
                }
                if let t = text { self.handleEvent(t) }
                self.receiveMessages()
            case .failure(let error):
                print("[AI]: WebSocket error: \(error)")
                Task { @MainActor in
                    self.state.setError("Connection error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(text)) { _ in }
    }

    private func sendSessionUpdate() {
        let persona = CharacterPersona.forCharacter(named: state.selectedCharacterName)
        sendJSON([
            "type": "session.update",
            "session": [
                "modalities": ["text", "audio"],
                "voice": persona.voice,
                "instructions": persona.instructions,
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "input_audio_transcription": ["model": "whisper-1"],
                "turn_detection": ["type": "server_vad"]
            ]
        ])
        print("[AI]: Sent session.update")
    }

    // MARK: - Audio Engine

    private func startAudioEngine() {
        let inputNode = engine.inputNode
        let inputFmt = inputNode.outputFormat(forBus: 0)

        // Converter: device mic format → PCM16 24 kHz mono for OpenAI
        let targetFmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: aiSampleRate, channels: 1, interleaved: true)!
        micConverter = AVAudioConverter(from: inputFmt, to: targetFmt)

        let outCapacity = AVAudioFrameCount(
            ceil(aiSampleRate / inputFmt.sampleRate * 4096))

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFmt) { [weak self] buf, _ in
            self?.forwardMicAudio(buf, targetFmt: targetFmt, capacity: outCapacity)
        }

        do {
            try engine.start()
            playerNode.play()
            // Tap the mixer AFTER start so outputFormat(forBus:) reflects the live format.
            // ~23ms fire rate (1024 frames @ 44.1kHz) mirrors WebRTC's 50ms stats poll cadence.
            let tapFmt = levelMixer.outputFormat(forBus: 0)
            levelMixer.installTap(onBus: 0, bufferSize: 1024, format: tapFmt) { [weak self] buf, _ in
                self?.reportLevel(buf)
            }
            print("[AI]: AVAudioEngine started")
        } catch {
            print("[AI]: Failed to start audio engine: \(error)")
        }
    }

    private func reportLevel(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        var sumSq: Float = 0
        for i in 0..<frameCount { sumSq += data[i] * data[i] }
        let rms = min(sqrt(sumSq / Float(frameCount)) * 3.5, 1.0)
        Task { @MainActor in RealtimeChatState.shared.audioLevel = rms }
    }

    private func forwardMicAudio(
        _ buffer: AVAudioPCMBuffer, targetFmt: AVAudioFormat, capacity: AVAudioFrameCount
    ) {
        guard let conv = micConverter,
              let out = AVAudioPCMBuffer(pcmFormat: targetFmt, frameCapacity: capacity)
        else { return }

        var done = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if !done { done = true; status.pointee = .haveData; return buffer }
            status.pointee = .noDataNow; return nil
        }
        guard err == nil, out.frameLength > 0, let raw = out.int16ChannelData else { return }

        let bytes = Data(bytes: raw[0], count: Int(out.frameLength) * 2)
        sendJSON(["type": "input_audio_buffer.append", "audio": bytes.base64EncodedString()])
    }

    private func scheduleAIAudio(_ base64PCM: String) {
        guard let pcm = Data(base64Encoded: base64PCM) else { return }
        let frameCount = pcm.count / 2
        guard frameCount > 0 else { return }

        let fmt = AVAudioFormat(standardFormatWithSampleRate: aiSampleRate, channels: 1)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buf.frameLength = AVAudioFrameCount(frameCount)

        pcm.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            guard let dst = buf.floatChannelData?[0] else { return }
            for i in 0..<frameCount { dst[i] = Float(src[i]) / 32768.0 }
        }

        if !engine.isRunning { try? engine.start() }
        playerNode.scheduleBuffer(buf)
        if !playerNode.isPlaying { playerNode.play() }
    }

    // MARK: - Event Handling

    private func handleEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        print("[AI Event]: \(type)")

        Task { @MainActor in
            switch type {
            case "session.created":
                self.sendSessionUpdate()
                self.state.status = .ready
                self.startSileroVADIfEnabled()

            case "response.audio.delta":
                if let delta = json["delta"] as? String {
                    self.scheduleAIAudio(delta)
                }

            case "response.audio_transcript.delta":
                if let delta = json["delta"] as? String {
                    self.state.aiTranscript += delta
                }

            case "conversation.item.input_audio_transcription.completed":
                if let t = json["transcript"] as? String {
                    self.state.userTranscript = t
                }

            case "input_audio_buffer.speech_started":
                if self.state.status == .ready { self.state.status = .listening }

            case "input_audio_buffer.speech_stopped":
                if self.state.status == .listening { self.state.status = .ready }

            case "response.output_item.added":
                self.state.aiTranscript = ""
                self.state.status = .speaking

            case "response.done":
                self.state.status = .ready
                // Fallback: force level to 0 once audio buffer drains after the response ends.
                // The mixer tap naturally reads 0 when silent, but this handles edge cases.
                self.audioLevelResetTask?.cancel()
                self.audioLevelResetTask = Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run { RealtimeChatState.shared.audioLevel = 0 }
                }

            default: break
            }
        }
    }
}

// MARK: - Silero VAD

extension OpenAIRealtimeManager {
    private func startSileroVADIfEnabled() {
        guard settings.isVADEnabled else { return }
        sileroVAD.delegate = self
        sileroVAD.start()
    }
}

extension OpenAIRealtimeManager: SileroVADDelegate {
    func sileroVADDidDetectVoiceStart() {
        guard state.status == .ready else { return }
        state.status = .listening
        print("[SileroVAD]: Voice detected → listening")
    }

    func sileroVADDidDetectVoiceEnd() {
        guard state.status == .listening else { return }
        state.status = .ready
        print("[SileroVAD]: Voice ended → ready")
    }
}
