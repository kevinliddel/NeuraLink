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
import WebRTC

/// Signature for handling incoming events from OpenAI
protocol OpenAIRealtimeDelegate: AnyObject {
    func openaiDidUpdateStatus(_ status: AIConnectionStatus)
    func openaiDidReceiveTranscript(_ text: String, isUser: Bool)
    func openaiDidUpdateAudioLevel(_ level: Float)
}

/// Core manager for OpenAI Realtime API via WebRTC.
final class OpenAIRealtimeManager: NSObject, @unchecked Sendable {
    static let shared = OpenAIRealtimeManager()

    var peerConnection: RTCPeerConnection?
    /// The outgoing (mic) track — kept so song recognition can gate it.
    var localAudioTrack: RTCAudioTrack?
    var remoteDataChannel: RTCDataChannel?
    let factory: RTCPeerConnectionFactory
    private var statsTimer: Timer?
    var pendingOffer: RTCSessionDescription?
    var iceGatheringTimeout: Task<Void, Never>?
    let sileroVAD = SileroVADProcessor()

    // Dependencies
    let settings = OpenAISettings.shared
    let state = RealtimeChatState.shared

    // Function-call state (one active call at a time)
    var pendingFunctionCallId: String = ""
    var pendingFunctionName: String = ""
    var pendingFunctionArgsJSON: String = ""
    var deferredFunctionCall: (id: String, name: String, args: String)?

    /// True once THIS response streamed transcript text. `response.done`
    /// logs/stores the transcript only when set — a function-call-only
    /// response never clears `state.aiTranscript`, and logging it again
    /// duplicated the previous reply in the chat history.
    var hasFreshAITranscript = false

    // Post-audio execution: function waits until the AI's spoken audio finishes
    var audioPlaybackMonitorTask: Task<Void, Never>?
    // Set when the audio output item starts; anchors the speaking-duration estimate
    var speakingStartTime: Date?
    // Set when response.audio_transcript.done fires (real-time streaming signal)
    var transcriptDoneTime: Date?

    override init() {
        RTCInitializeSSL()
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        self.factory = RTCPeerConnectionFactory(
            encoderFactory: videoEncoderFactory, decoderFactory: videoDecoderFactory)
        super.init()
        setupAudioSession()
    }

    private func setupAudioSession() {
        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.lockForConfiguration()
        do {
            try rtcSession.setCategory(
                .playAndRecord, with: [.allowBluetoothHFP, .defaultToSpeaker])
            try rtcSession.setMode(.videoChat)
            try rtcSession.setActive(true)
            // Manual audio so `isAudioEnabled` actually gates the audio
            // units (it is a no-op otherwise) — song recognition suspends
            // them to get an unprocessed mic signal.
            rtcSession.useManualAudio = true
            rtcSession.isAudioEnabled = true
            nlLog("[AI]: RTCAudioSession configured for speaker output", level: .info)
        } catch {
            nlLog("[AI]: Failed to configure RTCAudioSession: \(error)", level: .error)
        }
        rtcSession.unlockForConfiguration()
    }

    func forceAudioToSpeaker() {
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
        } catch {
            nlLog("[AI]: Failed to override output port: \(error)", level: .error)
        }
    }

    /// Starts the Realtime session
    func connect() {
        guard settings.hasValidKey else {
            state.setError("Invalid API Key")
            return
        }

        // Prevent redundant connection attempts if already active or connecting.
        guard
            state.status != .connecting && state.status != .ready && state.status != .speaking
                && state.status != .thinking
        else {
            nlLog("[AI]: Already connected or connecting, skipping.", level: .info)
            return
        }

        state.status = .connecting
        nlLog("[AI]: Connecting to OpenAI Realtime...", level: .info)
        Task.detached(priority: .userInitiated) { [weak self] in
            self?.setupAudioSession()
            self?.setupPeerConnection()
            self?.createAndSendOffer()
        }
    }

    /// Stops the Realtime session
    func disconnect() {
        audioPlaybackMonitorTask?.cancel()
        audioPlaybackMonitorTask = nil
        speakingStartTime = nil
        transcriptDoneTime = nil
        AppFunctionExecutor.shared.pendingUIAction = nil
        micGateReasons.removeAll()
        sileroVAD.stop()
        ProactiveVisionManager.shared.stop()
        remoteDataChannel?.close()
        peerConnection?.close()
        peerConnection = nil
        stopStatsPolling()
        state.status = .disconnected
    }

    // MARK: - WebRTC Signaling

    func setupPeerConnection() {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.iceCandidatePoolSize = 10

        // Add STUN servers to help with NAT traversal
        config.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun1.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun2.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun3.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["stun:stun4.l.google.com:19302"])
        ]

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

        self.peerConnection = factory.peerConnection(
            with: config, constraints: constraints, delegate: self)

        // Add Audio track
        let audioSource = factory.audioSource(with: nil)
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "audio0")
        peerConnection?.add(audioTrack, streamIds: ["stream0"])
        self.localAudioTrack = audioTrack
        // Fresh track starts enabled — stale gate reasons from a previous
        // connection must not linger and mute it.
        micGateReasons.removeAll()

        // Setup Data Channel
        let dataChannelConfig = RTCDataChannelConfiguration()
        self.remoteDataChannel = peerConnection?.dataChannel(
            forLabel: "oai-events", configuration: dataChannelConfig)
        self.remoteDataChannel?.delegate = self
    }

    /// Suspends WebRTC's audio units for the song-recognition listen window.
    /// The voice-processing unit scrubs music out of the mic (AEC/noise
    /// suppression), which makes Shazam match attempts fail (code 202); the
    /// session also drops to `.default` mode so the raw mic reaches the
    /// recorder. The peer connection stays alive; `resumeAudioUnit()`
    /// restores voice mode. No-op when offline.
    func suspendAudioUnit() {
        guard peerConnection != nil else { return }
        let rtcSession = RTCAudioSession.sharedInstance()
        rtcSession.lockForConfiguration()
        rtcSession.isAudioEnabled = false
        do {
            try rtcSession.setMode(.default)
        } catch {
            nlLog("[AI]: Failed to drop session mode for music capture: \(error)", level: .warning)
        }
        rtcSession.unlockForConfiguration()
        nlLog("[AI]: WebRTC audio suspended for music recognition", level: .info)
    }

    func resumeAudioUnit() {
        guard peerConnection != nil else { return }
        let rtcSession = RTCAudioSession.sharedInstance()
        // Restore the FULL WebRTC session configuration, not just the mode:
        // the capture window can leave the hardware at a different sample
        // rate (Shazam records at the device default), and restarting the
        // audio units against the wrong rate pitch-shifts/accelerates all
        // assistant speech until the next reconnect.
        let config = RTCAudioSessionConfiguration.webRTC()
        config.category = AVAudioSession.Category.playAndRecord.rawValue
        config.categoryOptions = [.allowBluetoothHFP, .defaultToSpeaker]
        config.mode = AVAudioSession.Mode.videoChat.rawValue
        rtcSession.lockForConfiguration()
        do {
            try rtcSession.setConfiguration(config, active: true)
        } catch {
            nlLog("[AI]: Failed to restore WebRTC session configuration: \(error)", level: .warning)
        }
        rtcSession.isAudioEnabled = true
        rtcSession.unlockForConfiguration()
        nlLog(
            "[AI]: WebRTC audio resumed after music recognition (rate \(config.sampleRate) Hz)",
            level: .info)
    }

    /// Why the outgoing mic track is currently gated. The track stays
    /// disabled while ANY reason is held, so overlapping holders (song
    /// recognition listening while the assistant announces, say) can't
    /// release each other's gate.
    enum MicGateReason: String {
        /// Song recognition is listening or announcing — the session must
        /// not hear the music (or our own TTS) as user speech.
        case songRecognition
        /// The assistant is speaking. Residual echo of its own voice that
        /// AEC misses (phone on a desk in PiP, speaker up) was reaching
        /// server_vad and coming back as phantom "user" turns; gate the
        /// track for the duration of the response instead.
        case assistantSpeaking
    }

    var micGateReasons: Set<MicGateReason> = []

    /// Gates or releases the outgoing mic for one reason; the track is
    /// re-enabled only when no reason remains. No-op when offline.
    func setMicGated(_ gated: Bool, reason: MicGateReason) {
        if gated {
            micGateReasons.insert(reason)
        } else {
            micGateReasons.remove(reason)
        }
        guard let track = localAudioTrack else { return }
        let shouldEnable = micGateReasons.isEmpty
        guard track.isEnabled != shouldEnable else { return }
        track.isEnabled = shouldEnable
        nlLog(
            "[AI]: Outgoing mic \(shouldEnable ? "restored" : "gated") (\(reason.rawValue))",
            level: .info)
    }

    func createAndSendOffer() {
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue
            ], optionalConstraints: nil)

        peerConnection?.offer(for: constraints) { [weak self] offer, error in
            nlLog("[AI]: Creating SDP offer...", level: .info)
            guard let self = self, let offer = offer else {
                self?.state.setError(
                    "Failed to create offer: \(error?.localizedDescription ?? "unknown")")
                return
            }

            self.peerConnection?.setLocalDescription(offer) { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.state.setError("Failed to set local desc: \(error.localizedDescription)")
                    return
                }
                nlLog(
                    "[AI]: SDP offer set, gathering ICE candidates (timeout in 1.5s)...",
                    level: .info)
                self.pendingOffer = offer

                // Fallback timeout: Send what we have if gathering takes too long
                self.iceGatheringTimeout?.cancel()
                self.iceGatheringTimeout = Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if !Task.isCancelled {
                        nlLog(
                            "[AI]: ICE gathering timeout reached, sending available candidates",
                            level: .info)
                        self.sendOfferIfPossible()
                    }
                }
            }
        }
    }

    func sendOfferIfPossible() {
        guard let offer = peerConnection?.localDescription, pendingOffer != nil else { return }
        iceGatheringTimeout?.cancel()
        iceGatheringTimeout = nil
        pendingOffer = nil  // Mark as sent
        sendOfferToOpenAI(offer)
    }

    /// Polling stats to extract audio levels for lip-sync
    func startStatsPolling() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statsTimer?.invalidate()
            self.statsTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) {
                [weak self] _ in
                self?.peerConnection?.statistics { report in
                    for (_, stats) in report.statistics {
                        if stats.type == "inbound-rtp",
                            let audioLevelValue = stats.values["audioLevel"] {
                            let level = (audioLevelValue as? NSNumber)?.floatValue ?? 0.0
                            if level > 0.01 {
                                nlLog("[AI]: Incoming audio level detected: \(level)", level: .info)
                            }
                            Task { @MainActor in
                                RealtimeChatState.shared.audioLevel = level
                            }
                        }
                    }
                }
            }
        }
    }

    /// Stops polling
    func stopStatsPolling() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statsTimer?.invalidate()
            self.statsTimer = nil
        }
    }

    // MARK: - Silero VAD

    func startSileroVADIfEnabled() {
        guard settings.isVADEnabled else { return }
        sileroVAD.delegate = self
        sileroVAD.start()
    }
}
